//! Chunking and note classification (design D7; corpus-indexing Chunking and
//! Passage metadata).
//!
//! - Devlog note: paragraphs (blank-line separated, fenced code kept whole)
//!   grouped until >= 80 words, each group prefixed with the note's `# `
//!   title. HTML comments (the `<!-- Section … -->` line) are metadata and
//!   dropped.
//! - Spec / spec delta: one passage for `## Purpose`, one per
//!   `### Requirement:` block with its scenarios.
//! - proposal / design / tasks: the text before the first `##` if it has any
//!   besides the `# ` title, then one passage per `##` section with a body.
//!
//! Spec and artifact passages start with a context line (`auth spec`,
//! `add-retry design`), so a passage that never names its subject can still
//! match it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sources = @import("sources.zig");

pub const min_note_words = 80;

pub const NoteKind = enum { decision, stopped, section, answer, change, review, note };

pub const NoteTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
};

pub const NoteMeta = struct {
    kind: NoteKind,
    /// From `YYYYMMDD-HHMM-`; null when the filename doesn't start with one.
    time: ?NoteTime,
};

/// Kind and time from a note's basename, `YYYYMMDD-HHMM-<slug>.md`. The kind
/// is the slug's first word; unknown words, and names not in that shape, are
/// `note`.
pub fn noteMeta(basename: []const u8) NoteMeta {
    const name = if (std.mem.endsWith(u8, basename, ".md")) basename[0 .. basename.len - 3] else basename;
    const time = parseTime(name) orelse return .{ .kind = .note, .time = null };
    const slug = name["YYYYMMDD-HHMM-".len..];
    const first = slug[0 .. std.mem.indexOfScalar(u8, slug, '-') orelse slug.len];
    const note_kind = std.meta.stringToEnum(NoteKind, first) orelse .note;
    return .{ .kind = note_kind, .time = time };
}

fn parseTime(name: []const u8) ?NoteTime {
    if (name.len < "YYYYMMDD-HHMM-".len + 1) return null;
    if (name[8] != '-' or name[13] != '-') return null;
    const t: NoteTime = .{
        .year = std.fmt.parseInt(u16, name[0..4], 10) catch return null,
        .month = std.fmt.parseInt(u8, name[4..6], 10) catch return null,
        .day = std.fmt.parseInt(u8, name[6..8], 10) catch return null,
        .hour = std.fmt.parseInt(u8, name[9..11], 10) catch return null,
        .minute = std.fmt.parseInt(u8, name[11..13], 10) catch return null,
    };
    if (t.month < 1 or t.month > 12 or t.day < 1 or t.day > 31 or t.hour > 23 or t.minute > 59) return null;
    return t;
}

/// The passage kind recorded in the index (corpus-indexing, Passage
/// metadata): `spec`, `spec-delta`, `proposal`, `design`, `tasks`, or a
/// devlog note's kind from its filename.
pub fn kind(src: sources.Source) []const u8 {
    return switch (src.class.artifact) {
        .note => @tagName(noteMeta(std.fs.path.basename(src.path)).kind),
        .spec_delta => "spec-delta",
        .spec, .proposal, .design, .tasks => @tagName(src.class.artifact),
    };
}

/// Passages for one indexed file.
pub fn passages(arena: Allocator, src: sources.Source, text: []const u8) Allocator.Error![]const []const u8 {
    const c = src.class;
    return switch (c.artifact) {
        .note => chunkNote(arena, text),
        .spec => chunkSpec(arena, try std.fmt.allocPrint(arena, "{s} spec", .{c.capability.?}), text),
        .spec_delta => chunkSpec(arena, try std.fmt.allocPrint(arena, "{s} spec delta ({s})", .{ c.capability.?, c.change.? }), text),
        .proposal, .design, .tasks => chunkSections(
            arena,
            try std.fmt.allocPrint(arena, "{s} {s}", .{ c.change.?, @tagName(c.artifact) }),
            text,
        ),
    };
}

