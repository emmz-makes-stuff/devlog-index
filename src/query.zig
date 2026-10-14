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
//! them. A missing index is an error naming `update`. The notices go on every
//! result as well as to stderr, so a `--json` caller reading only stdout
//! still sees them.
//!
//! Each devlog-note result carries its thread (D8): the later notes in the
//! same change that refer back to it by filename, by `HHMM` next to "note",
//! or, for a `section-N-done` note, by `§N-done` / `section N done`. Each
//! entry holds the passages that make the reference.

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
    /// The note's passages that make the reference.
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
    /// The query's notices (`Outcome.notices`), on every result.
    notices: []const []const u8 = &.{},
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
    return runInner(arena, gpa, io, ws, opts, diag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (diag.message.len == 0)
            diag.message = try std.fmt.allocPrint(arena, "query failed ({s})", .{@errorName(err)});
        return error.QueryFailed;
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
    if (try staleness(arena, io, ws, db)) |n| try notices.append(arena, n);
    const r = try rank(arena, gpa, db, opts, diag);
    if (r.semantic_skipped) |n| try notices.append(arena, n);
    const results = try load(arena, db, try merge(arena, r.lexical, r.semantic));
    for (results) |*res| res.notices = notices.items;
    return .{ .results = results, .notices = notices.items };
}

/// A notice when files changed since the last update, or when that cannot
/// be checked; null when the index is up to date.
pub fn staleness(arena: Allocator, io: Io, ws: workspace.Workspace, db: dbm.Db) !?[]const u8 {
    var fdiag: freshness.Diag = .{};
    const changes = freshness.detect(arena, io, ws, db, &fdiag) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed => try std.fmt.allocPrint(arena, "could not check whether the index is up to date: {s}", .{fdiag.message}),
        else => try std.fmt.allocPrint(arena, "could not check whether the index is up to date ({s})", .{@errorName(err)}),
    };
    if (changes.total() == 0) return null;
    return try std.fmt.allocPrint(
        arena,
        "{d} file{s} changed since the last update {s} not indexed yet; run: devlog-index update",
        .{ changes.total(), if (changes.total() == 1) "" else "s", if (changes.total() == 1) "is" else "are" },
    );
}

/// Both methods' ranked passage ids for one query, before the merge.
pub const Ranking = struct {
    /// Top `opts.k` by `bm25()`, best first.
    lexical: []const i64,
    /// Top `opts.k` by cosine, best first; empty when semantic search was skipped.
    semantic: []const i64,
    /// The notice saying why semantic search was skipped, or null if it ran.
    semantic_skipped: ?[]const u8 = null,
};

/// Ranks `opts.text` both ways in the open index `db`.
pub fn rank(arena: Allocator, gpa: Allocator, db: dbm.Db, opts: Options, diag: *Diag) !Ranking {
    const lex = try lexical(arena, db, opts.text, opts.k);
    var sem: []const i64 = &.{};
    var skip: ?[]const u8 = null;
    if (try semanticSkipReason(arena, db, opts)) |why| {
        skip = try skipped(arena, why);
    } else {
        const dim_text = (try index.readSetting(arena, db, "dim")).?;
        const dim = std.fmt.parseInt(u32, dim_text, 10) catch {
            diag.message = try std.fmt.allocPrint(arena, "the index's dim setting is not a number (\"{s}\"); rebuild it with: {s}", .{ dim_text, index.rebuild_command });
            return error.QueryFailed;
        };
        if (embedQuery(arena, gpa, opts.provider.?, dim, opts.text)) |vec| {
            sem = try semantic(arena, db, vec, opts.k);
        } else |why| skip = try skipped(arena, try describeEmbedFailure(arena, why, dim));
    }
    return .{ .lexical = lex, .semantic = sem, .semantic_skipped = skip };
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

fn load(arena: Allocator, db: dbm.Db, hits: []const Hit) ![]Result {
    var s = try db.prepare(
        \\SELECT p.text, f.path, f.rel, f.member, f.change, f.capability, f.archived, f.kind, f.note_time
        \\FROM passages p JOIN files f ON f.id = p.file_id WHERE p.id = ?
    );
    defer s.finalize();
    var later = try db.prepare(
        \\SELECT f.path, f.kind, f.note_time, p.text FROM files f JOIN passages p ON p.file_id = f.id
        \\WHERE f.member = ? AND f.change = ? AND f.archived = ? AND f.note_time > ?
        \\ORDER BY f.note_time, f.path, p.ordinal
    );
    defer later.finalize();
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
        r.thread = try threadOf(arena, later, r.*);
    }
    return out;
}

