//! Source discovery: which files under each member's `openspec/` are indexed
//! (corpus-indexing, Indexed sources).
//!
//! Indexed: devlog notes, proposal/design/tasks of active and archived
//! changes, spec deltas of active changes, and main specs. Not indexed:
//! archived spec deltas, legacy `DEVLOG.md`, anything else.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const workspace = @import("workspace.zig");

pub const Artifact = enum {
    note,
    proposal,
    design,
    tasks,
    spec,
    spec_delta,
};

/// What a path under `openspec/` is, if it is indexed. Slices point into the
/// classified path.
pub const Class = struct {
    artifact: Artifact,
    /// Change name; archived changes have their `YYYY-MM-DD-` prefix stripped.
    change: ?[]const u8 = null,
    archived: bool = false,
    /// `specs/<capability>/spec.md`; may contain `/` for nested capabilities.
    capability: ?[]const u8 = null,
};

pub const Source = struct {
    /// Basename of the member's resolved path.
    member: []const u8,
    /// Absolute path of the file.
    path: []const u8,
    /// Relative to the member root, `/`-separated (`openspec/...`).
    rel: []const u8,
    class: Class,
};

/// `rel` is relative to a member's `openspec/` directory, `/`-separated.
pub fn classify(rel: []const u8) ?Class {
    if (!std.mem.endsWith(u8, rel, ".md")) return null;

    if (std.mem.startsWith(u8, rel, "specs/")) {
        const cap = specCapability(rel["specs/".len..]) orelse return null;
        return .{ .artifact = .spec, .capability = cap };
    }

    if (!std.mem.startsWith(u8, rel, "changes/")) return null;
    var rest = rel["changes/".len..];
    var archived = false;
    if (std.mem.startsWith(u8, rest, "archive/")) {
        archived = true;
        rest = rest["archive/".len..];
    }
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const dir = rest[0..slash];
    const inner = rest[slash + 1 ..];
    const change = if (archived) stripDatePrefix(dir) else dir;
    const base: Class = .{ .artifact = .note, .change = change, .archived = archived };

    if (std.mem.eql(u8, inner, "proposal.md")) return withArtifact(base, .proposal);
    if (std.mem.eql(u8, inner, "design.md")) return withArtifact(base, .design);
    if (std.mem.eql(u8, inner, "tasks.md")) return withArtifact(base, .tasks);
    if (std.mem.startsWith(u8, inner, "devlog/")) {
        if (std.mem.indexOfScalar(u8, inner["devlog/".len..], '/') != null) return null;
        return base;
    }
    if (std.mem.startsWith(u8, inner, "specs/")) {
        if (archived) return null;
        var c = withArtifact(base, .spec_delta);
        c.capability = specCapability(inner["specs/".len..]) orelse return null;
        return c;
    }
    return null;
}

fn withArtifact(c: Class, a: Artifact) Class {
    var out = c;
    out.artifact = a;
    return out;
}

fn specCapability(s: []const u8) ?[]const u8 {
    const suffix = "/spec.md";
    if (!std.mem.endsWith(u8, s, suffix)) return null;
    const cap = s[0 .. s.len - suffix.len];
    return if (cap.len == 0) null else cap;
}

/// `2026-03-10-add-retry` → `add-retry`; anything else is returned unchanged.
pub fn stripDatePrefix(dir: []const u8) []const u8 {
    if (dir.len <= 11) return dir;
    for (dir[0..11], 0..) |c, i| {
        const want_dash = i == 4 or i == 7 or i == 10;
        if (want_dash) {
            if (c != '-') return dir;
        } else if (!std.ascii.isDigit(c)) return dir;
    }
    return dir[11..];
}