/// Lines with trailing `\r` removed, tracking whether each is inside a fenced
/// code block (fence lines themselves count as inside).
const Lines = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    in_fence: bool = false,

    const Line = struct { text: []const u8, fenced: bool };

    fn init(text: []const u8) Lines {
        return .{ .it = std.mem.splitScalar(u8, text, '\n') };
    }

    fn next(l: *Lines) ?Line {
        const raw = l.it.next() orelse return null;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            l.in_fence = !l.in_fence;
            return .{ .text = line, .fenced = true };
        }
        return .{ .text = line, .fenced = l.in_fence };
    }
};

fn isBlank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r\n").len == 0;
}

fn headingLevel(line: Lines.Line) usize {
    if (line.fenced) return 0;
    var n: usize = 0;
    while (n < line.text.len and line.text[n] == '#') n += 1;
    if (n == 0 or n >= line.text.len or line.text[n] != ' ') return 0;
    return n;
}

fn wordCount(s: []const u8) usize {
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}

pub fn chunkNote(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var title: ?[]const u8 = null;
    var paragraphs: std.ArrayList([]const u8) = .empty;
    var para: std.ArrayList(u8) = .empty;
    var in_comment = false;

    var lines: Lines = .init(text);
    while (lines.next()) |line| {
        if (!line.fenced) {
            if (in_comment) {
                if (std.mem.indexOf(u8, line.text, "-->") != null) in_comment = false;
                continue;
            }
            const trimmed = std.mem.trim(u8, line.text, " \t");
            if (std.mem.startsWith(u8, trimmed, "<!--")) {
                in_comment = std.mem.indexOf(u8, trimmed, "-->") == null;
                continue;
            }
            if (title == null and headingLevel(line) == 1) {
                title = std.mem.trim(u8, line.text[2..], " \t");
                continue;
            }
            if (isBlank(line.text)) {
                try flushParagraph(arena, &paragraphs, &para);
                continue;
            }
        }
        if (para.items.len > 0) try para.append(arena, '\n');
        try para.appendSlice(arena, line.text);
    }
    try flushParagraph(arena, &paragraphs, &para);

    var out: std.ArrayList([]const u8) = .empty;
    var group: std.ArrayList(u8) = .empty;
    var words: usize = 0;
    for (paragraphs.items) |p| {
        if (group.items.len > 0) try group.appendSlice(arena, "\n\n");
        try group.appendSlice(arena, p);
        words += wordCount(p);
        if (words >= min_note_words) {
            try out.append(arena, try withPrefix(arena, title, group.items));
            group = .empty;
            words = 0;
        }
    }
    if (group.items.len > 0) try out.append(arena, try withPrefix(arena, title, group.items));
    return out.items;
}

fn flushParagraph(arena: Allocator, paragraphs: *std.ArrayList([]const u8), para: *std.ArrayList(u8)) Allocator.Error!void {
    if (para.items.len == 0) return;
    try paragraphs.append(arena, para.items);
    para.* = .empty;
}

fn withPrefix(arena: Allocator, prefix: ?[]const u8, body: []const u8) Allocator.Error![]const u8 {
    const p = prefix orelse return arena.dupe(u8, body);
    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ p, body });
}

pub fn chunkSpec(arena: Allocator, prefix: []const u8, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var block: std.ArrayList(u8) = .empty;
    var keeping = false;

    var lines: Lines = .init(text);
    while (lines.next()) |line| {
        const level = headingLevel(line);
        if (level == 2 or level == 3) {
            try flushBlock(arena, &out, prefix, &block, keeping);
            const heading = std.mem.trim(u8, line.text[level + 1 ..], " \t");
            keeping = (level == 2 and std.ascii.eqlIgnoreCase(heading, "Purpose")) or
                (level == 3 and std.mem.startsWith(u8, heading, "Requirement:"));
        }
        if (keeping) {
            try block.appendSlice(arena, line.text);
            try block.append(arena, '\n');
        }
    }
    try flushBlock(arena, &out, prefix, &block, keeping);
    return out.items;
}

