//! The vendored SQLite + sqlite-vec C API, and the one-time sqlite-vec
//! registration every connection needs.

const std = @import("std");

pub const c = @cImport({
    @cDefine("SQLITE_CORE", "1");
    @cInclude("sqlite3.h");
    @cInclude("sqlite-vec.h");
});

/// Registers sqlite-vec as an auto-extension, so every connection opened
/// afterwards has `vec0`. Idempotent: SQLite ignores a repeat registration.
pub fn registerVec() void {
    _ = c.sqlite3_auto_extension(@ptrCast(&c.sqlite3_vec_init));
}

test "in-memory DB has FTS5 and vec0" {
    registerVec();
    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &db));
    defer _ = c.sqlite3_close_v2(db);

    const sql =
        \\CREATE VIRTUAL TABLE t_fts USING fts5(body, tokenize = 'porter');
        \\INSERT INTO t_fts(body) VALUES ('naming conventions for services');
        \\CREATE VIRTUAL TABLE t_vec USING vec0(embedding float[4]);
        \\INSERT INTO t_vec(rowid, embedding) VALUES (1, '[1, 0, 0, 0]');
    ;
    var err: [*c]u8 = null;
    const rc = c.sqlite3_exec(db, sql, null, null, &err);
    if (rc != c.SQLITE_OK) {
        std.debug.print("sqlite: {s}\n", .{err});
        c.sqlite3_free(err);
    }
    try std.testing.expectEqual(c.SQLITE_OK, rc);

    // Porter stemming: "convention" matches "conventions".
    var stmt: ?*c.sqlite3_stmt = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, "SELECT count(*) FROM t_fts WHERE t_fts MATCH 'convention'", -1, &stmt, null));
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(stmt, 0));
    _ = c.sqlite3_finalize(stmt);

    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, "SELECT rowid FROM t_vec WHERE embedding MATCH '[1, 0, 0, 0]' AND k = 1", -1, &stmt, null));
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 1), c.sqlite3_column_int64(stmt, 0));
    _ = c.sqlite3_finalize(stmt);
}
