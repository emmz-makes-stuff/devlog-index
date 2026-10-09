//! `query [--json] [--k N] "<ext>"` (workspace-query; design D6).
//!
//! Ranks passages two ways — FTS5 `bm25()` over the passage text and cosine
//! over the `vec0` vectors — and returns the union of each method's top k,
//! de-duplicated, each result labelled with the method(s) that found it.
//! Passages found by both come first, then the rest alternate lexical and
//! semantic by their own rank.
//!
//! A query never presents partial results as complete: when semantic search
//! cannot run (model not cached or failing to load, another model, no
//! vectors) the lexical results come with a notice saying why, and a stale
//! index (files changed since the last update) comes with a notice counting
//! them. A missing index is an error naming `update`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const workspace = @import("workspace.zig");
const dbm = @import("db.zig");
const index = @import("index.zig");
const freshness = @import("freshness.zig");
const update = @import("update.zig");
const model_url = @import("model_url.zig");

pub const default_k = 5;
pub const max_k = 100;

pub const Options = struct {
    text: []const u8,
    /// Results per method; the union holds at most 2k.
    k: usize = default_k,
    /// The model this binary embeds with; the index must match it.
    model_url: []const u8 = model_url.pinned_url,
    /// Supplies the query embedder (query task); null skips semantic search.
    provider: ?update.Provider,
};

/// A later note in the same change that refers back to a result (D8).
pub const ThreadEntry = struct {
    path: []const u8,
    kind: []const u8,
    note_time: ?[]const u8,
    text: []const u8,
};

pub const Result = struct {
    member: []const u8,
    /// Null for a main spec.
    change: ?[]const u8,
    capability: ?[]const u8,
    /// "archived" or "active".
    state: []const u8,
    kind: []const u8,
    note_time: ?[]const u8,
    path: []const u8,
    rel: []const u8,
    /// "lexical", "semantic", or both.
    methods: []const []const u8,
    text: []const u8,
    thread: []const ThreadEntry = &.{},
};

pub const Outcome = struct {
    results: []const Result,
    /// Shown on stderr: semantic search skipped, stale index.
    notices: []const []const u8,
};

pub const Error = error{QueryFailed} || Allocator.Error;

pub const Diag = struct {
    message: []const u8 = "",
};

pub fn run(arena: Allocator, gpa: Allocator, io: Io, ws: workspace.Workspace, opts: Options, diag: *Diag) Error!Outcome {
    return runInner(arena, gpa, io, ws, opts, diag) catch |err| switch (err) {
        error.OutOfMemory, error.QueryFailed => |e| return e,
        else => {
            if (diag.message.len == 0)
                diag.message = try std.fmt.allocPrint(arena, "query failed ({s})", .{@errorName(err)});
            return error.QueryFailed;
        },
    };
}

fn runInner(arena: Allocator, gpa: Allocator, io: Io, ws: workspace.Workspace, opts: Options, diag: *Diag) !Outcome {
    const path = try update.indexPath(arena, ws);
    var idiag: index.Diag = .{};
    var db = index.openRead(arena, io, path, &idiag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.message = idiag.message;
            return error.QueryFailed;
        },
    };
    defer db.close();

    var notices: std.ArrayList([]const u8) = .empty;

    var fdiag: freshness.Diag = .{};
    if (freshness.detect(arena, io, ws, db, &fdiag)) |changes| {
        if (changes.total() > 0) try notices.append(arena, try std.fmt.allocPrint(
            arena,
            "{d} file{s} changed since the last update {s} not indexed yet; run: devlog-index update",
            .{ changes.total(), if (changes.total() == 1) "" else "s", if (changes.total() == 1) "is" else "are" },
        ));
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => try notices.append(arena, try std.fmt.allocPrint(arena, "could not check whether the index is up to date: {s}", .{fdiag.message})),
        else => try notices.append(arena, try std.fmt.allocPrint(arena, "could not check whether the index is up to date ({s})", .{@errorName(err)})),
    }

    const lex = try lexical(arena, db, opts.text, opts.k);
    var sem: []const i64 = &.{};
    if (try semanticSkipReason(arena, db, opts)) |why| {
        try notices.append(arena, try skipped(arena, why));
    } else {
        const dim = std.fmt.parseInt(u32, (try index.readSetting(arena, db, "dim")).?, 10) catch return error.QueryFailed;
        if (embedQuery(arena, gpa, opts.provider.?, dim, opts.text)) |vec| {
            sem = try semantic(arena, db, vec, opts.k);
        } else |why| try notices.append(arena, try skipped(arena, try describeEmbedFailure(arena, why, dim)));
    }

    return .{
        .results = try load(arena, db, try merge(arena, lex, sem)),
        .notices = notices.items,
    };
}

