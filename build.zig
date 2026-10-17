const std = @import("std");
const builtin = @import("builtin");

// A wrong Zig version fails here with one message, instead of with a wall of
// stdlib errors from APIs that moved between versions.
comptime {
    const required = std.SemanticVersion.parse(@import("build.zig.zon").minimum_zig_version) catch unreachable;
    const current = builtin.zig_version;
    if (current.major != required.major or current.minor != required.minor) {
        @compileError(std.fmt.comptimePrint("zpdf needs Zig {d}.{d}.x, this is {d}.{d}.{d}", .{
            required.major, required.minor, current.major, current.minor, current.patch,
        }));
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const kb = b.dependency("kb", .{});
    const harfbuzz = b.dependency("harfbuzz", .{});

    const mod = b.addModule("zpdf", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // kb's default allocator is malloc.
        .link_libc = true,
    });

    const build_options = b.addOptions();
    build_options.addOptionPath("test_font_latin", harfbuzz.path("test/shape/data/in-house/fonts/7bbd3175734d5d291e1c15271ec0cbb97b626ebf.ttf"));
    build_options.addOptionPath("test_font_marks", harfbuzz.path("test/shape/data/in-house/fonts/8228d035fcd65d62ec9728fb34f42c63be93a5d3.ttf"));
    build_options.addOptionPath("test_font_devanagari", harfbuzz.path("test/shape/data/in-house/fonts/b722a7d09e60421f3efbc706ad348ab47b88567b.ttf"));
    build_options.addOptionPath("test_font_arabic", harfbuzz.path("test/shape/data/in-house/fonts/872d2955d326bd6676a06f66b8238ebbaabc212f.ttf"));
    build_options.addOptionPath("test_font_hebrew", harfbuzz.path("test/shape/data/in-house/fonts/b895f8ff06493cc893ec44de380690ca0074edfa.ttf"));
    build_options.addOptionPath("test_font_toomanyops", harfbuzz.path("test/shape/data/text-rendering-tests/fonts/TestGSUBThree.ttf"));
    build_options.addOptionPath("test_font_roboto", harfbuzz.path("test/subset/data/fonts/Roboto-Regular.ttf"));
    build_options.addOptionPath("test_font_cff", harfbuzz.path("test/subset/data/fonts/SourceSansPro-Regular.otf"));
    build_options.addOptionPath("test_font_ttc", harfbuzz.path("test/shape/data/in-house/fonts/TTC.ttc"));
    build_options.addOptionPath("test_font_noto_devanagari", harfbuzz.path("test/subset/data/fonts/NotoSansDevanagari-Regular.ttf"));
    build_options.addOptionPath("test_font_amiri", harfbuzz.path("test/subset/data/fonts/Amiri-Regular.ttf"));
    build_options.addOptionPath("test_font_noto_hebrew", harfbuzz.path("test/subset/data/fonts/NotoIKEAHebrewLatin-Regular.ttf"));
    build_options.addOptionPath("test_font_variable", harfbuzz.path("test/subset/data/fonts/Fraunces.ttf"));
    build_options.addOptionPath("test_font_roboto_flex", harfbuzz.path("test/subset/data/fonts/RobotoFlex-Variable.ttf"));
    build_options.addOptionPath("test_font_noto_sans_vf", harfbuzz.path("test/subset/data/fonts/NotoSans-VF.abc.ttf"));
    build_options.addOptionPath("test_font_gpos_four", harfbuzz.path("test/shape/data/text-rendering-tests/fonts/TestGPOSFour.ttf"));
    build_options.addOptionPath("test_font_avar2", harfbuzz.path("test/api/fonts/TestAvar2Instance.ttf"));
    build_options.addOptionPath("test_font_mada", harfbuzz.path("test/api/fonts/Mada-VF.ttf"));
    build_options.addOptionPath("test_font_roboto_variable", harfbuzz.path("test/subset/data/fonts/Roboto-Variable.ttf"));
    build_options.addOptionPath("test_font_playwrite", harfbuzz.path("test/subset/data/fonts/playwrite_mm.subset.ttf"));
    build_options.addOptionPath("bidi_cases", b.path("tests/bidi/cases.tsv"));
    build_options.addOptionPathDirectory("golden_dir", b.path("tests/golden"));
    build_options.addOptionPathDirectory("read_fixtures", b.path("tests/read"));
    build_options.addOptionPathDirectory("cid_dir", b.path("src/cid"));
    build_options.addOptionPath("winansi_table", b.path("tests/winansi/table.tsv"));
    build_options.addOptionPath("test_font_anchor", harfbuzz.path("test/api/fonts/SourceSansVariable-Roman.anchor.ttf"));
    build_options.addOptionPath("test_font_duplicate_axes", harfbuzz.path("test/shape/data/in-house/fonts/e8691822f6a705e3e9fb48a0405c645b1a036590.ttf"));
    mod.addOptions("build_options", build_options);
    mod.addOptions("abi_options", abiOptions(b, false, false));
    addKb(b, mod, kb, .libc);
    const cid = packCidMaps(b);
    addCidMaps(mod, &cid, true);

    const shape_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/zpdf-shape.zig"),
        .target = target,
        .optimize = optimize,
    });
    shape_exe_mod.addImport("zpdf", mod);
    const shape_exe = b.addExecutable(.{
        .name = "zpdf-shape",
        .root_module = shape_exe_mod,
    });
    b.installArtifact(shape_exe);

    const text_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/zpdf-text.zig"),
        .target = target,
        .optimize = optimize,
    });
    text_exe_mod.addImport("zpdf", mod);
    const text_exe = b.addExecutable(.{
        .name = "zpdf-text",
        .root_module = text_exe_mod,
    });
    b.installArtifact(text_exe);

    const read_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/zpdf-read.zig"),
        .target = target,
        .optimize = optimize,
    });
    read_exe_mod.addImport("zpdf", mod);
    b.installArtifact(b.addExecutable(.{
        .name = "zpdf-read",
        .root_module = read_exe_mod,
    }));

    // `zig build test -- --test-filter X` does not reach the test runner, so a
    // filtered run must go through this option instead.
    const test_filters = b.option([]const []const u8, "test-filter", "Run only tests whose name contains this (repeatable)") orelse &.{};
    checkTestRoots(b);
    const tests = b.addTest(.{ .root_module = mod, .filters = test_filters });
    // The test binary, installed but not run, so tools/test-valgrind.sh can
    // cross-compile it (-Dtarget=aarch64-linux-musl) and run it on Linux.
    const test_artifacts = b.step("test-artifacts", "Install the test binary to <prefix>/test without running it");
    test_artifacts.dependOn(&b.addInstallArtifact(tests, .{ .dest_dir = .{ .override = .{ .custom = "test" } } }).step);

    const test_step = b.step("test", "Run unit tests, check formatting, and build for wasm32");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&text_exe.step);

    // bench-ab:begin (tools/bench-ab.py copies this block into an older tree that lacks it)
    // tools/bench-ab.py builds this (zig build bench -Doptimize=ReleaseFast)
    // and times it against main and against MuPDF (tools/bench-mupdf.c). It
    // is compiled in `zig build test` too, so it cannot rot.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("zpdf", mod);
    const bench_exe = b.addExecutable(.{ .name = "zpdf-bench", .root_module = bench_mod });
    b.step("bench", "Install zpdf-bench, the workload tools/bench-ab.py times").dependOn(&b.addInstallArtifact(bench_exe, .{}).step);
    test_step.dependOn(&bench_exe.step);
    // bench-ab:end

    // The PDFs zpdf-text makes for tests/golden/cases.tsv must hash to
    // tests/golden/sha256.txt (tools/golden-check.zig says how to read a
    // failure). It runs the zpdf-text this build installs, so it checks the
    // program as shipped, and a refactor that moves one byte of output fails.
    const golden_step = b.step("golden", "Check zpdf-text's output for tests/golden/cases.tsv against tests/golden/sha256.txt");
    addGolden(b, golden_step, text_exe, harfbuzz);
    test_step.dependOn(golden_step);

    // Unformatted code fails `zig build test`; `zig build fmt` fixes it.
    const fmt_paths: []const std.Build.LazyPath = &.{ b.path("src"), b.path("tools"), b.path("build.zig"), b.path("build.zig.zon") };
    test_step.dependOn(&b.addFmt(.{ .paths = fmt_paths, .check = true }).step);
    b.step("fmt", "Format the Zig sources").dependOn(&b.addFmt(.{ .paths = fmt_paths }).step);

    // The browser build: wasm32 with no C runtime. It is part of `zig build test`
    // so code that only breaks on wasm fails in the normal loop, not later.
    const wasm = addWasm(b, kb, build_options, &cid, "zpdf", false);
    b.installArtifact(wasm);
    const wasm_step = b.step("wasm", "Build for wasm32-freestanding");
    wasm_step.dependOn(&wasm.step);
    test_step.dependOn(&wasm.step);
    // The same build plus a panic on demand (zpdf_wasm_test_panic), only for the
    // browser test of the trap policy; never installed.
    const wasm_test_build = addWasm(b, kb, build_options, &cid, "zpdf-test", true);

    // The wasm in headless Chromium, through web/index.html and pdf.js. Needs bun on
    // PATH; `bun install` fetches pdf.js and Playwright, and the first run may need
    // `bun web/node_modules/playwright-core/cli.js install --only-shell chromium`.
    const web_install = b.addSystemCommand(&.{ "bun", "install", "--frozen-lockfile" });
    web_install.setCwd(b.path("web"));
    web_install.has_side_effects = true;
    const web_test = b.addSystemCommand(&.{"env"});
    web_test.addPrefixedFileArg("ZPDF_WASM=", wasm.getEmittedBin());
    web_test.addPrefixedFileArg("ZPDF_TEST_WASM=", wasm_test_build.getEmittedBin());
    web_test.addPrefixedDirectoryArg("ZPDF_FONTS=", harfbuzz.path("test/subset/data/fonts"));
    web_test.addArgs(&.{ "bun", "test", "--timeout", "30000" });
    web_test.setCwd(b.path("web"));
    web_test.has_side_effects = true;
    web_test.step.dependOn(&web_install.step);
    b.step("web-test", "Build zpdf.wasm and test it in headless Chromium (web/)").dependOn(&web_test.step);

    // libzpdf: the C ABI (src/abi.zig) as a native shared library, for .NET and C.
    const native = addNative(b, kb, build_options, &cid, target, false);
    b.installArtifact(native);

    // zpdf.h and the C# declarations, written from src/abi.zig.
    const gen_abi_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen-abi.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    gen_abi_mod.addImport("zpdf", addZpdfModule(b, kb, build_options, &cid, b.graph.host));
    const gen_abi = b.addRunArtifact(b.addExecutable(.{ .name = "gen-abi", .root_module = gen_abi_mod }));
    gen_abi.addFileArg(b.path("src/abi.zig"));
    const header = gen_abi.addOutputFileArg("zpdf.h");
    const csharp = gen_abi.addOutputFileArg("Zpdf.Abi.g.cs");
    const abi_step = b.step("abi", "Install libzpdf, include/zpdf.h and csharp/Zpdf.Abi.g.cs");
    abi_step.dependOn(&b.addInstallArtifact(native, .{}).step);
    abi_step.dependOn(&b.addInstallHeaderFile(header, "zpdf.h").step);
    abi_step.dependOn(&b.addInstallFileWithDir(csharp, .{ .custom = "csharp" }, "Zpdf.Abi.g.cs").step);

    // For a package that depends on zpdf (a .NET package's native build, say), by name:
    //   zpdf.namedLazyPath("zpdf.h"), zpdf.namedLazyPath("Zpdf.Abi.g.cs"), and
    //   zpdf.namedLazyPath("libzpdf-<rid>") for each rid in native_targets (the file is that
    //   entry's `file`), stripped, as native-all installs it.
    b.addNamedLazyPath("zpdf.h", header);
    b.addNamedLazyPath("Zpdf.Abi.g.cs", csharp);

    // libzpdf for each runtime a .NET package carries, as runtimes/<rid>/native/<file>.
    const native_all = b.step("native-all", "Build libzpdf for linux-x64, linux-arm64, osx-arm64 and win-x64");
    // The same libraries laid out as runtimes/<rid>/native/<file>, for the NuGet package.
    const runtimes = b.addWriteFiles();
    for (native_targets) |t| {
        const lib = addNative(b, kb, build_options, &cid, b.resolveTargetQuery(t.query), true);
        _ = runtimes.addCopyFile(lib.getEmittedBin(), b.fmt("runtimes/{s}/native/{s}", .{ t.rid, t.file }));
        b.addNamedLazyPath(b.fmt("libzpdf-{s}", .{t.rid}), lib.getEmittedBin());
        native_all.dependOn(&b.addInstallArtifact(lib, .{
            .dest_dir = .{ .override = .{ .custom = b.pathJoin(&.{ "runtimes", t.rid, "native" }) } },
            .dest_sub_path = t.file,
            .implib_dir = .disabled,
            .pdb_dir = .disabled,
        }).step);
    }

    // A C program against the generated header and the shared library, as a C caller has them:
    // it fails to compile when the header disagrees with itself, and to run when libzpdf does.
    const abi_test_mod = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true });
    abi_test_mod.addCSourceFile(.{ .file = b.path("tests/abi/abi-test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-Werror" } });
    abi_test_mod.addIncludePath(header.dirname());
    abi_test_mod.linkLibrary(native);
    const abi_test = b.addRunArtifact(b.addExecutable(.{ .name = "abi-test", .root_module = abi_test_mod }));
    abi_test.addFileArg(harfbuzz.path("test/subset/data/fonts/Roboto-Regular.ttf"));
    abi_test.addFileArg(b.path("tests/read/objstm.pdf"));
    abi_test.expectStdOutEqual("abi-test: ok\n");
    test_step.dependOn(&abi_test.step);

    // The .NET library (dotnet/Zpdf) keeps the generated declarations beside its own code, so it
    // builds with dotnet alone; `zig build test` fails when that copy differs from what
    // gen-abi writes now.
    const csharp_copy = "dotnet/Zpdf/Zpdf.Abi.g.cs";
    const update_csharp = b.addUpdateSourceFiles();
    update_csharp.addCopyFileToSource(csharp, csharp_copy);
    b.step("dotnet-codegen", "Write " ++ csharp_copy ++ " from src/abi.zig").dependOn(&update_csharp.step);
    const same_file = b.addExecutable(.{ .name = "same-file", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/same-file.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const csharp_check = b.addRunArtifact(same_file);
    csharp_check.addFileArg(csharp);
    csharp_check.addFileArg(b.path(csharp_copy));
    csharp_check.addArg("tools/zig build dotnet-codegen");
    test_step.dependOn(&csharp_check.step);

    // The .NET library's tests against this libzpdf. Needs the .NET SDK.
    const dotnet_test = b.addSystemCommand(&.{ "dotnet", "test", "dotnet/Zpdf.Tests/Zpdf.Tests.csproj", "-c", "Release" });
    dotnet_test.addPrefixedDirectoryArg("--property:ZpdfNativeDir=", native.getEmittedBin().dirname());
    dotnet_test.addPrefixedFileArg("--property:ZpdfTestFont=", harfbuzz.path("test/subset/data/fonts/Roboto-Regular.ttf"));
    dotnet_test.has_side_effects = true;
    b.step("dotnet-test", "Run the .NET library's tests against libzpdf (needs dotnet)").dependOn(&dotnet_test.step);

    // The NuGet package, with libzpdf for every RID native-all builds, into <prefix>/nuget.
    const dotnet_pack = b.addSystemCommand(&.{ "dotnet", "pack", "dotnet/Zpdf/Zpdf.csproj", "-c", "Release" });
    dotnet_pack.addPrefixedDirectoryArg("--property:ZpdfRuntimes=", runtimes.getDirectory().path(b, "runtimes"));
    dotnet_pack.addPrefixedDirectoryArg("--property:ZpdfNativeDir=", native.getEmittedBin().dirname());
    dotnet_pack.addArg("--output");
    const nuget = dotnet_pack.addOutputDirectoryArg("nuget");
    dotnet_pack.has_side_effects = true;
    b.step("dotnet-pack", "Pack the .NET library with libzpdf for every RID (needs dotnet)").dependOn(
        &b.addInstallDirectory(.{ .source_dir = nuget, .install_dir = .prefix, .install_subdir = "nuget" }).step,
    );
}

const NativeTarget = struct { rid: []const u8, query: std.Target.Query, file: []const u8 };

/// The runtime identifiers .NET packages use, with the file name .NET looks for on each.
const native_targets = [_]NativeTarget{
    .{ .rid = "linux-x64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu }, .file = "libzpdf.so" },
    .{ .rid = "linux-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu }, .file = "libzpdf.so" },
    .{ .rid = "osx-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .file = "libzpdf.dylib" },
    // gnu, so a Linux or macOS machine can build it without MSVC.
    .{ .rid = "win-x64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }, .file = "zpdf.dll" },
};

/// The zpdf module for `target`, with no exports, for a host tool that reads its types.
fn addZpdfModule(b: *std.Build, kb: *std.Build.Dependency, build_options: *std.Build.Step.Options, cid: *const CidMaps, target: std.Build.ResolvedTarget) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    m.addOptions("build_options", build_options);
    m.addOptions("abi_options", abiOptions(b, false, false));
    addKb(b, m, kb, .libc);
    addCidMaps(m, cid, true);
    return m;
}

/// libzpdf: ReleaseSafe with kb's C undefined behaviour set to trap, for the reason zpdf.wasm
/// is (addWasm). In a native process a defect then ends the process, which src/abi.zig's
/// protocol says. kb's symbols are hidden, so only the zpdf_ exports leave the library.
fn addNative(b: *std.Build, kb: *std.Build.Dependency, build_options: *std.Build.Step.Options, cid: *const CidMaps, target: std.Build.ResolvedTarget, strip: bool) *std.Build.Step.Compile {
    const m = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
        .pic = true,
        .sanitize_c = .trap,
        .strip = strip,
    });
    m.addOptions("build_options", build_options);
    m.addOptions("abi_options", abiOptions(b, false, true));
    addKb(b, m, kb, .libc_hidden);
    addCidMaps(m, cid, true);
    return b.addLibrary(.{ .name = "zpdf", .linkage = .dynamic, .root_module = m });
}

/// test_exports: the wasm test build's zpdf_wasm_test_* exports. export_c: export the C ABI
/// from a native build (libzpdf); zpdf.wasm always exports it.
fn abiOptions(b: *std.Build, test_exports: bool, export_c: bool) *std.Build.Step.Options {
    const o = b.addOptions();
    o.addOption(bool, "test_exports", test_exports);
    o.addOption(bool, "export_c", export_c);
    return o;
}

/// zpdf.wasm. ReleaseSafe, with kb's C undefined behaviour set to trap: a defect
/// in Zig or kb then stops the call (and the panic message is kept, see
/// src/abi.zig) instead of going on with bad state, which ReleaseSmall would do
/// for an out-of-bounds read, `unreachable` or an assert. Stripped, since the
/// browser cannot use the debug info.
fn addWasm(b: *std.Build, kb: *std.Build.Dependency, build_options: *std.Build.Step.Options, cid: *const CidMaps, name: []const u8, test_exports: bool) *std.Build.Step.Compile {
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSafe,
        .sanitize_c = .trap,
        .strip = true,
    });
    wasm_mod.addOptions("build_options", build_options);
    wasm_mod.addOptions("abi_options", abiOptions(b, test_exports, false));
    addKb(b, wasm_mod, kb, .no_crt);
    addCidMaps(wasm_mod, cid, false);
    const wasm = b.addExecutable(.{
        .name = name,
        .root_module = wasm_mod,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.export_memory = true;
    return wasm;
}

// kb_text_shape is compiled from src/kb_impl.c. Without a C runtime kb needs
// memset and memcpy from somewhere, and takes its allocator from the caller.
fn addKb(b: *std.Build, mod: *std.Build.Module, kb: *std.Build.Dependency, runtime: enum { no_crt, libc, libc_hidden }) void {
    mod.addIncludePath(kb.path("."));
    mod.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{ "kb_impl.c", "kb_shim.c" },
        .flags = switch (runtime) {
            .no_crt => &.{ "-std=c11", "-DKB_TEXT_SHAPE_NO_CRT", "-DKBTS_MEMSET=__builtin_memset", "-DKBTS_MEMCPY=__builtin_memcpy" },
            .libc => &.{"-std=c11"},
            .libc_hidden => &.{ "-std=c11", "-fvisibility=hidden" },
        },
    });
}

