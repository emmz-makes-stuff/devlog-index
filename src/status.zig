//! `status [--json]` (corpus-indexing, Index status; design D9): the
//! workspace, each member's passage count or that it is missing, the files
//! changed since the last update, when that was, and whether the embedding
//! model is cached. Reads the index only, so it works during an update (the
//! index is in WAL mode) and never loads the model.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const workspace = @import("workspace.zig");
const index = @import("index.zig");
const freshness = @import("freshness.zig");
const update = @import("update.zig");

pub const Member = struct {
    name: []const u8,
    path: []const u8,
    /// "ok", "missing" or "no_openspec".
    status: []const u8,
    /// Passages in the index; a missing member's are kept, so it can be > 0.
    passages: usize,
};

pub const Model = struct {
    cached: bool,
    path: []const u8,
};

pub const Status = struct {
    workspace: []const u8,
    root: []const u8,
    index: []const u8,
    indexed: bool,
    members: []const Member,
    files_changed: usize,
    /// UTC, ISO 8601; null before the first update.
    last_update: ?[]const u8,
    model: Model,
};

pub const Error = error{StatusFailed} || Allocator.Error;

pub const Diag = struct {
    message: []const u8 = "",
};

/// Gather the status of `ws`. `model_path` is where the pinned model is
/// cached. A missing index is reported (`indexed` false, every source
/// changed), not an error; an unreadable one is an error.
pub fn gather(arena: Allocator, io: Io, ws: workspace.Workspace, model_path: []const u8, diag: *Diag) Error!Status {
    return gatherInner(arena, io, ws, model_path, diag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (diag.message.len == 0)
            diag.message = try std.fmt.allocPrint(arena, "status failed ({s})", .{@errorName(err)});
        return error.StatusFailed;
    };
}

fn gatherInner(arena: Allocator, io: Io, ws: workspace.Workspace, model_path: []const u8, diag: *Diag) !Status {
    const path = try update.indexPath(arena, ws);
    var idiag: index.Diag = .{};
    var maybe_db: ?@import("db.zig").Db = index.openRead(arena, io, path, &idiag) catch |err| switch (err) {
        error.NoIndex => null,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.message = idiag.message;
            return error.StatusFailed;
        },
    };
    defer if (maybe_db) |*d| d.close();

    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    var last_update: ?[]const u8 = null;
    if (maybe_db) |db| {
        var s = try db.prepare("SELECT f.member, count(p.id) FROM files f LEFT JOIN passages p ON p.file_id = f.id GROUP BY f.member");
        defer s.finalize();
        while (try s.step()) try counts.put(arena, try arena.dupe(u8, s.text(0)), @intCast(s.int(1)));
        if (try index.readSetting(arena, db, "last_update")) |v|
            last_update = try isoUtc(arena, std.fmt.parseInt(i64, v, 10) catch {
                diag.message = try std.fmt.allocPrint(arena, "the index's last_update setting is not a timestamp (\"{s}\"); rebuild it with: {s}", .{ v, index.rebuild_command });
                return error.StatusFailed;
            });
    }

    const members = try arena.alloc(Member, ws.members.len);
    for (ws.members, members) |m, *out| out.* = .{
        .name = m.declared,
        .path = m.path,
        .status = @tagName(m.status),
        .passages = counts.get(std.fs.path.basename(m.path)) orelse 0,
    };

    var fdiag: freshness.Diag = .{};
    const changes = freshness.detect(arena, io, ws, maybe_db, &fdiag) catch |err| switch (err) {
        error.ReadFailed => {
            diag.message = fdiag.message;
            return error.StatusFailed;
        },
        else => return err,
    };
    const cached = if (Io.Dir.cwd().access(io, model_path, .{})) |_| true else |_| false;
    return .{
        .workspace = ws.name,
        .root = ws.root,
        .index = path,
        .indexed = maybe_db != null,
        .members = members,
        .files_changed = changes.total(),
        .last_update = last_update,
        .model = .{ .cached = cached, .path = model_path },
    };
}