fn skipped(arena: Allocator, why: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "semantic search skipped: {s}; these results are lexical only", .{why});
}

/// Why the index cannot be searched semantically with `opts`, or null.
fn semanticSkipReason(arena: Allocator, db: dbm.Db, opts: Options) !?[]const u8 {
    if (opts.provider == null) return "no embedding model";
    const url = try index.readSetting(arena, db, "model_url") orelse "(none)";
    if (!std.mem.eql(u8, url, opts.model_url))
        return try std.fmt.allocPrint(arena, "the index was built with model {s}, but this devlog-index uses {s}; rebuild it with: {s}", .{ url, opts.model_url, index.rebuild_command });
    if (try index.readSetting(arena, db, "dim") == null) return "the index has no vectors yet";
    return null;
}

/// The query's vector, in the arena.
fn embedQuery(arena: Allocator, gpa: Allocator, provider: update.Provider, dim: u32, text: []const u8) anyerror![]const f32 {
    const e = try provider.getFn(provider.ptr);
    if (e.dim != dim) return error.DimensionMismatch;
    const v = try e.embed(gpa, text);
    defer gpa.free(v);
    return arena.dupe(f32, v);
}

fn describeEmbedFailure(arena: Allocator, err: anyerror, dim: u32) Allocator.Error![]const u8 {
    return switch (err) {
        error.ModelNotCached => "the embedding model is not downloaded yet (devlog-index update fetches it)",
        error.DimensionMismatch => std.fmt.allocPrint(arena, "the model's vectors do not match the index's {d}-d vectors; rebuild it with: {s}", .{ dim, index.rebuild_command }),
        else => std.fmt.allocPrint(arena, "the embedding model failed ({s})", .{@errorName(err)}),
    };
}

/// The query as an FTS5 expression: each term quoted, joined with OR, so
/// punctuation and words like NOT or NEAR cannot act as operators. Terms are
/// runs of ASCII letters and digits or non-ASCII bytes; anything else
/// separates them. Empty when the query has no terms.
pub fn ftsQuery(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (!isTermByte(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and isTermByte(text[i])) i += 1;
        if (out.items.len > 0) try out.appendSlice(arena, " OR ");
        try out.append(arena, '"');
        try out.appendSlice(arena, text[start..i]);
        try out.append(arena, '"');
    }
    return out.items;
}

fn isTermByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b >= 0x80;
}

/// Passage ids of the top `k` by `bm25()`, best first.
pub fn lexical(arena: Allocator, db: dbm.Db, text: []const u8, k: usize) ![]const i64 {
    const expr = try ftsQuery(arena, text);
    if (expr.len == 0) return &.{};
    var s = try db.prepare("SELECT rowid FROM passages_fts WHERE passages_fts MATCH ? ORDER BY bm25(passages_fts) LIMIT ?");
    defer s.finalize();
    try s.bindText(1, expr);
    try s.bindInt(2, @intCast(k));
    return collectIds(arena, s);
}

/// Passage ids of the top `k` by cosine distance to `vec`, best first.
pub fn semantic(arena: Allocator, db: dbm.Db, vec: []const f32, k: usize) ![]const i64 {
    var s = try db.prepare("SELECT rowid FROM passages_vec WHERE embedding MATCH ? AND k = ? ORDER BY distance");
    defer s.finalize();
    try s.bindBlob(1, std.mem.sliceAsBytes(vec));
    try s.bindInt(2, @intCast(k));
    return collectIds(arena, s);
}

fn collectIds(arena: Allocator, s: dbm.Stmt) ![]const i64 {
    var ids: std.ArrayList(i64) = .empty;
    while (try s.step()) try ids.append(arena, s.int(0));
    return ids.items;
}

pub const Hit = struct {
    id: i64,
    /// 1-based rank in each method's list, if it found the passage.
    lexical: ?usize = null,
    semantic: ?usize = null,
};

