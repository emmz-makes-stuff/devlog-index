//! Test helpers shared by the module tests: a stub embedder and a temp copy
//! of the fixture workspace (design D10).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const workspace = @import("workspace.zig");
const dbm = @import("db.zig");
const update_mod = @import("update.zig");
const Provider = update_mod.Provider;
const Embedder = update_mod.Embedder;

/// Deterministic 8-d vectors from the text's hash; counts calls and can be
/// told to fail on load or after N embeddings.
pub const Stub = struct {
    fail_load: bool = false,
    fail_after: ?usize = null,
    /// Vectors one element short of the 8 dimensions it reports.
    short_vectors: bool = false,
    loads: usize = 0,
    embeds: usize = 0,

    pub fn provider(s: *Stub) Provider {
        return .{ .ptr = s, .getFn = get };
    }

    fn get(ptr: *anyopaque) anyerror!Embedder {
        const s: *Stub = @ptrCast(@alignCast(ptr));
        s.loads += 1;
        if (s.fail_load) return error.ModelLoadFailed;
        return .{ .ptr = s, .dim = 8, .embedFn = embedFn };
    }

    fn embedFn(ptr: *anyopaque, gpa: Allocator, text: []const u8) anyerror![]f32 {
        const s: *Stub = @ptrCast(@alignCast(ptr));
        if (s.fail_after) |n| if (s.embeds >= n) return error.Interrupted;
        s.embeds += 1;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
        const v = try gpa.alloc(f32, if (s.short_vectors) 7 else 8);
        var sum: f32 = 0;
        for (v, 0..) |*x, i| {
            x.* = @as(f32, @floatFromInt(digest[i])) - 127.5;
            sum += x.* * x.*;
        }
        for (v) |*x| x.* /= @sqrt(sum);
        return v;
    }
};

pub const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8,

    pub fn init() !Fixture {
        var f: Fixture = .{ .arena_state = .init(testing.allocator), .tmp = testing.tmpDir(.{}), .root = "" };
        errdefer f.deinit();
        const a = f.arena_state.allocator();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try f.tmp.dir.realPath(testing.io, &buf);
        f.root = try a.dupe(u8, buf[0..n]);
        try copyTree(a, @import("test_options").fixture_workspace, f.tmp.dir);
        return f;
    }

    pub fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena_state.deinit();
    }

    pub fn arena(f: *Fixture) Allocator {
        return f.arena_state.allocator();
    }

    pub fn path(f: *Fixture, rel: []const u8) ![]const u8 {
        return std.fs.path.join(f.arena(), &.{ f.root, rel });
    }

    /// Resolve from `start` (relative to the fixture root) and update.
    pub fn update(f: *Fixture, start: []const u8, stub: *Stub, rebuild: bool) !update_mod.Report {
        var wdiag: workspace.Diag = .{};
        const ws = try workspace.resolve(f.arena(), testing.io, try f.path(start), &wdiag);
        var diag: update_mod.Diag = .{};
        return update_mod.run(f.arena(), testing.allocator, testing.io, ws, .{ .provider = stub.provider(), .rebuild = rebuild, .model_url = "test://stub" }, &diag) catch |err| {
            std.debug.print("update: {s}: {s}\n", .{ @errorName(err), diag.message });
            return err;
        };
    }

    pub fn db(f: *Fixture) !dbm.Db {
        return dbm.Db.open(try std.fs.path.joinZ(f.arena(), &.{ f.root, ".devlog-index", "index.db" }), .read_only);
    }

    /// Runs `sql` against the index, read-write.
    pub fn exec(f: *Fixture, sql: [:0]const u8) !void {
        var d = try dbm.Db.open(try std.fs.path.joinZ(f.arena(), &.{ f.root, ".devlog-index", "index.db" }), .read_write_create);
        defer d.close();
        try d.exec(sql);
    }

    pub fn count(f: *Fixture, sql: []const u8) !i64 {
        var d = try f.db();
        defer d.close();
        return (try d.oneInt(sql)).?;
    }

    pub fn write(f: *Fixture, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |p| try f.tmp.dir.createDirPath(testing.io, p);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }
};

fn copyTree(arena: Allocator, src_root: []const u8, dst: Io.Dir) !void {
    var src = try Io.Dir.cwd().openDir(testing.io, src_root, .{ .iterate = true });
    defer src.close(testing.io);
    var walker = try src.walk(arena);
    defer walker.deinit();
    while (try walker.next(testing.io)) |entry| switch (entry.kind) {
        .directory => try dst.createDirPath(testing.io, entry.path),
        .file => try src.copyFile(entry.path, dst, entry.path, testing.io, .{}),
        else => {},
    };
}