/// Every indexed file of every member whose status is `ok`, sorted by path.
/// Symlinked files and directories are followed and indexed at the link's
/// path; a directory whose target was already visited is skipped, so a loop
/// ends. A link that leads nowhere (or loops on itself) is skipped, and its
/// path is appended to `broken` when given.
pub fn discover(arena: Allocator, io: Io, ws: workspace.Workspace, broken: ?*std.ArrayList([]const u8)) ![]Source {
    var w: Walk = .{ .arena = arena, .io = io, .broken = broken };
    for (ws.members) |m| {
        if (m.status != .ok) continue;
        w.member = std.fs.path.basename(m.path);
        w.openspec = try std.fs.path.join(arena, &.{ m.path, "openspec" });
        try w.dir(w.openspec, "");
    }
    std.mem.sort(Source, w.list.items, {}, lessByPath);
    return w.list.items;
}

const Walk = struct {
    arena: Allocator,
    io: Io,
    broken: ?*std.ArrayList([]const u8),
    member: []const u8 = "",
    openspec: []const u8 = "",
    list: std.ArrayList(Source) = .empty,
    /// Real paths of the directories walked so far.
    visited: std.StringHashMapUnmanaged(void) = .empty,

    /// `rel` is `abs` relative to the member's `openspec/`, `/`-separated.
    fn dir(w: *Walk, abs: []const u8, rel: []const u8) !void {
        const real = try Io.Dir.cwd().realPathFileAlloc(w.io, abs, w.arena);
        if ((try w.visited.getOrPut(w.arena, real)).found_existing) return;

        var d = try Io.Dir.cwd().openDir(w.io, abs, .{ .iterate = true });
        defer d.close(w.io);
        // By name, so which path wins an already-visited target is the same
        // on every run.
        var entries: std.ArrayList(Io.Dir.Entry) = .empty;
        var it = d.iterate();
        while (try it.next(w.io)) |entry|
            try entries.append(w.arena, .{ .name = try w.arena.dupe(u8, entry.name), .kind = entry.kind, .inode = entry.inode });
        std.mem.sort(Io.Dir.Entry, entries.items, {}, lessByName);
        for (entries.items) |entry| {
            const child_abs = try std.fs.path.join(w.arena, &.{ abs, entry.name });
            const child_rel = if (rel.len == 0)
                try w.arena.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(w.arena, "{s}/{s}", .{ rel, entry.name });
            switch (entry.kind) {
                .directory => try w.dir(child_abs, child_rel),
                .file => try w.file(child_abs, child_rel),
                .sym_link => {
                    const st = d.statFile(w.io, entry.name, .{}) catch |err| switch (err) {
                        error.FileNotFound, error.NotDir, error.SymLinkLoop => {
                            if (w.broken) |b| try b.append(w.arena, child_abs);
                            continue;
                        },
                        else => |e| return e,
                    };
                    switch (st.kind) {
                        .directory => try w.dir(child_abs, child_rel),
                        .file => try w.file(child_abs, child_rel),
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    fn file(w: *Walk, abs: []const u8, rel: []const u8) !void {
        const class = classify(rel) orelse return;
        try w.list.append(w.arena, .{
            .member = w.member,
            .path = abs,
            .rel = try std.fmt.allocPrint(w.arena, "openspec/{s}", .{rel}),
            .class = class,
        });
    }
};

fn lessByName(_: void, a: Io.Dir.Entry, b: Io.Dir.Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn lessByPath(_: void, a: Source, b: Source) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

// ---- tests ----

const testing = std.testing;

test "classify: indexed and excluded paths" {
    const ok = [_]struct { rel: []const u8, want: Class }{
        .{ .rel = "specs/auth/spec.md", .want = .{ .artifact = .spec, .capability = "auth" } },
        .{ .rel = "specs/a/b/spec.md", .want = .{ .artifact = .spec, .capability = "a/b" } },
        .{ .rel = "changes/add-cache/proposal.md", .want = .{ .artifact = .proposal, .change = "add-cache" } },
        .{ .rel = "changes/add-cache/design.md", .want = .{ .artifact = .design, .change = "add-cache" } },
        .{ .rel = "changes/add-cache/tasks.md", .want = .{ .artifact = .tasks, .change = "add-cache" } },
        .{ .rel = "changes/add-cache/specs/cache/spec.md", .want = .{ .artifact = .spec_delta, .change = "add-cache", .capability = "cache" } },
        .{ .rel = "changes/add-cache/devlog/20260401-1000-decision-cache-ttl.md", .want = .{ .artifact = .note, .change = "add-cache" } },
        .{ .rel = "changes/archive/2026-03-10-add-retry/design.md", .want = .{ .artifact = .design, .change = "add-retry", .archived = true } },
        .{ .rel = "changes/archive/x/devlog/20260312-0915-stopped-2-1-needs-credentials.md", .want = .{ .artifact = .note, .change = "x", .archived = true } },
    };
    for (ok) |case| {
        const got = classify(case.rel) orelse {
            std.debug.print("{s}: not classified\n", .{case.rel});
            return error.TestExpectedClass;
        };
        try testing.expectEqual(case.want.artifact, got.artifact);
        try testing.expectEqual(case.want.archived, got.archived);
        try expectOptStr(case.want.change, got.change);
        try expectOptStr(case.want.capability, got.capability);
    }

    const excluded = [_][]const u8{
        "changes/archive/2026-03-10-add-retry/specs/auth/spec.md", // archived delta
        "changes/archive/2026-03-10-add-retry/DEVLOG.md", // legacy devlog
        "changes/add-cache/DEVLOG.md",
        "project.md",
        "config.yaml",
        "specs/auth/notes.md",
        "specs/spec.md",
        "changes/add-cache/devlog/sub/x.md",
        "changes/add-cache/notes.md",
        "changes/proposal.md",
    };
    for (excluded) |rel| {
        if (classify(rel) != null) {
            std.debug.print("{s}: should be excluded\n", .{rel});
            return error.TestExpectedExcluded;
        }
    }
}

fn expectOptStr(want: ?[]const u8, got: ?[]const u8) !void {
    if (want) |w| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(w, got.?);
    } else try testing.expect(got == null);
}

test "stripDatePrefix" {
    try testing.expectEqualStrings("add-retry", stripDatePrefix("2026-03-10-add-retry"));
    try testing.expectEqualStrings("add-retry", stripDatePrefix("add-retry"));
    try testing.expectEqualStrings("2026-03-10", stripDatePrefix("2026-03-10"));
    try testing.expectEqualStrings("2026-3-10-x-yz", stripDatePrefix("2026-3-10-x-yz"));
}

test "discover lists exactly the fixture's indexed files" {
    const test_options = @import("test_options");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diag: workspace.Diag = .{};
    const ws = try workspace.resolve(arena, testing.io, test_options.fixture_workspace, &diag);
    const found = try discover(arena, testing.io, ws, null);

    const want = [_][]const u8{
        "alpha/openspec/changes/add-cache/devlog/20260401-1000-decision-cache-ttl.md",
        "alpha/openspec/changes/add-cache/proposal.md",
        "alpha/openspec/changes/add-cache/specs/cache/spec.md",
        "alpha/openspec/changes/add-cache/tasks.md",
        "alpha/openspec/changes/archive/2026-03-10-add-retry/design.md",
        "alpha/openspec/changes/archive/2026-03-10-add-retry/devlog/20260310-0900-section-1-start.md",
        "alpha/openspec/changes/archive/2026-03-10-add-retry/devlog/20260310-1015-decision-retry-policy.md",
        "alpha/openspec/changes/archive/2026-03-10-add-retry/devlog/20260311-1400-section-1-done.md",
        "alpha/openspec/changes/archive/2026-03-10-add-retry/devlog/20260312-0915-stopped-2-1-needs-credentials.md",
        "alpha/openspec/changes/archive/2026-03-10-add-retry/devlog/20260312-1100-answer-credentials.md",
        "alpha/openspec/changes/archive/2026-03-10-add-retry/devlog/20260313-1030-decision-retry-reversal.md",
        "alpha/openspec/changes/archive/2026-03-10-add-retry/devlog/20260314-0900-review-section-1.md",
        "alpha/openspec/changes/archive/2026-03-10-add-retry/proposal.md",
        "alpha/openspec/changes/archive/2026-03-10-add-retry/tasks.md",
        "alpha/openspec/specs/auth/spec.md",
        "beta/openspec/changes/archive/2026-03-20-init-api/devlog/20260315-0800-section-1-start.md",
        "beta/openspec/changes/archive/2026-03-20-init-api/devlog/20260320-1200-change-done.md",
        "beta/openspec/changes/archive/2026-03-20-init-api/proposal.md",
        "beta/openspec/specs/api/spec.md",
    };
    var got: std.ArrayList([]const u8) = .empty;
    for (found) |s| try got.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ s.member, s.rel }));
    if (got.items.len != want.len) {
        for (got.items) |g| std.debug.print("  found {s}\n", .{g});
        return error.TestUnexpectedSources;
    }
    for (want, got.items) |w, g| try testing.expectEqualStrings(w, g);

    // Absolute paths point at the files and archived metadata is carried.
    for (found) |s| {
        try testing.expect(std.mem.startsWith(u8, s.path, ws.root));
        try Io.Dir.cwd().access(testing.io, s.path, .{});
    }
    try testing.expect(found[4].class.archived);
    try testing.expectEqualStrings("add-retry", found[4].class.change.?);
}

test "discover follows symlinked files and directories, skips a loop, reports a broken link" {
    const testutil = @import("testutil.zig");
    var f = try testutil.Fixture.init();
    defer f.deinit();
    const d = f.tmp.dir;
    const io = testing.io;

    try f.write("elsewhere/20260402-0900-decision-linked.md", "# Linked\n\nA note kept outside the tree.\n");
    try f.write("elsewhere/specs/linked/spec.md", "# Linked spec\n\nA spec kept outside the tree.\n");
    try d.symLink(io, try f.path("elsewhere/20260402-0900-decision-linked.md"), "alpha/openspec/changes/add-cache/devlog/20260402-0900-decision-linked.md", .{});
    try d.symLink(io, try f.path("elsewhere/specs/linked"), "beta/openspec/specs/linked", .{ .is_directory = true });
    try d.symLink(io, try f.path("alpha/openspec/specs"), "alpha/openspec/specs/auth/loop", .{ .is_directory = true });
    try d.symLink(io, try f.path("elsewhere/gone.md"), "alpha/openspec/changes/add-cache/devlog/20260403-0900-note-gone.md", .{});

    var diag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), io, f.root, &diag);
    var broken: std.ArrayList([]const u8) = .empty;
    const found = try discover(f.arena(), io, ws, &broken);

    try testing.expectEqual(@as(usize, 21), found.len);
    var note = false;
    var spec = false;
    for (found) |s| {
        try testing.expect(std.mem.indexOf(u8, s.rel, "/loop/") == null);
        if (std.mem.eql(u8, s.rel, "openspec/changes/add-cache/devlog/20260402-0900-decision-linked.md")) {
            note = true;
            try testing.expectEqual(Artifact.note, s.class.artifact);
        }
        if (std.mem.eql(u8, s.rel, "openspec/specs/linked/spec.md")) {
            spec = true;
            try testing.expectEqualStrings("beta", s.member);
            try testing.expectEqualStrings("linked", s.class.capability.?);
        }
    }
    try testing.expect(note and spec);
    try testing.expectEqual(@as(usize, 1), broken.items.len);
    try testing.expect(std.mem.endsWith(u8, broken.items[0], "20260403-0900-note-gone.md"));

    // update indexes the linked files and reports the broken link.
    var stub: testutil.Stub = .{};
    const r = try f.update("", &stub, false);
    try testing.expectEqual(@as(usize, 21), r.added);
    try testing.expectEqual(@as(usize, 1), r.broken_links.len);
}