/// The union of both ranked lists (D6): passages found by both first, by
/// their better rank (lexical breaks ties); then the others, alternating
/// lexical and semantic by their own rank.
pub fn merge(arena: Allocator, lex: []const i64, sem: []const i64) Allocator.Error![]const Hit {
    var out: std.ArrayList(Hit) = .empty;
    for (lex, 1..) |id, r| {
        if (std.mem.indexOfScalar(i64, sem, id)) |j| try out.append(arena, .{ .id = id, .lexical = r, .semantic = j + 1 });
    }
    std.mem.sort(Hit, out.items, {}, struct {
        fn less(_: void, a: Hit, b: Hit) bool {
            const ba = @min(a.lexical.?, a.semantic.?);
            const bb = @min(b.lexical.?, b.semantic.?);
            return if (ba != bb) ba < bb else a.lexical.? < b.lexical.?;
        }
    }.less);
    var lex_only: std.ArrayList(Hit) = .empty;
    for (lex, 1..) |id, r| if (std.mem.indexOfScalar(i64, sem, id) == null) try lex_only.append(arena, .{ .id = id, .lexical = r });
    var sem_only: std.ArrayList(Hit) = .empty;
    for (sem, 1..) |id, r| if (std.mem.indexOfScalar(i64, lex, id) == null) try sem_only.append(arena, .{ .id = id, .semantic = r });
    for (0..@max(lex_only.items.len, sem_only.items.len)) |j| {
        if (j < lex_only.items.len) try out.append(arena, lex_only.items[j]);
        if (j < sem_only.items.len) try out.append(arena, sem_only.items[j]);
    }
    return out.items;
}

fn load(arena: Allocator, db: dbm.Db, hits: []const Hit) ![]const Result {
    var s = try db.prepare(
        \\SELECT p.text, f.path, f.rel, f.member, f.change, f.capability, f.archived, f.kind, f.note_time
        \\FROM passages p JOIN files f ON f.id = p.file_id WHERE p.id = ?
    );
    defer s.finalize();
    const out = try arena.alloc(Result, hits.len);
    for (hits, out) |h, *r| {
        s.reset();
        try s.bindInt(1, h.id);
        if (!try s.step()) return error.QueryFailed; // an id from the index's own tables
        var methods: std.ArrayList([]const u8) = .empty;
        if (h.lexical != null) try methods.append(arena, "lexical");
        if (h.semantic != null) try methods.append(arena, "semantic");
        r.* = .{
            .text = try arena.dupe(u8, s.text(0)),
            .path = try arena.dupe(u8, s.text(1)),
            .rel = try arena.dupe(u8, s.text(2)),
            .member = try arena.dupe(u8, s.text(3)),
            .change = if (s.isNull(4)) null else try arena.dupe(u8, s.text(4)),
            .capability = if (s.isNull(5)) null else try arena.dupe(u8, s.text(5)),
            .state = if (s.int(6) != 0) "archived" else "active",
            .kind = try arena.dupe(u8, s.text(7)),
            .note_time = if (s.isNull(8)) null else try arena.dupe(u8, s.text(8)),
            .methods = methods.items,
        };
    }
    return out;
}

pub fn writeText(results: []const Result, out: *Io.Writer) Io.Writer.Error!void {
    if (results.len == 0) return out.writeAll("No results.\n");
    for (results, 1..) |r, n| {
        if (n > 1) try out.writeByte('\n');
        try out.print("{d}. {s} · ", .{ n, r.member });
        if (r.change) |c| try out.writeAll(c) else {
            try out.writeAll("main spec");
            if (r.capability) |cap| try out.print(" ({s})", .{cap});
        }
        try out.print(" · {s} · {s}", .{ r.state, r.kind });
        if (r.note_time) |t| try out.print(" · {s}", .{t});
        try out.writeAll(" · ");
        for (r.methods, 0..) |m, i| try out.print("{s}{s}", .{ if (i > 0) " + " else "", m });
        try out.print("\n   {s}\n\n", .{r.path});
        try writeIndented(out, r.text, "   ");
    }
}

fn writeIndented(out: *Io.Writer, text: []const u8, indent: []const u8) Io.Writer.Error!void {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len > 0) try out.writeAll(indent);
        try out.print("{s}\n", .{line});
    }
}