/// The later notes in `r`'s change that refer back to it, in time order,
/// using `later` (the thread query in `load`).
fn threadOf(arena: Allocator, later: dbm.Stmt, r: Result) ![]const ThreadEntry {
    const change = r.change orelse return &.{};
    const time = r.note_time orelse return &.{};
    const refs = Refs.of(r.path) orelse return &.{};
    later.reset();
    try later.bindText(1, r.member);
    try later.bindText(2, change);
    try later.bindInt(3, @intFromBool(std.mem.eql(u8, r.state, "archived")));
    try later.bindText(4, time);
    var out: std.ArrayList(ThreadEntry) = .empty;
    while (try later.step()) {
        const passage = later.text(3);
        if (!refs.foundIn(passage)) continue;
        // Rows are ordered by note, so a note's referring passages are adjacent.
        if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1].path, later.text(0))) {
            const last = &out.items[out.items.len - 1];
            last.text = try std.mem.concat(arena, u8, &.{ last.text, "\n\n", passage });
            continue;
        }
        try out.append(arena, .{
            .path = try arena.dupe(u8, later.text(0)),
            .kind = try arena.dupe(u8, later.text(1)),
            .note_time = try arena.dupe(u8, later.text(2)),
            .text = try arena.dupe(u8, passage),
        });
    }
    return out.items;
}

/// What a later note may call a devlog note by (D8).
pub const Refs = struct {
    /// The basename without `.md`.
    stem: []const u8,
    /// `HHMM` from the basename.
    time: []const u8,
    /// `N` for a `section-N-done` note; section references point only there.
    section: ?[]const u8,

    /// Null unless `path` names a devlog note, `YYYYMMDD-HHMM-<slug>.md`.
    pub fn of(path: []const u8) ?Refs {
        const base = std.fs.path.basename(path);
        if (base.len < "YYYYMMDD-HHMM-x.md".len or !std.mem.endsWith(u8, base, ".md") or base[8] != '-' or base[13] != '-') return null;
        for (base[0..13], 0..) |b, i| if (i != 8 and !std.ascii.isDigit(b)) return null;
        return .{ .stem = base[0 .. base.len - 3], .time = base[9..13], .section = sectionDone(base[14 .. base.len - 3]) };
    }

    /// True when `text` refers to the note: its filename (with or without
    /// `.md`), its time next to "note" ("the 1346 note", "note 1346"), or
    /// for a section-done note "§N-done" or "section N done".
    pub fn foundIn(refs: Refs, text: []const u8) bool {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, refs.stem)) |at| : (i = at + 1) {
            if (standalone(text, at, refs.stem.len)) return true;
        }
        i = 0;
        while (std.mem.indexOfPos(u8, text, i, refs.time)) |at| : (i = at + 1) {
            if (standalone(text, at, refs.time.len) and
                (wordAt(text, skipSpace(text, at + refs.time.len, .forward), "note") or wordBefore(text, at, "note")))
                return true;
        }
        const n = refs.section orelse return false;
        i = 0;
        while (std.mem.indexOfPos(u8, text, i, "§")) |at| : (i = at + 1) {
            const p = at + "§".len;
            if (std.mem.startsWith(u8, text[p..], n) and wordAt(text, p + n.len, "-done")) return true;
        }
        i = 0;
        while (std.ascii.indexOfIgnoreCasePos(text, i, "section")) |at| : (i = at + 1) {
            if (at > 0 and isWordByte(text[at - 1])) continue;
            const p = skipSpace(text, at + "section".len, .forward);
            if (p == at + "section".len or !std.mem.startsWith(u8, text[p..], n)) continue;
            const q = skipSpace(text, p + n.len, .forward);
            if (q > p + n.len and wordAt(text, q, "done")) return true;
        }
        return false;
    }
};

