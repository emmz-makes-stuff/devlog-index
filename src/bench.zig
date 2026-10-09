//! Hidden `bench-cold` command (task 2.2): measures the cold-query path —
//! process start, model load, one query embedding, and a vector search over
//! a workspace-sized table — against the 1 s budget (workspace-query, Query
//! latency).
//!
//!   devlog-index bench-cold --setup <db>   build <db> with random vectors
//!   devlog-index bench-cold <db>           time one cold query against it
//!
//! Run the second form as a fresh process and time it from outside as well
//! (`time devlog-index bench-cold <db>`): the in-process phases can't see
//! process start-up.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const model_mod = @import("model.zig");
const model_url = @import("model_url.zig");
const download = @import("download.zig");
const embed_mod = @import("embed.zig");

const c = sqlite.c;

/// About the size of the first real workspace (design: 3,222 passages).
pub const passage_count = 3200;
const dim = 768;

pub fn run(init: std.process.Init, args: []const [:0]const u8, out: *std.Io.Writer) !void {
    if (args.len == 2 and std.mem.eql(u8, args[0], "--setup")) return setup(args[1], out);
    if (args.len != 1) return error.Usage;
    return measure(init, args[0], out);
}

fn setup(path: [:0]const u8, out: *std.Io.Writer) !void {
    sqlite.registerVec();
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path.ptr, &db) != c.SQLITE_OK) return error.SqliteOpenFailed;
    defer _ = c.sqlite3_close(db);

    try exec(db, "DROP TABLE IF EXISTS bench_vec; CREATE VIRTUAL TABLE bench_vec USING vec0(embedding float[768] distance_metric=cosine); BEGIN;");

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "INSERT INTO bench_vec(rowid, embedding) VALUES (?, ?)", -1, &stmt, null) != c.SQLITE_OK)
        return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    var vec: [dim]f32 = undefined;
    for (1..passage_count + 1) |rowid| {
        var sum: f32 = 0;
        for (&vec) |*v| {
            v.* = rand.floatNorm(f32);
            sum += v.* * v.*;
        }
        const norm = std.math.sqrt(sum);
        for (&vec) |*v| v.* /= norm;

        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(rowid));
        _ = c.sqlite3_bind_blob(stmt, 2, &vec, @sizeOf(@TypeOf(vec)), c.SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
    }
    try exec(db, "COMMIT;");
    try out.print("bench-cold: wrote {d} random {d}-d vectors to {s}\n", .{ passage_count, dim, path });
}

fn measure(init: std.process.Init, path: [:0]const u8, out: *std.Io.Writer) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const t0 = now();

    const home = init.environ_map.get("HOME") orelse return error.NoHome;
    const parsed = try model_url.parse(model_url.pinned_url);
    const model_path = try model_url.cachePathZ(arena, home, parsed);
    if (try download.ensureCached(gpa, init.io, model_path, model_url.pinned_url))
        return error.ModelWasDownloaded; // the timing would include the download; run again

    model_mod.initBackend();
    defer model_mod.deinitBackend();
    var model = try model_mod.Model.loadFromFile(model_path, .{ .quiet = true });
    defer model.deinit();
    var emb = try embed_mod.Embedder.init(model, true);
    defer emb.deinit();
    const t_load = now();

    const q = try emb.embed(gpa, .query, "what is the standard for naming services");
    defer gpa.free(q);
    const t_embed = now();

    sqlite.registerVec();
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK) return error.SqliteOpenFailed;
    defer _ = c.sqlite3_close(db);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "SELECT rowid, distance FROM bench_vec WHERE embedding MATCH ? AND k = 5", -1, &stmt, null) != c.SQLITE_OK)
        return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_blob(stmt, 1, q.ptr, @intCast(q.len * @sizeOf(f32)), c.SQLITE_STATIC);
    var hits: usize = 0;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) hits += 1;
    if (hits != 5) return error.UnexpectedHitCount;
    const t_search = now();

    try out.print(
        \\bench-cold: model load {d} ms, query embed {d} ms, vector search over {d} {d} ms, total in-process {d} ms
        \\
    , .{ ms(t0, t_load), ms(t_load, t_embed), passage_count, ms(t_embed, t_search), ms(t0, t_search) });
}

fn exec(db: ?*c.sqlite3, sql: [:0]const u8) !void {
    var err: [*c]u8 = null;
    if (c.sqlite3_exec(db, sql.ptr, null, null, &err) != c.SQLITE_OK) {
        std.log.err("sqlite: {s}", .{err});
        c.sqlite3_free(err);
        return error.SqliteExecFailed;
    }
}

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn ms(from: u64, to: u64) u64 {
    return (to - from) / std.time.ns_per_ms;
}