/// One JSON object per result, one per line, and nothing else.
pub fn writeJson(results: []const Result, out: *Io.Writer) Io.Writer.Error!void {
    for (results) |r| {
        try std.json.Stringify.value(r, .{}, out);
        try out.writeByte('\n');
    }
}

// ---- tests ----

const testing = std.testing;
const testutil = @import("testutil.zig");

test "ftsQuery quotes every term and drops punctuation" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("\"why\" OR \"is\" OR \"the\" OR \"schema\" OR \"private\"", try ftsQuery(a, "why is the schema private?"));
    try testing.expectEqualStrings("\"say\" OR \"hi\" OR \"x\" OR \"NOT\" OR \"col\" OR \"y\"", try ftsQuery(a, "say \"hi\" * -x NOT col: y"));
    try testing.expectEqualStrings("\"café\" OR \"naïve\"", try ftsQuery(a, "café/naïve"));
    try testing.expectEqualStrings("", try ftsQuery(a, " \"*-: "));
}

/// An index built by hand: three passages with known 3-d vectors.
const Hand = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    db: dbm.Db,

    fn init() !Hand {
        var h: Hand = .{ .arena_state = .init(testing.allocator), .tmp = testing.tmpDir(.{}), .db = undefined };
        errdefer h.arena_state.deinit();
        errdefer h.tmp.cleanup();
        const a = h.arena_state.allocator();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try h.tmp.dir.realPath(testing.io, &buf);
        var diag: index.Diag = .{};
        var ix = try index.Index.open(a, try std.fs.path.joinZ(a, &.{ buf[0..n], "index.db" }), "test://hand", &diag);
        try ix.ensureVec(a, 3, &diag);
        h.db = ix.db;
        try h.db.exec(
            \\INSERT INTO files(id, path, member, rel, hash, size, mtime_ns, kind, change, archived, capability, note_time, indexed_at) VALUES
            \\ (1, '/w/infra/openspec/specs/naming/spec.md', 'infra', 'openspec/specs/naming/spec.md', 'h1', 1, 1, 'spec', NULL, 0, 'naming', NULL, 0),
            \\ (2, '/w/api/openspec/changes/archive/2026-01-02-add-x/devlog/20260102-1346-decision-x.md', 'api', 'openspec/changes/archive/2026-01-02-add-x/devlog/20260102-1346-decision-x.md', 'h2', 1, 1, 'decision', 'add-x', 1, NULL, '2026-01-02 13:46', 0);
            \\INSERT INTO passages(id, file_id, ordinal, title, text, text_hash) VALUES
            \\ (1, 1, 0, NULL, 'Service naming convention: kebab-case names prefixed by the team.', 't1'),
            \\ (2, 2, 0, NULL, 'Decision: the schema stays private; zorblax handles the export.', 't2'),
            \\ (3, 2, 1, NULL, 'Rollout notes for the schema change, behind a flag.', 't3');
            \\INSERT INTO passages_fts(rowid, text) SELECT id, text FROM passages;
        );
        var ins = try h.db.prepare("INSERT INTO passages_vec(rowid, embedding) VALUES (?, ?)");
        defer ins.finalize();
        const vecs = [_][3]f32{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0.6, 0.8 } };
        for (vecs, 1..) |v, id| {
            try ins.bindInt(1, @intCast(id));
            try ins.bindBlob(2, std.mem.sliceAsBytes(&v));
            try ins.run();
        }
        return h;
    }

    fn deinit(h: *Hand) void {
        h.db.close();
        h.tmp.cleanup();
        h.arena_state.deinit();
    }

    fn arena(h: *Hand) Allocator {
        return h.arena_state.allocator();
    }
};

test "lexical: bm25 ranking; operator characters in the query are harmless" {
    var h = try Hand.init();
    defer h.deinit();
    try testing.expectEqualSlices(i64, &.{2}, try lexical(h.arena(), h.db, "zorblax", 5));
    try testing.expectEqualSlices(i64, &.{2}, try lexical(h.arena(), h.db, "\"zorblax\" * -NEAR: (export", 5));
    const both = try lexical(h.arena(), h.db, "schema", 5);
    try testing.expectEqual(@as(usize, 2), both.len);
    try testing.expectEqualSlices(i64, &.{}, try lexical(h.arena(), h.db, "*-:\"", 5));
    try testing.expectEqual(@as(usize, 1), (try lexical(h.arena(), h.db, "schema", 1)).len);
}