pub fn chunkSections(arena: Allocator, prefix: []const u8, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var block: std.ArrayList(u8) = .empty;

    var lines: Lines = .init(text);
    while (lines.next()) |line| {
        const level = headingLevel(line);
        if (level == 1) continue; // the document title; the prefix names the artifact
        if (level == 2) try flushBlock(arena, &out, prefix, &block, true);
        try block.appendSlice(arena, line.text);
        try block.append(arena, '\n');
    }
    try flushBlock(arena, &out, prefix, &block, true);
    return out.items;
}

/// Emits `prefix\n\n<block>` when the block has body text beyond its heading
/// line, then clears the block.
fn flushBlock(
    arena: Allocator,
    out: *std.ArrayList([]const u8),
    prefix: []const u8,
    block: *std.ArrayList(u8),
    keep: bool,
) Allocator.Error!void {
    defer block.* = .empty;
    if (!keep) return;
    const body = std.mem.trim(u8, block.items, " \t\r\n");
    const after_heading = if (std.mem.startsWith(u8, body, "#"))
        body[(std.mem.indexOfScalar(u8, body, '\n') orelse body.len)..]
    else
        body;
    if (isBlank(after_heading)) return;
    try out.append(arena, try withPrefix(arena, prefix, body));
}

// ---- tests ----

const testing = std.testing;

fn readFixture(arena: Allocator, rel: []const u8) ![]const u8 {
    const test_options = @import("test_options");
    const path = try std.fs.path.join(arena, &.{ test_options.fixture_workspace, rel });
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .unlimited);
}

test "noteMeta: the corpus-indexing stopped example" {
    const m = noteMeta("20260312-0915-stopped-2-1-needs-credentials.md");
    try testing.expectEqual(NoteKind.stopped, m.kind);
    try testing.expectEqual(NoteTime{ .year = 2026, .month = 3, .day = 12, .hour = 9, .minute = 15 }, m.time.?);

    // With discovery: repo, change and archived state come from the path.
    const class = sources.classify("changes/archive/x/devlog/20260312-0915-stopped-2-1-needs-credentials.md").?;
    const src: sources.Source = .{ .member = "api", .path = "/w/api/openspec/changes/archive/x/devlog/20260312-0915-stopped-2-1-needs-credentials.md", .rel = "", .class = class };
    try testing.expectEqualStrings("api", src.member);
    try testing.expectEqualStrings("x", src.class.change.?);
    try testing.expect(src.class.archived);
    try testing.expectEqual(sources.Artifact.note, src.class.artifact);
}

test "noteMeta: kinds from the slug's first word" {
    const cases = [_]struct { name: []const u8, kind: NoteKind }{
        .{ .name = "20260310-1015-decision-retry-policy.md", .kind = .decision },
        .{ .name = "20260311-1400-section-1-done.md", .kind = .section },
        .{ .name = "20260310-0900-section-1-start.md", .kind = .section },
        .{ .name = "20260312-1100-answer-credentials.md", .kind = .answer },
        .{ .name = "20260320-1200-change-done.md", .kind = .change },
        .{ .name = "20260314-0900-review-section-1.md", .kind = .review },
        .{ .name = "20260314-0900-review.md", .kind = .review },
        .{ .name = "20260314-0900-decisions-log.md", .kind = .note },
        .{ .name = "20260314-0900-start.md", .kind = .note },
    };
    for (cases) |c| {
        const m = noteMeta(c.name);
        try testing.expectEqual(c.kind, m.kind);
        try testing.expect(m.time != null);
    }
    for ([_][]const u8{ "notes.md", "2026-0312-0915-x.md", "20261312-0915-decision-x.md", "20260312-2460-decision-x.md", "20260312-0915-" }) |bad| {
        const m = noteMeta(bad);
        try testing.expectEqual(NoteKind.note, m.kind);
        try testing.expect(m.time == null);
    }
}

