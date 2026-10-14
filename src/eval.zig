//! `eval` (retrieval-eval; design D10).
//!
//! Runs every question in the workspace's golden set
//! (`.devlog-index/golden.json`) as a default query and reports where each
//! expected source ranks. A source's rank is its best passage's place among
//! the primary results (the default top ten). A source outside them is shown
//! with its rank in each method's own list, searched to `depth`, so a near
//! miss can be told from a source neither method finds.
//!
//! `eval` passes only if every expected source is in the top ten, except for
//! questions marked `known_miss`: those are reported but do not fail, and
//! are reported as unexpectedly found once every source is in the top ten. A
//! source that is not in the index fails, known miss or not. Ranks without
//! semantic search are not the default query's ranks, so `eval` fails when
//! semantic search cannot run.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const workspace = @import("workspace.zig");
const dbm = @import("db.zig");
const index = @import("index.zig");
const update = @import("update.zig");
const query = @import("query.zig");
const model_url = @import("model_url.zig");

pub const golden_basename = "golden.json";
/// How deep each method's list is searched for a source outside the top ten.
pub const depth = query.max_k;
const max_golden_bytes = 1 << 20;

/// The file format of `golden.json`.
pub const Golden = struct {
    questions: []const Question,
};

pub const Question = struct {
    question: []const u8,
    /// Paths relative to the workspace root.
    expected: []const []const u8,
    known_miss: bool = false,
};

pub const Source = struct {
    /// As written in the golden set.
    path: []const u8,
    indexed: bool,
    /// 1-based place among the primary results, if there.
    rank: ?usize = null,
    /// 1-based rank in each method's list to `depth`, if there.
    lexical: ?usize = null,
    semantic: ?usize = null,
};

pub const Verdict = enum {
    found,
    missed,
    known_miss,
    unexpectedly_found,
    not_indexed,

    pub fn fails(v: Verdict) bool {
        return v == .missed or v == .not_indexed;
    }

    fn label(v: Verdict) []const u8 {
        return switch (v) {
            .found => "FOUND",
            .missed => "MISSED",
            .known_miss => "KNOWN MISS",
            .unexpectedly_found => "UNEXPECTED",
            .not_indexed => "NOT INDEXED",
        };
    }
};

pub const Entry = struct {
    question: Question,
    sources: []const Source,
    verdict: Verdict,
    /// Lengths of each method's list to `depth`: shorter means no more matches.
    lexical_len: usize,
    semantic_len: usize,
};

pub const Report = struct {
    entries: []const Entry,
    /// Stale index; shown on stderr.
    notices: []const []const u8,

    pub fn passed(r: Report) bool {
        for (r.entries) |e| if (e.verdict.fails()) return false;
        return true;
    }
};

pub const Options = struct {
    /// The model this binary embeds with; the index must match it.
    model_url: []const u8 = model_url.pinned_url,
    /// Supplies the query embedder (query task); null fails the run.
    provider: ?update.Provider,
};

pub const Error = error{EvalFailed} || Allocator.Error;

pub const Diag = struct {
    message: []const u8 = "",
};

pub fn goldenPath(arena: Allocator, ws: workspace.Workspace) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ ws.root, workspace.data_dirname, golden_basename });
}

pub fn run(arena: Allocator, gpa: Allocator, io: Io, ws: workspace.Workspace, opts: Options, diag: *Diag) Error!Report {
    return runInner(arena, gpa, io, ws, opts, diag) catch |err| switch (err) {
        error.OutOfMemory, error.EvalFailed => |e| return e,
        else => {
            if (diag.message.len == 0)
                diag.message = try std.fmt.allocPrint(arena, "eval failed ({s})", .{@errorName(err)});
            return error.EvalFailed;
        },
    };
}

