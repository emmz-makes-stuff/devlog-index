//! CLI integration tests (design D10): run the built binary against a temp
//! copy of the fixture and check its streams and exit codes. The index is
//! built through the library with the stub embedder, so the binary sees an
//! index from another model and every query degrades to lexical with a
//! notice; HOME points at an empty temp dir so no real model is touched.

const std = @import("std");
const testing = std.testing;
const testutil = @import("testutil.zig");

const Run = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

/// Runs the binary in `cwd` with HOME set to `home` and nothing else in its
/// environment.
fn cli(arena: std.mem.Allocator, cwd: []const u8, home: []const u8, args: []const []const u8) !Run {
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    // The build passes the exe relative to the build root (the test's cwd);
    // the child runs elsewhere.
    const exe = try std.fs.path.resolve(arena, &.{ try std.process.currentPathAlloc(testing.io, arena), @import("test_options").exe });
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{exe}, args });
    const r = try std.process.run(arena, testing.io, .{ .argv = argv, .cwd = .{ .path = cwd }, .environ_map = &env });
    return switch (r.term) {
        .exited => |code| .{ .code = code, .stdout = r.stdout, .stderr = r.stderr },
        else => error.ChildDidNotExit,
    };
}

/// The fixture, indexed with the stub, plus an empty HOME inside it.
fn indexed(f: *testutil.Fixture) ![]const u8 {
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    try f.write("home/.keep", "");
    return f.path("home");
}

test "cli: query --json writes only JSON lines to stdout, notices to stderr" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    const home = try indexed(&f);

    const r = try cli(f.arena(), f.root, home, &.{ "query", "--json", "thundering-herd argument" });
    try testing.expectEqual(@as(u8, 0), r.code);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.stdout, "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, f.arena(), line, .{});
        try testing.expect(v.object.get("notices").?.array.items.len > 0);
    }
    try testing.expect(n > 0);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "devlog-index: notice: ") != null);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "built with model test://stub") != null);
}

test "cli: status exits 0" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    const home = try indexed(&f);

    const r = try cli(f.arena(), f.root, home, &.{"status"});
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(r.stdout.len > 0);
}

test "cli: eval without a golden set exits 1" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    const home = try indexed(&f);

    const r = try cli(f.arena(), f.root, home, &.{"eval"});
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expect(std.mem.startsWith(u8, r.stderr, "devlog-index: "));
    try testing.expect(std.mem.indexOf(u8, r.stderr, "golden.json") != null);
}

test "cli: a command outside any workspace exits 1" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try outside.dir.realPath(testing.io, &buf);

    const r = try cli(f.arena(), buf[0..n], buf[0..n], &.{"status"});
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "init") != null);
    try testing.expectEqual(@as(usize, 0), r.stdout.len);
}

test "cli: usage errors exit 2" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    const home = try indexed(&f);

    const cases: []const []const []const u8 = &.{
        &.{"query"},
        &.{ "query", "--k", "0", "x" },
        &.{ "query", "--jsno", "retry policy" },
        &.{ "update", "--json" },
        &.{"init"},
        &.{ "status", "--bogus" },
        &.{"no-such-command"},
    };
    for (cases) |args| {
        const r = try cli(f.arena(), f.root, home, args);
        testing.expectEqual(@as(u8, 2), r.code) catch |err| {
            std.debug.print("args: {f}\n", .{std.json.fmt(args, .{})});
            return err;
        };
        try testing.expectEqual(@as(usize, 0), r.stdout.len);
    }
}