test "chunkNote: long note split, title on every passage, comment dropped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try readFixture(arena, "alpha/openspec/changes/archive/2026-03-10-add-retry/devlog/20260310-1015-decision-retry-policy.md");
    try testing.expect(wordCount(text) >= 300);

    const ps = try chunkNote(arena, text);
    try testing.expect(ps.len > 1);
    for (ps, 0..) |p, i| {
        try testing.expect(std.mem.startsWith(u8, p, "Decision: retry policy\n\n"));
        try testing.expect(std.mem.indexOf(u8, p, "<!--") == null);
        try testing.expect(std.mem.indexOf(u8, p, "# Decision") == null);
        // Every group but the last reaches the word threshold (title excluded).
        if (i + 1 < ps.len) try testing.expect(wordCount(p) - 3 >= min_note_words);
    }
    // No text is lost: each paragraph's opening words land in some passage.
    for ([_][]const u8{ "We need a retry policy", "The options considered", "We chose a fixed 500 ms", "Only connection failures", "## Next" }) |needle| {
        var found = false;
        for (ps) |p| found = found or std.mem.indexOf(u8, p, needle) != null;
        try testing.expect(found);
    }
}

test "chunkNote: short note is one passage; fences and multi-line comments" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const short = try chunkNote(arena, "# Answer: x\r\n\r\nYes.\r\n\r\n## Next\r\n\r\n- Go.\r\n");
    try testing.expectEqual(@as(usize, 1), short.len);
    try testing.expectEqualStrings("Answer: x\n\nYes.\n\n## Next\n\n- Go.", short[0]);

    const fenced = try chunkNote(arena,
        \\# T
        \\<!-- Section: 1
        \\  spans lines -->
        \\Before.
        \\
        \\```
        \\# not a title
        \\
        \\<!-- not a comment -->
        \\```
    );
    try testing.expectEqual(@as(usize, 1), fenced.len);
    try testing.expectEqualStrings("T\n\nBefore.\n\n```\n# not a title\n\n<!-- not a comment -->\n```", fenced[0]);

    const untitled = try chunkNote(arena, "Just text.");
    try testing.expectEqualStrings("Just text.", untitled[0]);
}

test "chunkSpec: purpose plus one passage per requirement with scenarios" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try readFixture(arena, "alpha/openspec/specs/auth/spec.md");

    const ps = try chunkSpec(arena, "auth spec", text);
    try testing.expectEqual(@as(usize, 4), ps.len);
    try testing.expect(std.mem.startsWith(u8, ps[0], "auth spec\n\n## Purpose\n\nAuthenticates"));
    try testing.expect(std.mem.startsWith(u8, ps[1], "auth spec\n\n### Requirement: Token refresh"));
    try testing.expect(std.mem.indexOf(u8, ps[1], "#### Scenario: Token near expiry") != null);
    try testing.expect(std.mem.indexOf(u8, ps[1], "Retry transient") == null);
    try testing.expect(std.mem.startsWith(u8, ps[2], "auth spec\n\n### Requirement: Retry transient failures"));
    try testing.expect(std.mem.indexOf(u8, ps[2], "#### Scenario: Upstream returns 503") != null);
    try testing.expect(std.mem.startsWith(u8, ps[3], "auth spec\n\n### Requirement: Credentials from the environment"));
    for (ps) |p| try testing.expect(std.mem.indexOf(u8, p, "## Requirements") == null);

    // A delta: requirements under ADDED/MODIFIED headings; no purpose.
    const delta = try chunkSpec(arena, "cache spec delta (add-cache)",
        \\# Spec Delta
        \\## ADDED Requirements
        \\### Requirement: A
        \\Body A.
        \\## MODIFIED Requirements
        \\### Requirement: B
        \\Body B.
        \\## Purpose
        \\
    );
    try testing.expectEqual(@as(usize, 2), delta.len);
    try testing.expectEqualStrings("cache spec delta (add-cache)\n\n### Requirement: A\nBody A.", delta[0]);
    try testing.expectEqualStrings("cache spec delta (add-cache)\n\n### Requirement: B\nBody B.", delta[1]);
}

