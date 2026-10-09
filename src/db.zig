//! A thin wrapper over the vendored SQLite C API: open, exec, prepared
//! statements. Errors carry SQLite's message through `Db.lastError`.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const c = sqlite.c;

/// SQLITE_TRANSIENT is `(sqlite3_destructor_type)-1`, which Zig cannot hold in a
/// function pointer (misaligned). These declarations take the destructor as a
/// pointer-sized integer instead, which is ABI-identical.
const transient: isize = -1;
extern fn sqlite3_bind_text(*c.sqlite3_stmt, c_int, [*]const u8, c_int, isize) c_int;
extern fn sqlite3_bind_blob(*c.sqlite3_stmt, c_int, [*]const u8, c_int, isize) c_int;

pub const Error = error{ SqliteOpenFailed, SqliteFailed, SqliteBusy };

pub const Mode = enum { read_only, read_write_create };

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8, mode: Mode) Error!Db {
        sqlite.registerVec();
        var h: ?*c.sqlite3 = null;
        const flags: c_int = switch (mode) {
            .read_only => c.SQLITE_OPEN_READONLY,
            .read_write_create => c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
        };
        if (c.sqlite3_open_v2(path.ptr, &h, flags, null) != c.SQLITE_OK) {
            if (h) |opened| _ = c.sqlite3_close(opened);
            return error.SqliteOpenFailed;
        }
        _ = c.sqlite3_busy_timeout(h, 5000);
        return .{ .handle = h.? };
    }

    pub fn close(db: *Db) void {
        _ = c.sqlite3_close(db.handle);
        db.* = undefined;
    }

    pub fn lastError(db: Db) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(db.handle));
    }

    pub fn exec(db: Db, sql: [:0]const u8) Error!void {
        const rc = c.sqlite3_exec(db.handle, sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) return mapRc(rc);
    }

    pub fn prepare(db: Db, sql: []const u8) Error!Stmt {
        var s: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &s, null);
        if (rc != c.SQLITE_OK) return mapRc(rc);
        return .{ .handle = s.? };
    }

    pub fn lastInsertRowId(db: Db) i64 {
        return c.sqlite3_last_insert_rowid(db.handle);
    }

    /// Replace this database's content with `src`'s, page for page, under
    /// SQLite's own locking: readers of `dest` (in WAL mode) keep seeing the
    /// old content until the copy commits.
    pub fn replaceWith(dest: Db, src: Db) Error!void {
        const b = c.sqlite3_backup_init(dest.handle, "main", src.handle, "main") orelse
            return mapRc(c.sqlite3_errcode(dest.handle));
        const rc = c.sqlite3_backup_step(b, -1);
        const finish_rc = c.sqlite3_backup_finish(b);
        if (rc != c.SQLITE_DONE) return mapRc(rc);
        try check(finish_rc);
    }

    /// The single integer a query returns, or null when it returns no row.
    pub fn oneInt(db: Db, sql: []const u8) Error!?i64 {
        var s = try db.prepare(sql);
        defer s.finalize();
        if (!try s.step()) return null;
        return s.int(0);
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn finalize(s: *Stmt) void {
        _ = c.sqlite3_finalize(s.handle);
        s.* = undefined;
    }

    pub fn reset(s: Stmt) void {
        _ = c.sqlite3_reset(s.handle);
        _ = c.sqlite3_clear_bindings(s.handle);
    }

    /// Binds are 1-based, as in SQLite. Text and blobs are copied
    /// (SQLITE_TRANSIENT), so the caller's memory may be freed afterwards.
    pub fn bindText(s: Stmt, i: c_int, v: []const u8) Error!void {
        try check(sqlite3_bind_text(s.handle, i, v.ptr, @intCast(v.len), transient));
    }

    pub fn bindOptText(s: Stmt, i: c_int, v: ?[]const u8) Error!void {
        if (v) |t| return s.bindText(i, t);
        try check(c.sqlite3_bind_null(s.handle, i));
    }

    pub fn bindInt(s: Stmt, i: c_int, v: i64) Error!void {
        try check(c.sqlite3_bind_int64(s.handle, i, v));
    }

    pub fn bindBlob(s: Stmt, i: c_int, v: []const u8) Error!void {
        try check(sqlite3_bind_blob(s.handle, i, v.ptr, @intCast(v.len), transient));
    }

    /// True when a row is available, false when the statement is done.
    pub fn step(s: Stmt) Error!bool {
        const rc = c.sqlite3_step(s.handle);
        return switch (rc) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => mapRc(rc),
        };
    }

    /// Step a statement that returns no rows, then reset it for reuse.
    pub fn run(s: Stmt) Error!void {
        defer s.reset();
        _ = try s.step();
    }

    pub fn int(s: Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(s.handle, col);
    }

    pub fn isNull(s: Stmt, col: c_int) bool {
        return c.sqlite3_column_type(s.handle, col) == c.SQLITE_NULL;
    }

    /// Valid until the next step/reset/finalize.
    pub fn text(s: Stmt, col: c_int) []const u8 {
        const p = c.sqlite3_column_text(s.handle, col) orelse return "";
        return p[0..@intCast(c.sqlite3_column_bytes(s.handle, col))];
    }

    /// Valid until the next step/reset/finalize.
    pub fn blob(s: Stmt, col: c_int) []const u8 {
        const p: [*]const u8 = @ptrCast(c.sqlite3_column_blob(s.handle, col) orelse return "");
        return p[0..@intCast(c.sqlite3_column_bytes(s.handle, col))];
    }
};