/// `N` when `slug` is `section-N-done` (optionally followed by `-<more>`).
fn sectionDone(slug: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, slug, "section-")) slug["section-".len..] else return null;
    var n: usize = 0;
    while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
    if (n == 0) return null;
    const tail = rest[n..];
    return if (std.mem.eql(u8, tail, "-done") or std.mem.startsWith(u8, tail, "-done-")) rest[0..n] else null;
}

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '-' or b == '_';
}

/// True when `text[at..at+len]` is not part of a longer word, number or name.
fn standalone(text: []const u8, at: usize, len: usize) bool {
    if (at > 0 and isWordByte(text[at - 1])) return false;
    return at + len == text.len or !isWordByte(text[at + len]);
}

/// True when `word` (any case) starts at `pos` and ends at a word boundary.
fn wordAt(text: []const u8, pos: usize, word: []const u8) bool {
    if (pos > text.len or !std.ascii.startsWithIgnoreCase(text[pos..], word)) return false;
    const end = pos + word.len;
    return end == text.len or !std.ascii.isAlphanumeric(text[end]);
}

/// True when `word` (any case) ends just before whitespace before `pos`.
fn wordBefore(text: []const u8, pos: usize, word: []const u8) bool {
    const end = skipSpace(text, pos, .backward);
    if (end == pos or end < word.len) return false;
    const start = end - word.len;
    if (!std.ascii.eqlIgnoreCase(text[start..end], word)) return false;
    return start == 0 or !std.ascii.isAlphanumeric(text[start - 1]);
}

/// The position past the whitespace from `pos` in `dir`; for `.backward`,
/// the end of the text before it.
fn skipSpace(text: []const u8, pos: usize, dir: enum { forward, backward }) usize {
    var p = pos;
    switch (dir) {
        .forward => while (p < text.len and std.ascii.isWhitespace(text[p])) {
            p += 1;
        },
        .backward => while (p > 0 and std.ascii.isWhitespace(text[p - 1])) {
            p -= 1;
        },
    }
    return p;
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
        for (r.thread) |t| {
            try out.print("\n   ↳ later note · {s} · {s}\n     {s}\n\n", .{ t.note_time orelse "", t.kind, t.path });
            try writeIndented(out, t.text, "     ");
        }
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
        inline for (.{ "member", "change", "state", "kind", "note_time", "path", "methods", "text", "thread", "notices" }) |key|
            try testing.expect(v.object.get(key) != null);
        if (n == 0) {
            const thread = v.object.get("thread").?.array.items;
            try testing.expectEqual(top.thread.len, thread.len);
            try testing.expect(thread.len > 0);
            inline for (.{ "path", "kind", "note_time", "text" }) |key|
                try testing.expect(thread[0].object.get(key) != null);
        }
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
    try expectJsonNotices(&f, o);

    // Another model's index: skipped, naming the rebuild.
    const other = try queryIn(&f, "", .{ .text = "retry policy", .provider = stub.provider(), .model_url = "test://other" });
    try testing.expect(other.results.len > 0);
    try testing.expect(std.mem.indexOf(u8, other.notices[0], index.rebuild_command) != null);
    try testing.expect(std.mem.indexOf(u8, other.notices[0], "built with model test://stub") != null);
    try testing.expect(std.mem.indexOf(u8, other.notices[0], "uses test://other") != null);
    try expectJsonNotices(&f, other);
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
    try expectJsonNotices(&f, o);
}