test "chunkSections: preamble with body, one per ## section, empty sections skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const proposal = try chunkSections(arena, "add-retry proposal", try readFixture(arena, "alpha/openspec/changes/archive/2026-03-10-add-retry/proposal.md"));
    try testing.expectEqual(@as(usize, 3), proposal.len);
    try testing.expect(std.mem.startsWith(u8, proposal[0], "add-retry proposal\n\nAlpha's calls"));
    try testing.expect(std.mem.startsWith(u8, proposal[1], "add-retry proposal\n\n## Why"));
    try testing.expect(std.mem.startsWith(u8, proposal[2], "add-retry proposal\n\n## What Changes"));

    const design = try chunkSections(arena, "add-retry design", try readFixture(arena, "alpha/openspec/changes/archive/2026-03-10-add-retry/design.md"));
    try testing.expectEqual(@as(usize, 3), design.len); // title-only preamble and "## Empty section" yield nothing
    try testing.expect(std.mem.startsWith(u8, design[0], "add-retry design\n\n## Context"));
    try testing.expect(std.mem.indexOf(u8, design[1], "### D1. Retry in the client") != null);
    try testing.expect(std.mem.startsWith(u8, design[2], "add-retry design\n\n## Risks"));

    const fenced = try chunkSections(arena, "c tasks", "## 1. A\n```\n## not a heading\n```\n");
    try testing.expectEqual(@as(usize, 1), fenced.len);
}

test "passages: dispatch and context prefixes from the source class" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const req = "### Requirement: R\nBody.\n";
    const mk = struct {
        fn f(rel: []const u8) sources.Source {
            return .{ .member = "alpha", .path = rel, .rel = rel, .class = sources.classify(rel).? };
        }
    }.f;

    try testing.expectEqualStrings("auth spec\n\n### Requirement: R\nBody.", (try passages(arena, mk("specs/auth/spec.md"), req))[0]);
    try testing.expectEqualStrings("cache spec delta (add-cache)\n\n### Requirement: R\nBody.", (try passages(arena, mk("changes/add-cache/specs/cache/spec.md"), req))[0]);
    try testing.expectEqualStrings("add-retry tasks\n\n## 1. A\n- [x] 1.1", (try passages(arena, mk("changes/archive/2026-03-10-add-retry/tasks.md"), "## 1. A\n- [x] 1.1\n"))[0]);
    try testing.expectEqualStrings("T\n\nBody.", (try passages(arena, mk("changes/c/devlog/20260101-0000-note.md"), "# T\n\nBody.\n"))[0]);
}

test "kind names match the spec" {
    const mk = struct {
        fn f(rel: []const u8) sources.Source {
            return .{ .member = "alpha", .path = rel, .rel = rel, .class = sources.classify(rel).? };
        }
    }.f;
    try testing.expectEqualStrings("spec", kind(mk("specs/auth/spec.md")));
    try testing.expectEqualStrings("spec-delta", kind(mk("changes/c/specs/auth/spec.md")));
    try testing.expectEqualStrings("proposal", kind(mk("changes/c/proposal.md")));
    try testing.expectEqualStrings("design", kind(mk("changes/c/design.md")));
    try testing.expectEqualStrings("tasks", kind(mk("changes/c/tasks.md")));
    try testing.expectEqualStrings("stopped", kind(mk("changes/archive/x/devlog/20260312-0915-stopped-2-1-needs-credentials.md")));
    try testing.expectEqualStrings("note", kind(mk("changes/c/devlog/notes.md")));
}

test "fixture end to end: no excluded text reaches a passage" {
    const test_options = @import("test_options");
    const workspace = @import("workspace.zig");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diag: workspace.Diag = .{};
    const ws = try workspace.resolve(arena, testing.io, test_options.fixture_workspace, &diag);
    var active_delta_seen = false;
    var total: usize = 0;
    for (try sources.discover(arena, testing.io, ws)) |src| {
        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, src.path, arena, .unlimited);
        const ps = try passages(arena, src, text);
        try testing.expect(ps.len > 0);
        total += ps.len;
        for (ps) |p| {
            for ([_][]const u8{ "UNDECLARED-SIBLING-MARKER", "ARCHIVED-DELTA-MARKER", "LEGACY-DEVLOG-MARKER" }) |m|
                try testing.expect(std.mem.indexOf(u8, p, m) == null);
            active_delta_seen = active_delta_seen or std.mem.indexOf(u8, p, "ACTIVE-DELTA-MARKER") != null;
        }
    }
    try testing.expect(active_delta_seen);
    try testing.expect(total > 19);
}
