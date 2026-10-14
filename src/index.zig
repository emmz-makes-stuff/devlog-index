//! The workspace index (design D3): one SQLite database at
//! `<root>/.devlog-index/index.db`.
//!
//! - `settings`: schema version, model URL, vector dimension.
//! - `files`: one row per indexed file, with its hash, size and mtime (D9)
//!   and the passage metadata that is constant per file.
//! - `passages`: text per passage, with a text hash so unchanged passages
//!   can reuse their vectors when a file moves or is edited.
//! - `passages_fts`: FTS5 (porter) over passage text, rowid = passage id.
//!   External content: the text lives only in `passages`, so a delete goes
//!   through the FTS `'delete'` command with the old text.
//! - `passages_vec`: vec0 cosine vectors, rowid = passage id. Created on the
//!   first embedding, since the dimension comes from the loaded model.
//!
//! The model URL is pinned at creation and the dimension at the first
//! embedding; a different model is refused with the rebuild command.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dbm = @import("db.zig");
const Db = dbm.Db;

/// 2: `passages_fts` reads its text from `passages` (external content).
pub const schema_version = "2";
pub const db_basename = "index.db";
pub const rebuild_command = "devlog-index update --rebuild";

pub const Diag = struct {
    message: []const u8 = "",
};

pub const OpenError = error{ ModelMismatch, SchemaMismatch } || dbm.Error || Allocator.Error;