fn runInner(arena: Allocator, gpa: Allocator, io: Io, ws: workspace.Workspace, opts: Options, diag: *Diag) !Report {
    const golden = try readGolden(arena, io, ws, diag);

    var idiag: index.Diag = .{};
    var db = index.openRead(arena, io, try update.indexPath(arena, ws), &idiag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.message = idiag.message;
            return error.EvalFailed;
        },
    };
    defer db.close();

    var file_id = try db.prepare("SELECT id FROM files WHERE path = ?");
    defer file_id.finalize();
    var passage_ids = try db.prepare("SELECT id FROM passages WHERE file_id = ?");
    defer passage_ids.finalize();

    var notices: std.ArrayList([]const u8) = .empty;
    if (try query.staleness(arena, io, ws, db)) |n| try notices.append(arena, n);

    const entries = try arena.alloc(Entry, golden.questions.len);
    for (golden.questions, entries) |q, *e| {
        const r = try query.rank(arena, gpa, db, .{ .text = q.question, .k = depth, .model_url = opts.model_url, .provider = opts.provider });
        if (r.semantic_skipped) |why| {
            diag.message = try std.fmt.allocPrint(arena, "cannot evaluate: {s}", .{why});
            return error.EvalFailed;
        }
        const primary = try query.merge(arena, r.lexical[0..@min(query.default_k, r.lexical.len)], r.semantic[0..@min(query.default_k, r.semantic.len)]);

        const sources = try arena.alloc(Source, q.expected.len);
        for (q.expected, sources) |rel, *s| {
            s.* = .{ .path = rel, .indexed = false };
            file_id.reset();
            try file_id.bindText(1, try std.fs.path.resolve(arena, &.{ ws.root, rel }));
            if (!try file_id.step()) continue;
            s.indexed = true;
            passage_ids.reset();
            try passage_ids.bindInt(1, file_id.int(0));
            var ids: std.ArrayList(i64) = .empty;
            while (try passage_ids.step()) try ids.append(arena, passage_ids.int(0));
            for (primary, 1..) |h, n| if (std.mem.indexOfScalar(i64, ids.items, h.id) != null) {
                s.rank = n;
                break;
            };
            s.lexical = bestRank(r.lexical, ids.items);
            s.semantic = bestRank(r.semantic, ids.items);
        }
        e.* = .{ .question = q, .sources = sources, .verdict = verdictOf(q, sources), .lexical_len = r.lexical.len, .semantic_len = r.semantic.len };
    }
    return .{ .entries = entries, .notices = notices.items };
}

fn readGolden(arena: Allocator, io: Io, ws: workspace.Workspace, diag: *Diag) !Golden {
    const path = try goldenPath(arena, ws);
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_golden_bytes)) catch |err| {
        diag.message = switch (err) {
            error.FileNotFound => try std.fmt.allocPrint(arena, "no golden set: expected it at {s}", .{path}),
            else => try std.fmt.allocPrint(arena, "cannot read the golden set {s} ({s})", .{ path, @errorName(err) }),
        };
        return error.EvalFailed;
    };
    const g = std.json.parseFromSliceLeaky(Golden, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.message = try std.fmt.allocPrint(
                arena,
                "the golden set {s} is not valid ({s}); expected {{\"questions\": [{{\"question\": \"...\", \"expected\": [\"<member>/openspec/...\"], \"known_miss\": false}}]}}",
                .{ path, @errorName(err) },
            );
            return error.EvalFailed;
        },
    };
    if (g.questions.len == 0) {
        diag.message = try std.fmt.allocPrint(arena, "the golden set {s} has no questions", .{path});
        return error.EvalFailed;
    }
    for (g.questions) |q| if (q.expected.len == 0) {
        diag.message = try std.fmt.allocPrint(arena, "the golden set {s}: question \"{s}\" has no expected sources", .{ path, q.question });
        return error.EvalFailed;
    };
    return g;
}

/// The 1-based rank of the first of `ids` in `list`.
fn bestRank(list: []const i64, ids: []const i64) ?usize {
    for (list, 1..) |id, n| if (std.mem.indexOfScalar(i64, ids, id) != null) return n;
    return null;
}

