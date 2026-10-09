//! Freshness without a watcher (design D9): how many files differ between
//! the workspace and the index, so `status` and `query` report a stale index
//! rather than silently using it.
//!
//! A file counts as changed when it is new, gone, or its content differs.
//! Size and mtime decide cheaply; the content is hashed only when either
//! differs from what the index recorded, so a touched but identical file is
//! not counted. Files under a member that is missing right now are not
//! counted as gone, matching `update`, which keeps their passages.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const workspace = @import("workspace.zig");
const sources = @import("sources.zig");
const dbm = @import("db.zig");
const update = @import("update.zig");

pub const Changes = struct {
    added: usize = 0,
    changed: usize = 0,
    removed: usize = 0,

    pub fn total(c: Changes) usize {
        return c.added + c.changed + c.removed;
    }
};

const Indexed = struct {
    hash: []const u8,
    size: i64,
    mtime_ns: i64,
    seen: bool = false,
};

pub const Diag = struct {
    message: []const u8 = "",
};

/// Compare the workspace's sources with the index's `files` table. With no
/// index (`db` null) every source counts as added. A file that cannot be
/// read is `error.ReadFailed`, with `diag.message` naming it.
pub fn detect(arena: Allocator, io: Io, ws: workspace.Workspace, db: ?dbm.Db, diag: *Diag) !Changes {
    var indexed: std.StringHashMapUnmanaged(Indexed) = .empty;
    if (db) |d| {
        var s = try d.prepare("SELECT path, hash, size, mtime_ns FROM files");
        defer s.finalize();
        while (try s.step()) {
            try indexed.put(arena, try arena.dupe(u8, s.text(0)), .{
                .hash = try arena.dupe(u8, s.text(1)),
                .size = s.int(2),
                .mtime_ns = s.int(3),
            });
        }
    }

    var c: Changes = .{};
    const cwd = Io.Dir.cwd();
    for (try sources.discover(arena, io, ws)) |src| {
        const old = indexed.getPtr(src.path) orelse {
            c.added += 1;
            continue;
        };
        old.seen = true;
        const st = cwd.statFile(io, src.path, .{}) catch |err| switch (err) {
            // Gone since discovery: left unseen, so it counts as removed.
            error.FileNotFound, error.NotDir => {
                old.seen = false;
                continue;
            },
            else => return readFailed(arena, diag, src.path, err),
        };
        if (st.size == old.size and st.mtime.nanoseconds == old.mtime_ns) continue;
        const text = cwd.readFileAlloc(io, src.path, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                old.seen = false;
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => return readFailed(arena, diag, src.path, err),
        };
        if (!std.mem.eql(u8, &update.hashHex(text), old.hash)) c.changed += 1;
    }

    var missing: std.ArrayList(workspace.Member) = .empty;
    for (ws.members) |m| if (m.status != .ok) try missing.append(arena, m);
    var it = indexed.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.seen) continue;
        if (underMissingMember(entry.key_ptr.*, missing.items)) continue;
        c.removed += 1;
    }
    return c;
}

fn readFailed(arena: Allocator, diag: *Diag, path: []const u8, err: anyerror) error{ ReadFailed, OutOfMemory } {
    diag.message = try std.fmt.allocPrint(arena, "cannot read {s} ({s})", .{ path, @errorName(err) });
    return error.ReadFailed;
}

/// Whether `path` lies inside one of the `missing` members.
pub fn underMissingMember(path: []const u8, missing: []const workspace.Member) bool {
    for (missing) |m| {
        if (std.mem.startsWith(u8, path, m.path) and path.len > m.path.len and path[m.path.len] == std.fs.path.sep)
            return true;
    }
    return false;
}

// ---- tests ----

const testing = std.testing;
const testutil = @import("testutil.zig");

fn detectIn(f: *testutil.Fixture, start: []const u8) !Changes {
    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, try f.path(start), &wdiag);
    var db = try f.db();
    defer db.close();
    var diag: Diag = .{};
    return detect(f.arena(), testing.io, ws, db, &diag);
}

test "freshness: a just-updated index has no changes; two added notes are two changes" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    try testing.expectEqual(@as(usize, 0), (try detectIn(&f, "")).total());

    try f.write("alpha/openspec/changes/add-cache/devlog/20260402-0900-decision-a.md", "# A\n\nOne.\n");
    try f.write("beta/openspec/changes/archive/2026-03-20-init-api/devlog/20260402-0901-decision-b.md", "# B\n\nTwo.\n");
    const c = try detectIn(&f, "beta");
    try testing.expectEqual(@as(usize, 2), c.added);
    try testing.expectEqual(@as(usize, 2), c.total());
}

test "freshness: edited and deleted files count; a touched identical file does not" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);

    const design = "alpha/openspec/changes/archive/2026-03-10-add-retry/design.md";
    const old = try f.tmp.dir.readFileAlloc(testing.io, design, f.arena(), .unlimited);
    try f.write(design, old); // same bytes, new mtime
    try testing.expectEqual(@as(usize, 0), (try detectIn(&f, "")).total());

    try f.write(design, try std.fmt.allocPrint(f.arena(), "{s}\nMore.\n", .{old}));
    try f.tmp.dir.deleteFile(testing.io, "alpha/openspec/changes/add-cache/proposal.md");
    const c = try detectIn(&f, "");
    try testing.expectEqual(@as(usize, 1), c.changed);
    try testing.expectEqual(@as(usize, 1), c.removed);
    try testing.expectEqual(@as(usize, 0), c.added);
}

test "freshness: a missing member's files are not counted as removed" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    try f.tmp.dir.rename("beta", f.tmp.dir, "beta-moved", testing.io);
    try testing.expectEqual(@as(usize, 0), (try detectIn(&f, "")).total());
}