test "Refs.of: stem, time, and the section only for a section-N-done note" {
    const d = Refs.of("/w/a/devlog/20260310-1015-decision-retry-policy.md").?;
    try testing.expectEqualStrings("20260310-1015-decision-retry-policy", d.stem);
    try testing.expectEqualStrings("1015", d.time);
    try testing.expect(d.section == null);
    try testing.expectEqualStrings("12", Refs.of("20260311-1400-section-12-done.md").?.section.?);
    try testing.expectEqualStrings("1", Refs.of("20260311-1400-section-1-done-retry.md").?.section.?);
    try testing.expect(Refs.of("20260310-0900-section-1-start.md").?.section == null);
    try testing.expect(Refs.of("20260310-0900-section-1-doneish.md").?.section == null);
    try testing.expect(Refs.of("DEVLOG.md") == null);
    try testing.expect(Refs.of("2026031x-0900-note.md") == null);
    try testing.expect(Refs.of("20260310-0900-.md") == null);
}

test "Refs.foundIn: each reference form, and near misses" {
    const d = Refs.of("20260310-1015-decision-retry-policy.md").?;
    try testing.expect(d.foundIn("as decided in 20260310-1015-decision-retry-policy: fixed"));
    try testing.expect(d.foundIn("see devlog/20260310-1015-decision-retry-policy.md."));
    try testing.expect(d.foundIn("reverses the 1015 note's decision"));
    try testing.expect(d.foundIn("the 1015\nNote said"));
    try testing.expect(d.foundIn("per note 1015, retry"));
    try testing.expect(!d.foundIn("20260310-1015-decision-retry-policy-v2 replaces it"));
    try testing.expect(!d.foundIn("the 1015 notebook"));
    try testing.expect(!d.foundIn("the 10150 note"));
    try testing.expect(!d.foundIn("at 1015 we met"));
    try testing.expect(!d.foundIn("the §1-done note"));

    const s = Refs.of("20260311-1400-section-1-done.md").?;
    try testing.expect(s.foundIn("Looked back over the §1-done note"));
    try testing.expect(s.foundIn("Section 1 done still holds"));
    try testing.expect(s.foundIn("since section  1\ndone,"));
    try testing.expect(!s.foundIn("the §10-done note"));
    try testing.expect(!s.foundIn("§1 tasks"));
    try testing.expect(!s.foundIn("section 11 done"));
    try testing.expect(!s.foundIn("subsection 1 done"));
    try testing.expect(!s.foundIn("section 1 doneness"));
    try testing.expect(!Refs.of("20260310-0900-section-1-start.md").?.foundIn("§1-done and section 1 done"));
}

/// The result from the note whose path ends with `name`.
fn resultFor(o: Outcome, name: []const u8) !Result {
    for (o.results) |r| if (std.mem.endsWith(u8, r.path, name)) return r;
    std.debug.print("no result from {s}\n", .{name});
    return error.TestExpectedResult;
}

fn expectThread(r: Result, names: []const []const u8) !void {
    try testing.expectEqual(names.len, r.thread.len);
    for (r.thread, names) |t, name| try testing.expect(std.mem.endsWith(u8, t.path, name));
}

/// A query matching every fixture note.
fn everything(f: *testutil.Fixture, stub: *testutil.Stub) !Outcome {
    return queryIn(f, "", .{ .text = "retry credentials section review answer api cache", .k = max_k, .provider = stub.provider(), .model_url = "test://stub" });
}

