//===-- tools/runtime-adapt/source/surface.d ----------------------*- D -*-===//
//
//                         LDC – the LLVM D compiler
//
// This file is distributed under the BSD-style LDC license. See the LICENSE
// file for details.
//
//===----------------------------------------------------------------------===//
//
// Compiler → runtime surface check. Answers "did this checkout include
// every pragma / UDA / ldc.* module / hook the frontend names?"
// Does not claim semantic equality with handwritten ldc/* bodies.
//
//===----------------------------------------------------------------------===//

module surface;

import compilerparse;
import ldcmods;
import ldcmods.intrinsics : looksLikePublicIntrinsic;
import paths;
import walk;

import std.algorithm : canFind, sort, uniq;
import std.array : appender, array, join;
import std.file : exists, readText;
import std.format : format;
import std.path : buildPath;

struct SurfaceGap
{
    string kind; /// module, pragma, attr, intrinsic, hook
    string name;
    string where; /// runtime | generated
}

struct SurfaceReport
{
    string guideRoot;
    bool ok;
    SurfaceGap[] missing;
    int modulesChecked;
    int pragmasChecked;
    int attrsChecked;
    int intrinsicsChecked;
    int hooksChecked;
}

/// Scan compiler vs this checkout's runtime (and optional generated tree).
SurfaceReport checkSurface(string ldcRoot, string generatedDir = "")
{
    SurfaceReport r;
    r.guideRoot = ldcRoot;
    auto m = parseCompiler(ldcRoot);
    r.ok = m.ok;
    if (!m.ok)
        return r;

    string runtimeBlob = slurpRuntime(ldcRoot);
    string genBlob;
    if (generatedDir.length && exists(generatedDir))
        genBlob = slurpGenerated(generatedDir);

    foreach (n; m.ldcModules)
    {
        if (!isLdcRuntimeModule(n) || skipModule(n))
            continue;
        r.modulesChecked++;
        auto rel = moduleRel(n);
        if (!runtimeHasFile(ldcRoot, rel) && !runtimeBlob.canFind("ldc." ~ n)
            && !runtimeBlob.canFind("module ldc." ~ n))
            r.missing ~= SurfaceGap("module", n, "runtime");
        if (genBlob.length && !genBlob.canFind("module ldc." ~ n)
            && !generatedHasFile(generatedDir, rel))
            r.missing ~= SurfaceGap("module", n, "generated");
    }

    foreach (p; m.pragmas)
    {
        if (!runtimePragma(p))
            continue;
        r.pragmasChecked++;
        if (!runtimeBlob.canFind(p))
            r.missing ~= SurfaceGap("pragma", p, "runtime");
        if (genBlob.length && !genBlob.canFind(p))
            r.missing ~= SurfaceGap("pragma", p, "generated");
    }

    foreach (n; m.attrNames)
    {
        if (!n.length || skipAttr(n))
            continue;
        r.attrsChecked++;
        auto pub = (n[0] == '_') ? n[1 .. $] : n;
        if (!runtimeBlob.canFind(pub))
            r.missing ~= SurfaceGap("attr", n, "runtime");
        if (genBlob.length && !genBlob.canFind(pub))
            r.missing ~= SurfaceGap("attr", n, "generated");
    }

    foreach (it; m.llvmIntrinsics)
    {
        if (!looksLikePublicIntrinsic(it))
            continue;
        r.intrinsicsChecked++;
        if (!runtimeBlob.canFind(it) && !runtimeBlob.canFind(stem(it)))
            r.missing ~= SurfaceGap("intrinsic", it, "runtime");
        if (genBlob.length && !genBlob.canFind(it) && !genBlob.canFind(stem(it)))
            r.missing ~= SurfaceGap("intrinsic", it, "generated");
    }

    foreach (h; m.runtimeHooks)
    {
        if (!h.length || skipHook(h))
            continue;
        r.hooksChecked++;
        if (!runtimeBlob.canFind(h))
            r.missing ~= SurfaceGap("hook", h, "runtime");
    }
    return r;
}

string renderSurface(const SurfaceReport r)
{
    auto buf = appender!string();
    buf.put("# Compiler → runtime surface\n\n");
    buf.put(format("- guide: `%s` ok=%s\n", r.guideRoot, r.ok));
    buf.put(format("- checked: modules=%s pragmas=%s attrs=%s intrinsics=%s hooks=%s\n",
        r.modulesChecked, r.pragmasChecked, r.attrsChecked, r.intrinsicsChecked,
        r.hooksChecked));
    buf.put(format("- missing: %s\n\n", r.missing.length));
    if (!r.missing.length)
    {
        buf.put("Every named compiler surface is present in the runtime tree.\n");
        return buf.data;
    }
    buf.put("| kind | name | where |\n|---|---|---|\n");
    foreach (g; r.missing)
        buf.put(format("| %s | `%s` | %s |\n", g.kind, g.name, g.where));
    return buf.data;
}

bool surfaceClean(const SurfaceReport r)
{
    return r.ok && !r.missing.length;
}

private bool skipModule(string n)
{
    // Named in compiler comments / JIT, not a druntime ldc/*.d we emit.
    switch (n)
    {
    case "sanitizers_flag", "traits", "dynamic_compile":
        return true;
    default:
        return false;
    }
}

/// Pragmas that must appear in ldc/* (not just be handled in gen/pragma.cpp).
private bool runtimePragma(string p)
{
    switch (p)
    {
    case "LDC_intrinsic", "LDC_inline_asm", "LDC_inline_ir", "LDC_fence",
        "LDC_atomic_load", "LDC_atomic_store", "LDC_atomic_cmp_xchg",
        "LDC_atomic_rmw", "LDC_profile_instr", "LDC_extern_weak":
        return true;
    default:
        return false;
    }
}

/// Compiler still names these; this runtime does not define them (fwd-decl only).
private bool skipHook(string h)
{
    return h == "_d_delarray_t";
}

private bool skipAttr(string n)
{
    switch (n)
    {
    case "gnuAbiTag", "selector", "optional", "mustuse", "standalone",
        "swift", "compute", "kernel", "_kernel":
        return true;
    default:
        return false;
    }
}

private string stem(string llvmName)
{
    auto s = llvmName;
    if (s.length >= 5 && s[0 .. 5] == "llvm.")
        s = s[5 .. $];
    auto i = s.length;
    foreach (j, ch; s)
        if (ch == '.')
        {
            i = j;
            break;
        }
    return s[0 .. i];
}

private bool runtimeHasFile(string ldcRoot, string rel)
{
    auto p = buildPath(druntimeSrc(ldcRoot), rel);
    return exists(p);
}

private bool generatedHasFile(string generatedDir, string rel)
{
    return exists(buildPath(generatedDir, rel));
}

private string slurpRuntime(string ldcRoot)
{
    auto buf = appender!string();
    foreach (f; walkLdcRuntime(ldcRoot))
    {
        if (!f.abs.length)
            continue;
        try
            buf.put(readText(f.abs));
        catch (Exception)
        {
        }
        buf.put('\n');
    }
    return buf.data;
}

private string slurpGenerated(string generatedDir)
{
    auto buf = appender!string();
    foreach (f; walkMergedTree(generatedDir))
    {
        try
            buf.put(readText(f.abs));
        catch (Exception)
        {
        }
        buf.put('\n');
    }
    return buf.data;
}