test "semantic: exhaustive cosine, nearest first, k per method" {
    var h = try Hand.init();
    defer h.deinit();
    try testing.expectEqualSlices(i64, &.{ 2, 3, 1 }, try semantic(h.arena(), h.db, &.{ 0, 1, 0.1 }, 5));
    try testing.expectEqualSlices(i64, &.{ 3, 2 }, try semantic(h.arena(), h.db, &.{ 0, 0.5, 1 }, 2));
    try testing.expectEqualSlices(i64, &.{1}, try semantic(h.arena(), h.db, &.{ 1, 0.1, 0 }, 1));
}

test "merge: both first, then alternating by own rank, no duplicates" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const hits = try merge(a, &.{ 10, 11, 12, 13 }, &.{ 20, 12, 21, 10 });
    var ids: [6]i64 = undefined;
    for (hits, &ids) |hit, *id| id.* = hit.id;
    // 10 (best rank 1) and 12 (best rank 2) were found by both.
    try testing.expectEqualSlices(i64, &.{ 10, 12, 11, 20, 13, 21 }, ids[0..hits.len]);
    try testing.expectEqual(@as(?usize, 1), hits[0].lexical);
    try testing.expectEqual(@as(?usize, 4), hits[0].semantic);
    try testing.expectEqual(@as(?usize, null), hits[2].semantic);
    try testing.expectEqual(@as(?usize, null), hits[3].lexical);

    try testing.expectEqual(@as(usize, 0), (try merge(a, &.{}, &.{})).len);
    try testing.expectEqual(@as(usize, 2), (try merge(a, &.{1}, &.{2})).len);
}

test "load labels results; text output shows every label" {
    var h = try Hand.init();
    defer h.deinit();
    const rs = try load(h.arena(), h.db, try merge(h.arena(), &.{2}, &.{ 2, 1 }));
    try testing.expectEqual(@as(usize, 2), rs.len);
    try testing.expectEqualStrings("api", rs[0].member);
    try testing.expectEqualStrings("add-x", rs[0].change.?);
    try testing.expectEqualStrings("archived", rs[0].state);
    try testing.expectEqualStrings("decision", rs[0].kind);
    try testing.expectEqualStrings("2026-01-02 13:46", rs[0].note_time.?);
    try testing.expectEqual(@as(usize, 2), rs[0].methods.len);
    try testing.expect(rs[1].change == null);

    var buf: Io.Writer.Allocating = .init(h.arena());
    try writeText(rs, &buf.writer);
    const text = buf.written();
    try testing.expect(std.mem.indexOf(u8, text, "1. api · add-x · archived · decision · 2026-01-02 13:46 · lexical + semantic\n   /w/api/") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2. infra · main spec (naming) · active · spec · semantic\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "   Decision: the schema stays private") != null);
}

fn queryIn(f: *testutil.Fixture, start: []const u8, opts: Options) !Outcome {
    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, try f.path(start), &wdiag);
    var diag: Diag = .{};
    return run(f.arena(), testing.allocator, testing.io, ws, opts, &diag) catch |err| {
        std.debug.print("query: {s}: {s}\n", .{ @errorName(err), diag.message });
        return err;
    };
}

test "query: labels on an archived decision note; --json lines all parse" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);

    const o = try queryIn(&f, "beta", .{ .text = "thundering-herd argument", .provider = stub.provider(), .model_url = "test://stub" });
    try testing.expectEqual(@as(usize, 0), o.notices.len);
    try testing.expect(o.results.len > 0 and o.results.len <= 2 * default_k);
    const top = o.results[0];
    try testing.expectEqualStrings("alpha", top.member);
    try testing.expectEqualStrings("add-retry", top.change.?);
    try testing.expectEqualStrings("archived", top.state);
    try testing.expectEqualStrings("decision", top.kind);
    try testing.expectEqualStrings("2026-03-10 10:15", top.note_time.?);
    try testing.expect(std.mem.endsWith(u8, top.path, "devlog/20260310-1015-decision-retry-policy.md"));
    try testing.expectEqualStrings("lexical", top.methods[0]);

    var buf: Io.Writer.Allocating = .init(f.arena());
    try writeJson(o.results, &buf.writer);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, buf.written(), "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, f.arena(), line, .{});
        inline for (.{ "member", "change", "state", "kind", "note_time", "path", "methods", "text", "thread" }) |key|
            try testing.expect(v.object.get(key) != null);
    }
    try testing.expectEqual(o.results.len, n);
}