fn check(rc: c_int) Error!void {
    if (rc != c.SQLITE_OK) return mapRc(rc);
}

fn mapRc(rc: c_int) Error {
    return switch (rc & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.SqliteBusy,
        else => error.SqliteFailed,
    };
}

test "prepare, bind, step round trip" {
    var db = try Db.open(":memory:", .read_write_create);
    defer db.close();
    try db.exec("CREATE TABLE t(a INTEGER, b TEXT, c BLOB)");
    var ins = try db.prepare("INSERT INTO t VALUES (?, ?, ?)");
    defer ins.finalize();
    try ins.bindInt(1, 7);
    try ins.bindOptText(2, null);
    try ins.bindBlob(3, "xy");
    try ins.run();

    var sel = try db.prepare("SELECT a, b, c FROM t");
    defer sel.finalize();
    try std.testing.expect(try sel.step());
    try std.testing.expectEqual(@as(i64, 7), sel.int(0));
    try std.testing.expect(sel.isNull(1));
    try std.testing.expectEqualStrings("xy", sel.blob(2));
    try std.testing.expect(!try sel.step());
    try std.testing.expectEqual(@as(?i64, 1), try db.oneInt("SELECT count(*) FROM t"));
    try std.testing.expectError(error.SqliteFailed, db.exec("SELECT * FROM nope"));
}

fn tmpDbPath(buf: []u8, tmp: *std.testing.TmpDir, name: []const u8) ![:0]const u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &dir_buf);
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir_buf[0..n], name });
}

test "WAL: a reader sees the last commit while a write transaction is open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpDbPath(&buf, &tmp, "w.db");

    var w = try Db.open(path, .read_write_create);
    defer w.close();
    try w.exec("PRAGMA journal_mode = WAL");
    try w.exec("CREATE TABLE t(a INTEGER); INSERT INTO t VALUES (1)");
    try w.exec("BEGIN IMMEDIATE; INSERT INTO t VALUES (2), (3)");

    var r = try Db.open(path, .read_only);
    defer r.close();
    try std.testing.expectEqual(@as(?i64, 1), try r.oneInt("SELECT count(*) FROM t"));
    try w.exec("COMMIT");
    try std.testing.expectEqual(@as(?i64, 3), try r.oneInt("SELECT count(*) FROM t"));
}

test "WAL: a cleanly closed database opens read-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpDbPath(&buf, &tmp, "w.db");
    {
        var w = try Db.open(path, .read_write_create);
        defer w.close();
        try w.exec("PRAGMA journal_mode = WAL; CREATE TABLE t(a INTEGER); INSERT INTO t VALUES (1)");
    }
    var r = try Db.open(path, .read_only);
    defer r.close();
    try std.testing.expectEqual(@as(?i64, 1), try r.oneInt("SELECT count(*) FROM t"));
}

test "replaceWith swaps content under an open reader" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    const live_path = try tmpDbPath(&buf_a, &tmp, "live.db");
    const new_path = try tmpDbPath(&buf_b, &tmp, "new.db");

    var live = try Db.open(live_path, .read_write_create);
    defer live.close();
    try live.exec("PRAGMA journal_mode = WAL; CREATE TABLE old(a INTEGER)");
    var reader = try Db.open(live_path, .read_only);
    defer reader.close();
    try std.testing.expectEqual(@as(?i64, 0), try reader.oneInt("SELECT count(*) FROM old"));

    {
        var fresh = try Db.open(new_path, .read_write_create);
        defer fresh.close();
        try fresh.exec("PRAGMA journal_mode = WAL; CREATE TABLE t(a INTEGER); INSERT INTO t VALUES (7)");
        try live.replaceWith(fresh);
    }
    try std.testing.expectEqual(@as(?i64, 7), try reader.oneInt("SELECT a FROM t"));
    try std.testing.expectError(error.SqliteFailed, reader.exec("SELECT * FROM old"));
}
