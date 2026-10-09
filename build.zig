const std = @import("std");

/// Mirrors `Backend` in the llama.cpp.zig fork's build.zig, so a typed value
/// can be passed into `b.dependency(...)` (Zig 0.16 wants the type).
const LlamaBackend = enum(u8) { cpu, vulkan, metal };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip_default = optimize == .ReleaseFast or optimize == .ReleaseSmall;
    const strip = b.option(bool, "strip", "Strip symbols from the final binary") orelse strip_default;

    // ---- Vendored C libraries (static, linked into the final exe) ----

    const sqlite_lib = buildSqlite(b, target, optimize);
    const sqlite_vec_lib = buildSqliteVec(b, target, optimize);

    // ---- llama.cpp bindings (daemonicai fork pinned in build.zig.zon) ----
    // CPU-only, as memlite: no Metal sidecar files, self-contained binary.
    const llama_dep = b.dependency("llama_cpp_zig", .{
        .target = target,
        .optimize = optimize,
        .backend = @as(LlamaBackend, .cpu),
    });
    const llama_lib = llama_dep.artifact("llama_cpp");

    // ---- devlog-index executable ----

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });
    exe_mod.addIncludePath(b.path("third_party/sqlite"));
    exe_mod.addIncludePath(b.path("third_party/sqlite-vec"));
    exe_mod.linkLibrary(sqlite_lib);
    exe_mod.linkLibrary(sqlite_vec_lib);
    exe_mod.linkLibrary(llama_lib);
    exe_mod.addImport("llama_c", llama_dep.module("c"));

    const exe = b.addExecutable(.{
        .name = "devlog-index",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run devlog-index");
    run_step.dependOn(&run_cmd.step);

    // Test-only paths; referenced from `test` blocks only, so they never reach
    // the release binary.
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "fixture_workspace", b.pathFromRoot("test/fixtures/workspace"));
    exe_mod.addOptions("test_options", test_options);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

fn buildSqlite(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("third_party/sqlite"));
    mod.addCSourceFile(.{
        .file = b.path("third_party/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
            "-DSQLITE_MAX_EXPR_DEPTH=0",
            "-DSQLITE_OMIT_DECLTYPE",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_PROGRESS_CALLBACK",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-DSQLITE_USE_ALLOCA",
            "-w",
        },
    });
    return b.addLibrary(.{
        .linkage = .static,
        .name = "sqlite3",
        .root_module = mod,
    });
}

fn buildSqliteVec(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("third_party/sqlite"));
    mod.addIncludePath(b.path("third_party/sqlite-vec"));
    mod.addCSourceFile(.{
        .file = b.path("third_party/sqlite-vec/sqlite-vec.c"),
        .flags = &.{
            "-DSQLITE_CORE",
            "-w",
        },
    });
    return b.addLibrary(.{
        .linkage = .static,
        .name = "sqlite-vec",
        .root_module = mod,
    });
}