test "query: default k returns at most ten distinct passages from every member" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    const o = try queryIn(&f, "alpha", .{ .text = "health check database retry token cache spec", .provider = stub.provider(), .model_url = "test://stub" });
    try testing.expect(o.results.len <= 10);
    var seen_beta = false;
    for (o.results, 0..) |r, i| {
        if (std.mem.eql(u8, r.member, "beta")) seen_beta = true;
        for (o.results[0..i]) |prev| try testing.expect(!(std.mem.eql(u8, prev.path, r.path) and std.mem.eql(u8, prev.text, r.text)));
    }
    try testing.expect(seen_beta);
}

test "query: no index is an error naming update" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, f.root, &wdiag);
    var diag: Diag = .{};
    try testing.expectError(error.QueryFailed, run(f.arena(), testing.allocator, testing.io, ws, .{ .text = "retry", .provider = null }, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "devlog-index update") != null);
}

test "query: model unavailable gives lexical results and says semantic search was skipped" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);

    var failing: testutil.Stub = .{ .fail_load = true };
    const o = try queryIn(&f, "", .{ .text = "retry policy", .provider = failing.provider(), .model_url = "test://stub" });
    try testing.expect(o.results.len > 0);
    for (o.results) |r| {
        try testing.expectEqual(@as(usize, 1), r.methods.len);
        try testing.expectEqualStrings("lexical", r.methods[0]);
    }
    try testing.expectEqual(@as(usize, 1), o.notices.len);
    try testing.expect(std.mem.startsWith(u8, o.notices[0], "semantic search skipped: the embedding model failed (ModelLoadFailed)"));

    // Another model's index: skipped, naming the rebuild.
    const other = try queryIn(&f, "", .{ .text = "retry policy", .provider = stub.provider(), .model_url = "test://other" });
    try testing.expect(other.results.len > 0);
    try testing.expect(std.mem.indexOf(u8, other.notices[0], index.rebuild_command) != null);
}

test "query: a stale index is used with a notice counting the unindexed files" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    try f.write("alpha/openspec/changes/add-cache/devlog/20260402-0900-decision-a.md", "# A\n\nOne retry.\n");
    try f.write("alpha/openspec/changes/add-cache/devlog/20260402-0910-decision-b.md", "# B\n\nTwo retries.\n");

    const o = try queryIn(&f, "", .{ .text = "retry policy", .provider = stub.provider(), .model_url = "test://stub" });
    try testing.expect(o.results.len > 0);
    try testing.expectEqual(@as(usize, 1), o.notices.len);
    try testing.expectEqualStrings("2 files changed since the last update are not indexed yet; run: devlog-index update", o.notices[0]);
}

test "query with the real model: a concept found without shared words (DEVLOG_INDEX_TEST_MODEL)" {
    const env = std.c.getenv("DEVLOG_INDEX_TEST_MODEL") orelse return error.SkipZigTest;
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, f.root, &wdiag);
    {
        var mp: update.ModelProvider = .{ .gpa = testing.allocator, .io = testing.io, .model_path = std.mem.span(env), .download_url = null };
        defer mp.deinit();
        var udiag: update.Diag = .{};
        _ = try update.run(f.arena(), testing.allocator, testing.io, ws, .{ .provider = mp.provider() }, &udiag);
    }
    var mp: update.ModelProvider = .{ .gpa = testing.allocator, .io = testing.io, .model_path = std.mem.span(env), .download_url = null, .task = .query };
    defer mp.deinit();
    var diag: Diag = .{};
    const o = try run(f.arena(), testing.allocator, testing.io, ws, .{ .text = "how long to pause when the auth server hiccups", .provider = mp.provider() }, &diag);
    try testing.expectEqual(@as(usize, 0), o.notices.len);
    for (o.results) |r| {
        if (!std.mem.endsWith(u8, r.path, "20260310-1015-decision-retry-policy.md")) continue;
        for (r.methods) |m| if (std.mem.eql(u8, m, "semantic")) return;
    }
    return error.RetryPolicyNotFoundSemantically;
}