fn isoUtc(arena: Allocator, secs: i64) Allocator.Error![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(secs, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

pub fn writeText(s: Status, out: *Io.Writer) Io.Writer.Error!void {
    try out.print("workspace: {s} ({s})\n", .{ s.workspace, s.root });
    if (s.indexed)
        try out.print("index: {s}\n", .{s.index})
    else
        try out.print("index: not built yet; build it with: devlog-index update\n", .{});
    try out.writeAll("members:\n");
    var width: usize = 0;
    for (s.members) |m| width = @max(width, m.name.len);
    for (s.members) |m| {
        try out.print("  {s}", .{m.name});
        try out.splatByteAll(' ', width - m.name.len + 2);
        if (std.mem.eql(u8, m.status, "ok")) {
            try out.print("{d} passages\n", .{m.passages});
        } else {
            const st: workspace.MemberStatus = std.meta.stringToEnum(workspace.MemberStatus, m.status) orelse .missing;
            const why = st.describe();
            try out.print("missing ({s}); {d} indexed passages kept\n", .{ why, m.passages });
        }
    }
    try out.print("files changed since last update: {d}\n", .{s.files_changed});
    try out.print("last update: {s}\n", .{s.last_update orelse "never"});
    if (s.model.cached)
        try out.print("model: cached ({s})\n", .{s.model.path})
    else
        try out.print("model: not cached; the next update downloads it to {s}\n", .{s.model.path});
}

/// One JSON object on one line.
pub fn writeJson(s: Status, out: *Io.Writer) Io.Writer.Error!void {
    try std.json.Stringify.value(s, .{}, out);
    try out.writeByte('\n');
}

// ---- tests ----

const testing = std.testing;
const testutil = @import("testutil.zig");

fn gatherIn(f: *testutil.Fixture, start: []const u8, model_path: []const u8) !Status {
    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, try f.path(start), &wdiag);
    var diag: Diag = .{};
    return gather(f.arena(), testing.io, ws, model_path, &diag) catch |err| {
        std.debug.print("status: {s}: {s}\n", .{ @errorName(err), diag.message });
        return err;
    };
}

fn render(arena: Allocator, s: Status, json: bool) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(arena);
    if (json) try writeJson(s, &buf.writer) else try writeText(s, &buf.writer);
    return buf.written();
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "status: stale index after two notes are added" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    const r = try f.update("", &stub, false);

    const fresh = try gatherIn(&f, "", try f.path("no-model.gguf"));
    try testing.expect(fresh.indexed);
    try testing.expectEqual(@as(usize, 0), fresh.files_changed);
    try testing.expect(fresh.last_update != null);
    try testing.expectEqual(r.passages_total, fresh.members[0].passages + fresh.members[1].passages);
    try testing.expect(fresh.members[0].passages > 0 and fresh.members[1].passages > 0);

    try f.write("alpha/openspec/changes/add-cache/devlog/20260402-0900-decision-a.md", "# A\n\nOne.\n");
    try f.write("alpha/openspec/changes/add-cache/devlog/20260402-0910-decision-b.md", "# B\n\nTwo.\n");
    const stale = try gatherIn(&f, "beta", try f.path("no-model.gguf"));
    try testing.expectEqual(@as(usize, 2), stale.files_changed);

    const text = try render(f.arena(), stale, false);
    try testing.expect(contains(text, "workspace: fixture ("));
    try testing.expect(contains(text, "files changed since last update: 2\n"));
    try testing.expect(contains(text, "model: not cached"));

    const json = try render(f.arena(), stale, true);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, "\n"));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, f.arena(), json, .{});
    try testing.expectEqual(@as(i64, 2), parsed.object.get("files_changed").?.integer);
    try testing.expectEqualStrings("fixture", parsed.object.get("workspace").?.string);
    try testing.expectEqual(false, parsed.object.get("model").?.object.get("cached").?.bool);
    try testing.expectEqual(@as(usize, 2), parsed.object.get("members").?.array.items.len);
}

test "status: a missing member is reported with its kept passages" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    const beta_passages = (try gatherIn(&f, "", "x")).members[1].passages;

    try f.tmp.dir.rename("beta", f.tmp.dir, "beta-moved", testing.io);
    const s = try gatherIn(&f, "alpha", "x");
    try testing.expectEqualStrings("beta", s.members[1].name);
    try testing.expectEqualStrings("missing", s.members[1].status);
    try testing.expectEqual(beta_passages, s.members[1].passages);
    try testing.expectEqualStrings("ok", s.members[0].status);
    try testing.expectEqual(@as(usize, 0), s.files_changed);

    const text = try render(f.arena(), s, false);
    try testing.expect(contains(text, "beta   missing (not found);"));
    const json = try render(f.arena(), s, true);
    try testing.expect(contains(json, "\"status\":\"missing\""));
}

test "status: no index yet, model cached" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    try f.write("model.gguf", "not really a model");
    const s = try gatherIn(&f, "", try f.path("model.gguf"));
    try testing.expect(!s.indexed);
    try testing.expectEqual(@as(usize, 19), s.files_changed);
    try testing.expect(s.last_update == null);
    try testing.expect(s.model.cached);
    const text = try render(f.arena(), s, false);
    try testing.expect(contains(text, "index: not built yet; build it with: devlog-index update\n"));
    try testing.expect(contains(text, "last update: never\n"));
    try testing.expect(contains(text, "model: cached ("));
    try testing.expect(contains(try render(f.arena(), s, true), "\"last_update\":null"));
}

test "status: an index with another schema is an error naming the rebuild" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    {
        var db = try @import("db.zig").Db.open(try std.fs.path.joinZ(f.arena(), &.{ f.root, ".devlog-index", "index.db" }), .read_write_create);
        defer db.close();
        try db.exec("UPDATE settings SET value = '0' WHERE key = 'schema_version'");
    }
    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, f.root, &wdiag);
    var diag: Diag = .{};
    try testing.expectError(error.StatusFailed, gather(f.arena(), testing.io, ws, "x", &diag));
    try testing.expect(contains(diag.message, index.rebuild_command));
}

test "isoUtc" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("2026-10-09T15:39:05Z", try isoUtc(arena_state.allocator(), 1791560345));
}

test "status: a corrupt last_update setting fails with a message naming the rebuild" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    try f.exec("UPDATE settings SET value = 'soon' WHERE key = 'last_update'");
    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, f.root, &wdiag);
    var diag: Diag = .{};
    try testing.expectError(error.StatusFailed, gather(f.arena(), testing.io, ws, "/nonexistent/model.gguf", &diag));
    try testing.expectEqualStrings("the index's last_update setting is not a timestamp (\"soon\"); rebuild it with: " ++ index.rebuild_command, diag.message);
}