test "thread: later notes in the same change, by filename, time and section, in time order" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    const o = try everything(&f, &stub);

    // By filename (with and without .md); beta's mentions are another change.
    const policy = try resultFor(o, "20260310-1015-decision-retry-policy.md");
    try expectThread(policy, &.{ "20260311-1400-section-1-done.md", "20260313-1030-decision-retry-reversal.md" });
    try testing.expectEqualStrings("section", policy.thread[0].kind);
    try testing.expectEqualStrings("2026-03-11 14:00", policy.thread[0].note_time.?);
    try testing.expect(std.mem.indexOf(u8, policy.thread[0].text, "Retry landed as decided in") != null);
    try testing.expect(std.mem.indexOf(u8, policy.thread[1].text, "Reverses the policy") != null);
    try expectThread(try resultFor(o, "20260313-1030-decision-retry-reversal.md"), &.{"20260314-0900-review-section-1.md"});

    // By time next to "note".
    try expectThread(try resultFor(o, "20260312-0915-stopped-2-1-needs-credentials.md"), &.{"20260312-1100-answer-credentials.md"});

    // By section, onto the section-done note only.
    try expectThread(try resultFor(o, "20260311-1400-section-1-done.md"), &.{"20260314-0900-review-section-1.md"});
    try expectThread(try resultFor(o, "20260310-0900-section-1-start.md"), &.{});

    // Nothing later refers to these; beta's own notes thread nothing from alpha.
    try expectThread(try resultFor(o, "20260314-0900-review-section-1.md"), &.{});
    try expectThread(try resultFor(o, "20260320-1200-change-done.md"), &.{});
}

test "thread: a same-time mention in another change is not threaded" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    // A later note in alpha's active change names the archived note by time and by filename.
    try f.write("alpha/openspec/changes/add-cache/devlog/20260402-0900-decision-token-retry.md",
        \\# Decision: token retry
        \\
        \\As the 1015 note said, and as 20260310-1015-decision-retry-policy.md records, retry 503s.
        \\
    );
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    const o = try everything(&f, &stub);
    try expectThread(try resultFor(o, "20260310-1015-decision-retry-policy.md"), &.{ "20260311-1400-section-1-done.md", "20260313-1030-decision-retry-reversal.md" });
}

test "thread: text output shows entries under their result, marked as later notes" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    const o = try everything(&f, &stub);
    const r = try resultFor(o, "20260312-0915-stopped-2-1-needs-credentials.md");

    var buf: Io.Writer.Allocating = .init(f.arena());
    try writeText(&.{r}, &buf.writer);
    const text = buf.written();
    const entry = std.mem.indexOf(u8, text, "\n   ↳ later note · 2026-03-12 11:00 · answer\n     /") orelse return error.TestExpectedThreadEntry;
    try testing.expect(entry > std.mem.indexOf(u8, text, "no test credentials").?);
    try testing.expect(std.mem.indexOf(u8, text[entry..], "\n     Emmz answered the question in the 0915 note") != null);
}

/// Every `--json` line carries the outcome's notices.
fn expectJsonNotices(f: *testutil.Fixture, o: Outcome) !void {
    var buf: Io.Writer.Allocating = .init(f.arena());
    try writeJson(o.results, &buf.writer);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, buf.written(), "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, f.arena(), line, .{});
        const got = v.object.get("notices").?.array.items;
        try testing.expectEqual(o.notices.len, got.len);
        for (o.notices, got) |want, g| try testing.expectEqualStrings(want, g.string);
    }
    try testing.expectEqual(o.results.len, n);
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

test "query: a corrupt dim setting fails with a message naming the rebuild" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    try f.exec("UPDATE settings SET value = 'eight' WHERE key = 'dim'");
    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, f.root, &wdiag);
    var diag: Diag = .{};
    try testing.expectError(error.QueryFailed, run(f.arena(), testing.allocator, testing.io, ws, .{ .text = "retry", .provider = stub.provider(), .model_url = "test://stub" }, &diag));
    try testing.expectEqualStrings("the index's dim setting is not a number (\"eight\"); rebuild it with: " ++ index.rebuild_command, diag.message);
}