const schema =
    \\CREATE TABLE IF NOT EXISTS settings(
    \\  key TEXT PRIMARY KEY,
    \\  value TEXT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS files(
    \\  id INTEGER PRIMARY KEY,
    \\  path TEXT NOT NULL UNIQUE,
    \\  member TEXT NOT NULL,
    \\  rel TEXT NOT NULL,
    \\  hash TEXT NOT NULL,
    \\  size INTEGER NOT NULL,
    \\  mtime_ns INTEGER NOT NULL,
    \\  kind TEXT NOT NULL,
    \\  change TEXT,
    \\  archived INTEGER NOT NULL,
    \\  capability TEXT,
    \\  note_time TEXT,
    \\  indexed_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS files_change ON files(member, change, note_time);
    \\CREATE TABLE IF NOT EXISTS passages(
    \\  id INTEGER PRIMARY KEY,
    \\  file_id INTEGER NOT NULL REFERENCES files(id),
    \\  ordinal INTEGER NOT NULL,
    \\  title TEXT,
    \\  text TEXT NOT NULL,
    \\  text_hash TEXT NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS passages_file ON passages(file_id);
    \\CREATE INDEX IF NOT EXISTS passages_text_hash ON passages(text_hash);
    \\CREATE VIRTUAL TABLE IF NOT EXISTS passages_fts USING fts5(text, content = 'passages', content_rowid = 'id', tokenize = 'porter');
;

pub const Index = struct {
    db: Db,
    path: []const u8,
    model_url: []const u8,
    /// Null until the vector table exists.
    dim: ?u32,

    /// Open (creating if needed) the index at `path` for writing. A new
    /// index is pinned to `model_url`; an existing one built with another
    /// model or schema is refused, with `diag.message` naming both and the
    /// rebuild command.
    pub fn open(arena: Allocator, path: [:0]const u8, model_url: []const u8, diag: *Diag) OpenError!Index {
        var db = try Db.open(path, .read_write_create);
        errdefer db.close();
        // WAL, so `status` and `query` read the last committed index while a
        // long update is writing. Persistent in the file; set outside a
        // transaction.
        try db.exec("PRAGMA journal_mode = WAL");
        try db.exec("BEGIN IMMEDIATE");
        errdefer db.exec("ROLLBACK") catch {};
        try db.exec(schema);
        var ix: Index = .{ .db = db, .path = path, .model_url = model_url, .dim = null };

        const stored_schema = try ix.setting(arena, "schema_version");
        const stored_url = try ix.setting(arena, "model_url");
        if (stored_schema == null and stored_url == null) {
            try ix.putSetting("schema_version", schema_version);
            try ix.putSetting("model_url", model_url);
        } else {
            if (stored_schema == null or !std.mem.eql(u8, stored_schema.?, schema_version)) {
                diag.message = try std.fmt.allocPrint(arena, "{s} has index schema {s}, this devlog-index uses {s}; rebuild it with: {s}", .{ path, stored_schema orelse "(none)", schema_version, rebuild_command });
                return error.SchemaMismatch;
            }
            if (stored_url == null or !std.mem.eql(u8, stored_url.?, model_url)) {
                diag.message = try std.fmt.allocPrint(arena, "{s} was built with model {s}, but this devlog-index uses {s}; rebuild it with: {s}", .{ path, stored_url orelse "(none)", model_url, rebuild_command });
                return error.ModelMismatch;
            }
        }
        if (try ix.setting(arena, "dim")) |d| ix.dim = std.fmt.parseInt(u32, d, 10) catch return error.SqliteFailed;
        try db.exec("COMMIT");
        return ix;
    }

    pub fn close(ix: *Index) void {
        ix.db.close();
        ix.* = undefined;
    }

    pub fn setting(ix: Index, arena: Allocator, key: []const u8) (dbm.Error || Allocator.Error)!?[]const u8 {
        return readSetting(arena, ix.db, key);
    }

    pub fn putSetting(ix: Index, key: []const u8, value: []const u8) dbm.Error!void {
        var s = try ix.db.prepare("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value");
        defer s.finalize();
        try s.bindText(1, key);
        try s.bindText(2, value);
        try s.run();
    }

    /// Create the vector table for `dim` on first use, or refuse a model
    /// whose dimension differs from the one the index was built with. Call
    /// inside the update's transaction.
    pub fn ensureVec(ix: *Index, arena: Allocator, dim: u32, diag: *Diag) OpenError!void {
        if (ix.dim) |have| {
            if (have == dim) return;
            diag.message = try std.fmt.allocPrint(arena, "{s} holds {d}-d vectors, but model {s} produces {d}-d; rebuild it with: {s}", .{ ix.path, have, ix.model_url, dim, rebuild_command });
            return error.ModelMismatch;
        }
        const sql = try std.fmt.allocPrintSentinel(arena, "CREATE VIRTUAL TABLE passages_vec USING vec0(embedding float[{d}] distance_metric=cosine)", .{dim}, 0);
        try ix.db.exec(sql);
        try ix.putSetting("dim", try std.fmt.allocPrint(arena, "{d}", .{dim}));
        ix.dim = dim;
    }
};

pub const ReadError = error{ NoIndex, SchemaMismatch, IndexBusy, IndexUnreadable } || Allocator.Error;

/// Open an existing index read-only, for `status` and `query`. A missing
/// index, another schema or an unreadable file is an error with
/// `diag.message` saying what to run.
pub fn openRead(arena: Allocator, io: std.Io, path: [:0]const u8, diag: *Diag) ReadError!Db {
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        diag.message = try std.fmt.allocPrint(arena, "no index at {s}; build it with: devlog-index update", .{path});
        return error.NoIndex;
    };
    var db = Db.open(path, .read_only) catch {
        diag.message = try std.fmt.allocPrint(arena, "cannot open {s}; rebuild it with: {s}", .{ path, rebuild_command });
        return error.IndexUnreadable;
    };
    errdefer db.close();
    const stored = readSetting(arena, db, "schema_version") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SqliteBusy => {
            diag.message = try std.fmt.allocPrint(arena, "{s} is locked by another devlog-index; try again shortly", .{path});
            return error.IndexBusy;
        },
        else => {
            diag.message = try std.fmt.allocPrint(arena, "cannot read {s}; rebuild it with: {s}", .{ path, rebuild_command });
            return error.IndexUnreadable;
        },
    };
    if (stored == null or !std.mem.eql(u8, stored.?, schema_version)) {
        diag.message = try std.fmt.allocPrint(arena, "{s} has index schema {s}, this devlog-index uses {s}; rebuild it with: {s}", .{ path, stored orelse "(none)", schema_version, rebuild_command });
        return error.SchemaMismatch;
    }
    return db;
}

pub fn readSetting(arena: Allocator, db: Db, key: []const u8) (dbm.Error || Allocator.Error)!?[]const u8 {
    var s = try db.prepare("SELECT value FROM settings WHERE key = ?");
    defer s.finalize();
    try s.bindText(1, key);
    if (!try s.step()) return null;
    return try arena.dupe(u8, s.text(0));
}

// ---- tests ----

const testing = std.testing;

fn tmpIndexPath(arena: Allocator, tmp: *testing.TmpDir) ![:0]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    return std.fs.path.joinZ(arena, &.{ buf[0..n], db_basename });
}