fn verdictOf(q: Question, sources: []const Source) Verdict {
    var all_ranked = true;
    for (sources) |s| {
        if (!s.indexed) return .not_indexed;
        if (s.rank == null) all_ranked = false;
    }
    if (q.known_miss) return if (all_ranked) .unexpectedly_found else .known_miss;
    return if (all_ranked) .found else .missed;
}

pub fn writeText(r: Report, out: *Io.Writer) Io.Writer.Error!void {
    const indent = " " ** 13;
    var counts = std.EnumArray(Verdict, usize).initFill(0);
    for (r.entries) |e| {
        counts.getPtr(e.verdict).* += 1;
        try out.print("{s:<13}{s}\n", .{ e.verdict.label(), e.question.question });
        for (e.sources) |s| {
            try out.print("{s}{s}  ", .{ indent, s.path });
            if (!s.indexed) {
                try out.writeAll("not indexed (check the path, or run: devlog-index update)\n");
            } else if (s.rank) |n| {
                try out.print("rank {d}\n", .{n});
            } else {
                try out.writeAll("not in the top ten (lexical ");
                try writeMethodRank(out, s.lexical, e.lexical_len);
                try out.writeAll(", semantic ");
                try writeMethodRank(out, s.semantic, e.semantic_len);
                try out.writeAll(")\n");
            }
        }
        if (e.verdict == .unexpectedly_found)
            try out.print("{s}every expected source is in the top ten; remove \"known_miss\" from this question\n", .{indent});
    }
    try out.print("\n{d} question{s}:", .{ r.entries.len, if (r.entries.len == 1) "" else "s" });
    var first = true;
    for (std.enums.values(Verdict)) |v| {
        const n = counts.get(v);
        if (n == 0) continue;
        try out.print("{s} {d} {s}", .{ if (first) "" else ",", n, switch (v) {
            .found => "found",
            .missed => "missed",
            .known_miss => if (n == 1) "known miss" else "known misses",
            .unexpectedly_found => "unexpectedly found",
            .not_indexed => "not indexed",
        } });
        first = false;
    }
    try out.print(". {s}\n", .{if (r.passed()) "PASS" else "FAIL"});
}

/// A method's rank, ">depth" when its list is full, or "no match" when the
/// list ended before the source.
fn writeMethodRank(out: *Io.Writer, rank: ?usize, list_len: usize) Io.Writer.Error!void {
    if (rank) |n| return out.print("{d}", .{n});
    if (list_len >= depth) return out.print(">{d}", .{depth});
    return out.writeAll("no match");
}

// ---- tests ----

const testing = std.testing;
const testutil = @import("testutil.zig");

const retry_policy = "alpha/openspec/changes/archive/2026-03-10-add-retry/devlog/20260310-1015-decision-retry-policy.md";
const beta_spec = "beta/openspec/specs/api/spec.md";
/// No lexical match and semantic rank 33 for "thundering-herd argument" with the stub.
const beta_done = "beta/openspec/changes/archive/2026-03-20-init-api/devlog/20260320-1200-change-done.md";

fn evalIn(f: *testutil.Fixture, stub: *testutil.Stub, golden: []const u8, diag: *Diag) !Report {
    try f.write(".devlog-index/golden.json", golden);
    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, f.root, &wdiag);
    return run(f.arena(), testing.allocator, testing.io, ws, .{ .provider = stub.provider(), .model_url = "test://stub" }, diag);
}

fn expectEval(f: *testutil.Fixture, stub: *testutil.Stub, golden: []const u8) !Report {
    var diag: Diag = .{};
    return evalIn(f, stub, golden, &diag) catch |err| {
        std.debug.print("eval: {s}: {s}\n", .{ @errorName(err), diag.message });
        return err;
    };
}

fn textOf(f: *testutil.Fixture, r: Report) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(f.arena());
    try writeText(r, &buf.writer);
    return buf.written();
}