// One zpdf-text run per case and mode, then one golden-check over all of them.
// A row of cases.tsv is: name, font (relative to the harfbuzz package's
// test/, or "-" for a standard font), then zpdf-text arguments;
// `--text-file=X` reads tests/golden/X.
fn addGolden(b: *std.Build, step: *std.Build.Step, text_exe: *std.Build.Step.Compile, harfbuzz: *std.Build.Dependency) void {
    const check_exe = b.addExecutable(.{
        .name = "golden-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/golden-check.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const check = b.addRunArtifact(check_exe);
    check.addFileArg(b.path("tests/golden/sha256.txt"));

    const cases = readRootFile(b, "tests/golden/cases.tsv", 1 << 20) catch |err| {
        std.debug.panic("tests/golden/cases.tsv: {t}", .{err});
    };
    var count: usize = 0;
    var rows = std.mem.splitScalar(u8, cases, '\n');
    while (rows.next()) |row| {
        if (row.len == 0 or row[0] == '#') continue;
        var cols = std.mem.splitScalar(u8, row, '\t');
        const name = cols.next().?;
        const font = cols.next() orelse std.debug.panic("tests/golden/cases.tsv: {s} has no font", .{name});
        const args_start = cols.index;
        for ([_][]const u8{ "", ".plain" }) |mode| {
            const run = b.addRunArtifact(text_exe);
            // "-": a standard font, named by a --standard argument, with no font file.
            if (!std.mem.eql(u8, font, "-")) run.addFileArg(harfbuzz.path(b.fmt("test/{s}", .{font})));
            cols.index = args_start;
            while (cols.next()) |arg| {
                if (std.mem.startsWith(u8, arg, "--text-file=")) {
                    run.addPrefixedFileArg("--text-file=", b.path(b.fmt("tests/golden/{s}", .{arg["--text-file=".len..]})));
                } else {
                    run.addArg(arg);
                }
            }
            if (mode.len != 0) run.addArg("--no-compress");
            const pdf = run.addPrefixedOutputFileArg("--out=", b.fmt("{s}{s}.pdf", .{ name, mode }));
            check.addPrefixedFileArg(b.fmt("{s}{s}=", .{ name, mode }), pdf);
        }
        count += 1;
    }
    if (count == 0) std.debug.panic("tests/golden/cases.tsv has no cases", .{});
    step.dependOn(&check.step);
}

/// Every src/*.zig with a test must be named in root.zig's `test {}` block. With -Dtest-filter,
/// Zig analyses only the tests that match, and a file reached only through another file's
/// declarations is then never analysed: its tests vanish from a filtered run, which still
/// passes (read_text.zig's did until 2026-10-16).
fn checkTestRoots(b: *std.Build) void {
    const root = readRootFile(b, "src/root.zig", 1 << 22) catch |err| std.debug.panic("src/root.zig: {t}", .{err});
    const start = std.mem.indexOf(u8, root, "\ntest {\n") orelse std.debug.panic("src/root.zig has no `test {{` block", .{});
    const block = root[start..][0 .. std.mem.indexOf(u8, root[start..], "\n}\n") orelse std.debug.panic("src/root.zig: `test {{` block not closed", .{})];
    b.dependOnDirectoryContents(b.path("src"));
    var dir = b.root.openDir(b.graph.io, "src", .{ .iterate = true }) catch |err| std.debug.panic("src: {t}", .{err});
    defer dir.close(b.graph.io);
    var it = dir.iterate();
    while (it.next(b.graph.io) catch |err| std.debug.panic("src: {t}", .{err})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig") or std.mem.eql(u8, entry.name, "root.zig")) continue;
        const text = readRootFile(b, b.fmt("src/{s}", .{entry.name}), 1 << 24) catch |err| std.debug.panic("src/{s}: {t}", .{ entry.name, err });
        if (std.mem.indexOf(u8, text, "\ntest \"") == null and !std.mem.startsWith(u8, text, "test \"")) continue;
        const stem = entry.name[0 .. entry.name.len - 4];
        if (std.mem.indexOf(u8, block, b.fmt("_ = {s};", .{stem})) != null) continue;
        if (std.mem.indexOf(u8, block, b.fmt("_ = @import(\"{s}\");", .{entry.name})) != null) continue;
        std.debug.panic("src/{s} has tests but src/root.zig's `test {{` block does not name it: add `_ = @import(\"{s}\");`", .{ entry.name, entry.name });
    }
}

/// A file of zpdf's checkout, read when the build is configured. Zig 0.17 reuses a cached
/// configuration until build.zig or a declared input changes, so every such read declares its file
/// (dependOnFileContents); without that, an edit to the file went unseen.
fn readRootFile(b: *std.Build, sub_path: []const u8, limit: usize) ![]u8 {
    b.dependOnFileContents(b.path(sub_path));
    var dir = try b.root.openDir(b.graph.io, ".", .{});
    defer dir.close(b.graph.io);
    return dir.readFileAlloc(b.graph.io, sub_path, b.allocator, .limited(limit));
}

/// The orderings src/cid has a CID-to-Unicode CMap for (Adobe-<ordering>-UCS2).
const cid_orderings = [_][]const u8{ "Japan1", "GB1", "CNS1", "Korea1", "KR" };

const CidMaps = [cid_orderings.len]std.Build.LazyPath;

/// Each of src/cid's CMaps compiled to a CidTable by tools/gen-cid-table.zig, built for the
/// host once. The tool builds src/read_text.zig as its own module with no tables, so it does
/// not depend on what it makes.
fn packCidMaps(b: *std.Build) CidMaps {
    const read_text = b.createModule(.{
        .root_source_file = b.path("src/read_text.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const no_tables = b.addOptions();
    no_tables.addOption(bool, "cid_tables", false);
    read_text.addOptions("read_options", no_tables);
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen-cid-table.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    gen_mod.addImport("read_text", read_text);
    const gen = b.addExecutable(.{ .name = "gen-cid-table", .root_module = gen_mod });
    var maps: CidMaps = undefined;
    for (cid_orderings, &maps) |ordering, *map| {
        const run = b.addRunArtifact(gen);
        run.addFileArg(b.path(b.fmt("src/cid/Adobe-{s}-UCS2", .{ordering})));
        map.* = run.addOutputFileArg(b.fmt("Adobe-{s}-UCS2.cidtable", .{ordering}));
    }
    return maps;
}

/// `@embedFile("cid_<ordering>")` in the module gives that ordering's CidTable, and the module's
/// `read_options.cid_tables` says whether zpdf.read uses them. zpdf.wasm, whose JS has no
/// reader, leaves them out.
fn addCidMaps(m: *std.Build.Module, maps: *const CidMaps, use: bool) void {
    const o = m.owner.addOptions();
    o.addOption(bool, "cid_tables", use);
    m.addOptions("read_options", o);
    if (!use) return;
    for (cid_orderings, maps) |ordering, map| {
        m.addAnonymousImport(m.owner.fmt("cid_{s}", .{ordering}), .{ .root_source_file = map });
    }
}