test "open bootstraps the schema and pins the model" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpIndexPath(arena, &tmp);

    var diag: Diag = .{};
    {
        var ix = try Index.open(arena, path, "https://example/model-a.gguf", &diag);
        defer ix.close();
        try testing.expectEqualStrings("https://example/model-a.gguf", (try ix.setting(arena, "model_url")).?);
        try testing.expectEqualStrings(schema_version, (try ix.setting(arena, "schema_version")).?);
        try testing.expect(ix.dim == null);
        try testing.expectEqual(@as(?i64, 0), try ix.db.oneInt("SELECT count(*) FROM files"));
        try testing.expectEqual(@as(?i64, 0), try ix.db.oneInt("SELECT count(*) FROM passages_fts"));
        try ix.ensureVec(arena, 4, &diag);
        try ix.ensureVec(arena, 4, &diag);
        try testing.expectEqual(@as(?i64, 0), try ix.db.oneInt("SELECT count(*) FROM passages_vec"));
    }
    {
        var ix = try Index.open(arena, path, "https://example/model-a.gguf", &diag);
        defer ix.close();
        try testing.expectEqual(@as(?u32, 4), ix.dim);
        try testing.expectError(error.ModelMismatch, ix.ensureVec(arena, 8, &diag));
        try testing.expect(std.mem.indexOf(u8, diag.message, "4-d") != null);
        try testing.expect(std.mem.indexOf(u8, diag.message, "8-d") != null);
        try testing.expect(std.mem.indexOf(u8, diag.message, rebuild_command) != null);
    }
}

test "open refuses a different model, naming both and the rebuild command" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpIndexPath(arena, &tmp);

    var diag: Diag = .{};
    var a = try Index.open(arena, path, "https://example/model-a.gguf", &diag);
    a.close();
    try testing.expectError(error.ModelMismatch, Index.open(arena, path, "https://example/model-b.gguf", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "model-a.gguf") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "model-b.gguf") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, rebuild_command) != null);

    // The refused open left the index as it was.
    var again = try Index.open(arena, path, "https://example/model-a.gguf", &diag);
    again.close();
}

test "the index is in WAL mode; openRead checks it exists and its schema" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpIndexPath(arena, &tmp);

    var diag: Diag = .{};
    try testing.expectError(error.NoIndex, openRead(arena, testing.io, path, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "devlog-index update") != null);

    var ix = try Index.open(arena, path, "https://example/model-a.gguf", &diag);
    {
        var s = try ix.db.prepare("PRAGMA journal_mode");
        defer s.finalize();
        try testing.expect(try s.step());
        try testing.expectEqualStrings("wal", s.text(0));
    }
    ix.close();

    var r = try openRead(arena, testing.io, path, &diag);
    r.close();

    var w = try Db.open(path, .read_write_create);
    try w.exec("UPDATE settings SET value = '0' WHERE key = 'schema_version'");
    w.close();
    try testing.expectError(error.SchemaMismatch, openRead(arena, testing.io, path, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, rebuild_command) != null);

    // An index from before external-content FTS (version 1) is refused too.
    w = try Db.open(path, .read_write_create);
    try w.exec("UPDATE settings SET value = '1' WHERE key = 'schema_version'");
    w.close();
    try testing.expectError(error.SchemaMismatch, openRead(arena, testing.io, path, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "has index schema 1, this devlog-index uses 2") != null);
}