fn contains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find \"{s}\" in:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedText;
    }
}

test "eval: all found prints each question with its ranks and passes" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    const r = try expectEval(&f, &stub,
        \\{"questions": [
        \\  {"question": "thundering-herd argument", "expected": ["
    ++ retry_policy ++
        \\"]},
        \\  {"question": "what does the api spec require", "expected": ["
    ++ beta_spec ++
        \\"]}
        \\]}
    );
    try testing.expect(r.passed());
    try testing.expectEqual(@as(usize, 2), r.entries.len);
    try testing.expectEqual(Verdict.found, r.entries[0].verdict);
    try testing.expectEqual(@as(?usize, 1), r.entries[0].sources[0].rank);
    try testing.expectEqual(Verdict.found, r.entries[1].verdict);
    const text = try textOf(&f, r);
    try contains(text, "FOUND        thundering-herd argument\n             " ++ retry_policy ++ "  rank 1\n");
    try contains(text, "2 questions: 2 found. PASS\n");
}

test "eval: one missed names the question and the source, with each method's rank, and fails" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    const r = try expectEval(&f, &stub,
        \\{"questions": [
        \\  {"question": "thundering-herd argument", "expected": ["
    ++ retry_policy ++
        \\"]},
        \\  {"question": "thundering-herd argument", "expected": ["
    ++ retry_policy ++ "\", \"" ++ beta_done ++
        \\"]}
        \\]}
    );
    try testing.expect(!r.passed());
    try testing.expectEqual(Verdict.found, r.entries[0].verdict);
    const missed = r.entries[1];
    try testing.expectEqual(Verdict.missed, missed.verdict);
    try testing.expectEqual(@as(?usize, 1), missed.sources[0].rank);
    try testing.expect(missed.sources[1].indexed);
    try testing.expectEqual(@as(?usize, null), missed.sources[1].rank);
    try testing.expect(missed.sources[1].semantic.? > query.default_k);
    const text = try textOf(&f, r);
    try contains(text, "MISSED       thundering-herd argument\n");
    try contains(text, "             " ++ beta_done ++ "  not in the top ten (lexical no match, semantic 33)\n");
    try contains(text, "2 questions: 1 found, 1 missed. FAIL\n");
}

test "eval: no golden set fails saying where it is expected" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, f.root, &wdiag);
    var diag: Diag = .{};
    try testing.expectError(error.EvalFailed, run(f.arena(), testing.allocator, testing.io, ws, .{ .provider = stub.provider(), .model_url = "test://stub" }, &diag));
    try testing.expectEqualStrings(try std.fmt.allocPrint(f.arena(), "no golden set: expected it at {s}/.devlog-index/golden.json", .{f.root}), diag.message);
}

test "eval: an invalid or empty golden set fails naming the file" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    for ([_][]const u8{
        "[]",
        "{\"questions\": [{\"question\": \"q\", \"expected\": [\"x\"], \"extra\": 1}]}",
        "{\"questions\": []}",
        "{\"questions\": [{\"question\": \"q\", \"expected\": []}]}",
    }) |golden| {
        var diag: Diag = .{};
        try testing.expectError(error.EvalFailed, evalIn(&f, &stub, golden, &diag));
        try contains(diag.message, "golden.json");
    }
}

test "eval: a source not in the index is not indexed, distinct from not ranked, and fails" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    const r = try expectEval(&f, &stub,
        \\{"questions": [{"question": "thundering-herd argument", "expected": ["
    ++ retry_policy ++
        \\", "alpha/openspec/changes/add-cache/devlog/20990101-0000-decision-missing.md"]}]}
    );
    try testing.expect(!r.passed());
    try testing.expectEqual(Verdict.not_indexed, r.entries[0].verdict);
    try testing.expect(r.entries[0].sources[0].indexed);
    try testing.expect(!r.entries[0].sources[1].indexed);
    const text = try textOf(&f, r);
    try contains(text, "NOT INDEXED  thundering-herd argument\n");
    try contains(text, "20990101-0000-decision-missing.md  not indexed (check the path, or run: devlog-index update)\n");
    try contains(text, "1 question: 1 not indexed. FAIL\n");
}

test "eval: a known miss still missing is reported with its ranks and does not fail" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    const r = try expectEval(&f, &stub,
        \\{"questions": [
        \\  {"question": "thundering-herd argument", "expected": ["
    ++ retry_policy ++
        \\"]},
        \\  {"question": "thundering-herd argument", "expected": ["
    ++ beta_done ++
        \\"], "known_miss": true}
        \\]}
    );
    try testing.expect(r.passed());
    try testing.expectEqual(Verdict.known_miss, r.entries[1].verdict);
    try testing.expect(r.entries[1].sources[0].semantic != null);
    const text = try textOf(&f, r);
    try contains(text, "KNOWN MISS   thundering-herd argument\n             " ++ beta_done ++ "  not in the top ten (lexical no match, semantic 33)\n");
    try contains(text, "2 questions: 1 found, 1 known miss. PASS\n");
}

test "eval: a known miss now found is reported as unexpectedly found and does not fail" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    const r = try expectEval(&f, &stub,
        \\{"questions": [{"question": "thundering-herd argument", "expected": ["
    ++ retry_policy ++
        \\"], "known_miss": true}]}
    );
    try testing.expect(r.passed());
    try testing.expectEqual(Verdict.unexpectedly_found, r.entries[0].verdict);
    const text = try textOf(&f, r);
    try contains(text, "UNEXPECTED   thundering-herd argument\n             " ++ retry_policy ++ "  rank 1\n");
    try contains(text, "remove \"known_miss\" from this question\n");
    try contains(text, "1 question: 1 unexpectedly found. PASS\n");
}

test "eval: a known miss whose source is not indexed fails" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    const r = try expectEval(&f, &stub,
        \\{"questions": [{"question": "retry", "expected": ["gamma/openspec/specs/x/spec.md"], "known_miss": true}]}
    );
    try testing.expect(!r.passed());
    try testing.expectEqual(Verdict.not_indexed, r.entries[0].verdict);
}

test "eval: fails when semantic search cannot run, saying why" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    var failing: testutil.Stub = .{ .fail_load = true };
    var diag: Diag = .{};
    try testing.expectError(error.EvalFailed, evalIn(&f, &failing,
        \\{"questions": [{"question": "retry", "expected": ["
    ++ retry_policy ++
        \\"]}]}
    , &diag));
    try testing.expect(std.mem.startsWith(u8, diag.message, "cannot evaluate: semantic search skipped: the embedding model failed (ModelLoadFailed)"));
}

test "eval: no index is an error naming update" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    var diag: Diag = .{};
    try testing.expectError(error.EvalFailed, evalIn(&f, &stub,
        \\{"questions": [{"question": "retry", "expected": ["
    ++ retry_policy ++
        \\"]}]}
    , &diag));
    try contains(diag.message, "devlog-index update");
}

test "eval: a stale index is evaluated, with one notice counting the unindexed files" {
    var f = try testutil.Fixture.init();
    defer f.deinit();
    var stub: testutil.Stub = .{};
    _ = try f.update("", &stub, false);
    try f.write("alpha/openspec/changes/add-cache/devlog/20260402-0900-decision-a.md", "# A\n\nOne retry.\n");
    const r = try expectEval(&f, &stub,
        \\{"questions": [
        \\  {"question": "thundering-herd argument", "expected": ["
    ++ retry_policy ++
        \\"]},
        \\  {"question": "retry", "expected": ["
    ++ retry_policy ++
        \\"]}
        \\]}
    );
    try testing.expectEqual(@as(usize, 2), r.entries.len);
    try testing.expectEqual(@as(usize, 1), r.notices.len);
    try testing.expectEqualStrings("1 file changed since the last update is not indexed yet; run: devlog-index update", r.notices[0]);
}
