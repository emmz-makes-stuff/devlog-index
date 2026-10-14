//! `update [--rebuild]` (corpus-indexing, Incremental update; design D3).
//!
//! Discovers the workspace's sources, hashes them, and compares with the
//! `files` table: new files are added, files whose hash changed are
//! re-chunked, files no longer found are removed. Files of a member that is
//! missing right now are kept (reported, not dropped); a member removed from
//! the config loses its files.
//!
//! All writes happen in one transaction, committed at the end, so an
//! interrupted or failed update leaves the previous index as it was. New
//! passages are inserted before old ones are deleted, and a passage whose
//! exact text is already indexed reuses that vector, so archiving a change
//! or lightly editing a note costs few or no embeddings.
//!
//! The embedding model is obtained from a `Provider` on first need only: a
//! run with nothing to embed never loads (or downloads) it. `--rebuild`
//! builds a fresh index beside the old one, then swaps it in (`swapIn`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const workspace = @import("workspace.zig");
const sources = @import("sources.zig");
const chunk = @import("chunk.zig");
const dbm = @import("db.zig");
const index = @import("index.zig");
const model_mod = @import("model.zig");
const model_url = @import("model_url.zig");
const download = @import("download.zig");
const embed_mod = @import("embed.zig");
const freshness = @import("freshness.zig");

pub const Embedder = struct {
    ptr: *anyopaque,
    dim: u32,
    embedFn: *const fn (ptr: *anyopaque, gpa: Allocator, text: []const u8) anyerror![]f32,

    /// The vector for `text` (document or query, per the provider's task); caller owns it.
    pub fn embed(e: Embedder, gpa: Allocator, text: []const u8) anyerror![]f32 {
        return e.embedFn(e.ptr, gpa, text);
    }
};

/// Supplies the embedder on first need. `get` may download and load a
/// model on its first call; query and eval call it once per query, so later
/// calls must return the loaded embedder.
pub const Provider = struct {
    ptr: *anyopaque,
    getFn: *const fn (ptr: *anyopaque) anyerror!Embedder,
};

pub const Options = struct {
    rebuild: bool = false,
    model_url: []const u8 = model_url.pinned_url,
    provider: Provider,
    /// Progress lines while embedding (stderr in the CLI); null for none.
    progress: ?*Io.Writer = null,
};

/// A progress line every this many embedded passages.
pub const progress_every = 100;

pub const Report = struct {
    added: usize = 0,
    changed: usize = 0,
    removed: usize = 0,
    unchanged: usize = 0,
    passages_embedded: usize = 0,
    passages_reused: usize = 0,
    /// Passages in the index after the update.
    passages_total: usize = 0,
    missing_members: []const workspace.Member = &.{},

    pub fn filesChanged(r: Report) usize {
        return r.added + r.changed + r.removed;
    }
};

pub const Error = error{
    ModelMismatch,
    SchemaMismatch,
    EmbeddingUnavailable,
    UpdateFailed,
} || Allocator.Error;

pub const Diag = struct {
    message: []const u8 = "",
};

pub fn indexPath(arena: Allocator, ws: workspace.Workspace) Allocator.Error![:0]const u8 {
    return std.fs.path.joinZ(arena, &.{ ws.root, workspace.data_dirname, index.db_basename });
}

pub fn run(arena: Allocator, gpa: Allocator, io: Io, ws: workspace.Workspace, opts: Options, diag: *Diag) Error!Report {
    return runInner(arena, gpa, io, ws, opts, diag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (diag.message.len == 0)
            diag.message = try std.fmt.allocPrint(arena, "update failed ({s}); the index is unchanged", .{@errorName(err)});
        return switch (err) {
            error.ModelMismatch, error.SchemaMismatch, error.EmbeddingUnavailable, error.UpdateFailed => |e| e,
            else => error.UpdateFailed,
        };
    };
}

fn runInner(arena: Allocator, gpa: Allocator, io: Io, ws: workspace.Workspace, opts: Options, diag: *Diag) !Report {
    const cwd = Io.Dir.cwd();
    const data_dir = try ws.dataDir(arena);
    try cwd.createDirPath(io, data_dir);
    const final_path = try indexPath(arena, ws);

    if (!opts.rebuild) return updateAt(arena, gpa, io, ws, opts, final_path, diag);

    // Build beside the old index, then swap it in; until the swap the old
    // index stays intact and usable.
    const tmp_path = try std.fmt.allocPrintSentinel(arena, "{s}.rebuild", .{final_path}, 0);
    deleteDbFiles(arena, io, tmp_path);
    defer deleteDbFiles(arena, io, tmp_path);
    const report = try updateAt(arena, gpa, io, ws, opts, tmp_path, diag);
    try swapIn(io, tmp_path, final_path);
    return report;
}

/// Make the rebuilt database at `built` the index at `live`. With no index
/// yet it is renamed into place. Otherwise its pages are copied into the
/// live file through SQLite: renaming over a WAL database that a reader has
/// open would pair the new file with the old `-wal`/`-shm` files.
fn swapIn(io: Io, built: [:0]const u8, live: [:0]const u8) !void {
    const cwd = Io.Dir.cwd();
    cwd.access(io, live, .{}) catch return cwd.rename(built, cwd, live, io);
    var src = try dbm.Db.open(built, .read_only);
    defer src.close();
    var dest = try dbm.Db.open(live, .read_write_create);
    defer dest.close();
    try dest.replaceWith(src);
}

/// The database file and its journal, WAL and shared-memory files.
fn deleteDbFiles(arena: Allocator, io: Io, path: []const u8) void {
    for ([_][]const u8{ "", "-journal", "-wal", "-shm" }) |suffix| {
        const p = std.fmt.allocPrint(arena, "{s}{s}", .{ path, suffix }) catch continue;
        Io.Dir.cwd().deleteFile(io, p) catch {};
    }
}

const Existing = struct {
    id: i64,
    hash: []const u8,
    size: i64,
    mtime_ns: i64,
    seen: bool = false,
};

fn updateAt(arena: Allocator, gpa: Allocator, io: Io, ws: workspace.Workspace, opts: Options, path: [:0]const u8, diag: *Diag) !Report {
    var report: Report = .{};

    var missing: std.ArrayList(workspace.Member) = .empty;
    for (ws.members) |m| if (m.status != .ok) try missing.append(arena, m);
    report.missing_members = missing.items;

    var idiag: index.Diag = .{};
    var ix = index.Index.open(arena, path, opts.model_url, &idiag) catch |err| switch (err) {
        error.ModelMismatch, error.SchemaMismatch => |e| {
            diag.message = idiag.message;
            return e;
        },
        else => |e| return e,
    };
    defer ix.close();
    const db = ix.db;

    // What the index holds now.
    var existing: std.StringHashMapUnmanaged(Existing) = .empty;
    {
        var s = try db.prepare("SELECT id, path, hash, size, mtime_ns FROM files");
        defer s.finalize();
        while (try s.step()) {
            try existing.put(arena, try arena.dupe(u8, s.text(1)), .{
                .id = s.int(0),
                .hash = try arena.dupe(u8, s.text(2)),
                .size = s.int(3),
                .mtime_ns = s.int(4),
            });
        }
    }

    // Snapshot every source before the (slow) embedding starts, so a live
    // workspace has only a short window to change under us.
    const snapshot = try takeSnapshot(arena, io, try sources.discover(arena, io, ws), diag);

    var w: Writer = try .init(arena, gpa, db, &ix, opts.provider, diag);
    defer w.deinit();

    // Chunk what needs (re)indexing and count the passages that will need an
    // embedding, so progress can show a total.
    {
        var counted: std.StringHashMapUnmanaged(void) = .empty;
        for (snapshot) |*snap| {
            if (existing.get(snap.src.path)) |old| if (std.mem.eql(u8, old.hash, &snap.hash)) continue;
            snap.chunked = try chunk.passages(arena, snap.src, snap.text);
            for (snap.chunked.?.passages) |p| {
                const h = try arena.dupe(u8, &hashHex(p));
                if ((try counted.getOrPut(arena, h)).found_existing) continue;
                if (!try w.isIndexed(h)) w.to_embed += 1;
            }
        }
        w.progress = opts.progress;
        if (w.progress) |out| if (w.to_embed > 0) {
            out.print("devlog-index: {d} passages to embed\n", .{w.to_embed}) catch {};
            out.flush() catch {};
        };
    }

    try db.exec("BEGIN IMMEDIATE");
    errdefer db.exec("ROLLBACK") catch {};

    const now_s: i64 = @intCast(@divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    var stale_passages: std.ArrayList(i64) = .empty;

    for (snapshot) |snap| {
        const src = snap.src;
        const hash = snap.hash;
        const size = snap.size;
        const mtime_ns = snap.mtime_ns;

        if (existing.getPtr(src.path)) |old| {
            old.seen = true;
            if (std.mem.eql(u8, old.hash, &hash)) {
                report.unchanged += 1;
                if (old.size != size or old.mtime_ns != mtime_ns) try w.touchFile(old.id, size, mtime_ns);
                continue;
            }
            report.changed += 1;
            try w.collectPassages(old.id, &stale_passages);
            try w.updateFile(old.id, &hash, size, mtime_ns, now_s);
            try w.insertPassages(old.id, snap.chunked.?, &report);
        } else {
            report.added += 1;
            const id = try w.insertFile(src, &hash, size, mtime_ns, now_s);
            try w.insertPassages(id, snap.chunked.?, &report);
        }
    }

    // Removed files: not found this time, and not under a member that is
    // missing right now.
    var it = existing.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.seen) continue;
        if (freshness.underMissingMember(entry.key_ptr.*, missing.items)) continue;
        report.removed += 1;
        try w.collectPassages(entry.value_ptr.id, &stale_passages);
        try w.deleteFile(entry.value_ptr.id);
    }

    // Old passages go last, so new ones could reuse their vectors.
    for (stale_passages.items) |id| try w.deletePassage(id);

    try ix.putSetting("last_update", try std.fmt.allocPrint(arena, "{d}", .{now_s}));
    try db.exec("COMMIT");

    report.passages_total = @intCast((try db.oneInt("SELECT count(*) FROM passages")).?);
    return report;
}

const Snap = struct {
    src: sources.Source,
    text: []const u8,
    hash: [64]u8,
    size: i64,
    mtime_ns: i64,
    /// Set for files that need (re)indexing.
    chunked: ?chunk.Chunked = null,
};

/// Stat, read and hash every source. A file that vanished since discovery
/// is left out, as if it had not been found (so an indexed copy is removed).
/// The stat comes before the read: if the file changes in between, the
/// recorded mtime is older than the content, so the next freshness check
/// re-hashes it rather than missing the change.
fn takeSnapshot(arena: Allocator, io: Io, srcs: []const sources.Source, diag: *Diag) ![]Snap {
    const cwd = Io.Dir.cwd();
    var out: std.ArrayList(Snap) = .empty;
    for (srcs) |src| {
        const st = cwd.statFile(io, src.path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return readFailed(arena, diag, src.path, err),
        };
        const text = cwd.readFileAlloc(io, src.path, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            error.OutOfMemory => return error.OutOfMemory,
            else => return readFailed(arena, diag, src.path, err),
        };
        try out.append(arena, .{
            .src = src,
            .text = text,
            .hash = hashHex(text),
            .size = @intCast(st.size),
            .mtime_ns = @intCast(st.mtime.nanoseconds),
        });
    }
    return out.items;
}

fn readFailed(arena: Allocator, diag: *Diag, path: []const u8, err: anyerror) Error {
    diag.message = try std.fmt.allocPrint(arena, "cannot read {s} ({s}); the index is unchanged", .{ path, @errorName(err) });
    return error.UpdateFailed;
}

pub fn hashHex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn noteTimeText(arena: Allocator, src: sources.Source) Allocator.Error!?[]const u8 {
    if (src.class.artifact != .note) return null;
    const t = chunk.noteMeta(std.fs.path.basename(src.path)).time orelse return null;
    return try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ t.year, t.month, t.day, t.hour, t.minute });
}

/// The update's prepared statements and the lazily obtained embedder.
const Writer = struct {
    arena: Allocator,
    gpa: Allocator,
    db: dbm.Db,
    ix: *index.Index,
    provider: Provider,
    diag: *Diag,
    embedder: ?Embedder = null,
    progress: ?*Io.Writer = null,
    /// Passages expected to need an embedding this run.
    to_embed: usize = 0,

    insert_file: dbm.Stmt,
    update_file: dbm.Stmt,
    touch_file: dbm.Stmt,
    delete_file: dbm.Stmt,
    file_passages: dbm.Stmt,
    insert_passage: dbm.Stmt,
    insert_fts: dbm.Stmt,
    find_by_hash: dbm.Stmt,
    delete_passage: dbm.Stmt,
    delete_fts: dbm.Stmt,
    // Prepared once the vector table exists.
    insert_vec: ?dbm.Stmt = null,
    get_vec: ?dbm.Stmt = null,
    delete_vec: ?dbm.Stmt = null,

    fn init(arena: Allocator, gpa: Allocator, db: dbm.Db, ix: *index.Index, provider: Provider, diag: *Diag) !Writer {
        var w: Writer = .{
            .arena = arena,
            .gpa = gpa,
            .db = db,
            .ix = ix,
            .provider = provider,
            .diag = diag,
            .insert_file = try db.prepare(
                \\INSERT INTO files(path, member, rel, hash, size, mtime_ns, kind, change, archived, capability, note_time, indexed_at)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            ),
            .update_file = try db.prepare("UPDATE files SET hash = ?2, size = ?3, mtime_ns = ?4, indexed_at = ?5 WHERE id = ?1"),
            .touch_file = try db.prepare("UPDATE files SET size = ?2, mtime_ns = ?3 WHERE id = ?1"),
            .delete_file = try db.prepare("DELETE FROM files WHERE id = ?"),
            .file_passages = try db.prepare("SELECT id FROM passages WHERE file_id = ?"),
            .insert_passage = try db.prepare("INSERT INTO passages(file_id, ordinal, title, text, text_hash) VALUES (?, ?, ?, ?, ?)"),
            .insert_fts = try db.prepare("INSERT INTO passages_fts(rowid, text) VALUES (?, ?)"),
            .find_by_hash = try db.prepare("SELECT id FROM passages WHERE text_hash = ? LIMIT 1"),
            .delete_passage = try db.prepare("DELETE FROM passages WHERE id = ?"),
            .delete_fts = try db.prepare("DELETE FROM passages_fts WHERE rowid = ?"),
        };
        if (ix.dim != null) try w.prepareVec();
        return w;
    }

    fn prepareVec(w: *Writer) !void {
        w.insert_vec = try w.db.prepare("INSERT INTO passages_vec(rowid, embedding) VALUES (?, ?)");
        w.get_vec = try w.db.prepare("SELECT embedding FROM passages_vec WHERE rowid = ?");
        w.delete_vec = try w.db.prepare("DELETE FROM passages_vec WHERE rowid = ?");
    }

    fn deinit(w: *Writer) void {
        inline for (.{ "insert_file", "update_file", "touch_file", "delete_file", "file_passages", "insert_passage", "insert_fts", "find_by_hash", "delete_passage", "delete_fts" }) |f|
            @field(w, f).finalize();
        inline for (.{ "insert_vec", "get_vec", "delete_vec" }) |f| {
            if (@field(w, f)) |*s| s.finalize();
        }
    }

    fn insertFile(w: *Writer, src: sources.Source, hash: []const u8, size: i64, mtime_ns: i64, now_s: i64) !i64 {
        const s = w.insert_file;
        try s.bindText(1, src.path);
        try s.bindText(2, src.member);
        try s.bindText(3, src.rel);
        try s.bindText(4, hash);
        try s.bindInt(5, size);
        try s.bindInt(6, mtime_ns);
        try s.bindText(7, chunk.kind(src));
        try s.bindOptText(8, src.class.change);
        try s.bindInt(9, @intFromBool(src.class.archived));
        try s.bindOptText(10, src.class.capability);
        try s.bindOptText(11, try noteTimeText(w.arena, src));
        try s.bindInt(12, now_s);
        try s.run();
        return w.db.lastInsertRowId();
    }

    /// Same path, so the class-derived columns are unchanged.
    fn updateFile(w: *Writer, id: i64, hash: []const u8, size: i64, mtime_ns: i64, now_s: i64) !void {
        const s = w.update_file;
        try s.bindInt(1, id);
        try s.bindText(2, hash);
        try s.bindInt(3, size);
        try s.bindInt(4, mtime_ns);
        try s.bindInt(5, now_s);
        try s.run();
    }

    fn touchFile(w: *Writer, id: i64, size: i64, mtime_ns: i64) !void {
        const s = w.touch_file;
        try s.bindInt(1, id);
        try s.bindInt(2, size);
        try s.bindInt(3, mtime_ns);
        try s.run();
    }

    fn deleteFile(w: *Writer, id: i64) !void {
        try w.delete_file.bindInt(1, id);
        try w.delete_file.run();
    }

    fn collectPassages(w: *Writer, file_id: i64, out: *std.ArrayList(i64)) !void {
        const s = w.file_passages;
        defer s.reset();
        try s.bindInt(1, file_id);
        while (try s.step()) try out.append(w.arena, s.int(0));
    }

    fn insertPassages(w: *Writer, file_id: i64, chunked: chunk.Chunked, report: *Report) !void {
        for (chunked.passages, 0..) |p, ordinal| {
            const text_hash = hashHex(p);
            const vec_bytes = try w.vectorFor(p, &text_hash, report);
            defer w.gpa.free(vec_bytes);

            const s = w.insert_passage;
            try s.bindInt(1, file_id);
            try s.bindInt(2, @intCast(ordinal));
            try s.bindOptText(3, chunked.title);
            try s.bindText(4, p);
            try s.bindText(5, &text_hash);
            try s.run();
            const id = w.db.lastInsertRowId();

            try w.insert_fts.bindInt(1, id);
            try w.insert_fts.bindText(2, p);
            try w.insert_fts.run();

            const iv = w.insert_vec.?;
            try iv.bindInt(1, id);
            try iv.bindBlob(2, vec_bytes);
            try iv.run();
        }
    }

    /// The vector bytes for passage text `p`: copied from an indexed passage
    /// with the same text, or freshly embedded. Caller frees with `gpa`.
    fn vectorFor(w: *Writer, p: []const u8, text_hash: []const u8, report: *Report) ![]u8 {
        if (w.get_vec) |gv| {
            const f = w.find_by_hash;
            defer f.reset();
            try f.bindText(1, text_hash);
            if (try f.step()) {
                defer gv.reset();
                try gv.bindInt(1, f.int(0));
                if (try gv.step()) {
                    report.passages_reused += 1;
                    return w.gpa.dupe(u8, gv.blob(0));
                }
            }
        }
        const e = try w.getEmbedder();
        const v = e.embed(w.gpa, p) catch |err| {
            w.diag.message = try std.fmt.allocPrint(w.arena, "embedding failed ({s}); the index is unchanged", .{@errorName(err)});
            return error.EmbeddingUnavailable;
        };
        defer w.gpa.free(v);
        report.passages_embedded += 1;
        w.reportProgress(report.passages_embedded);
        if (v.len != e.dim) {
            w.diag.message = try std.fmt.allocPrint(w.arena, "the model returned a {d}-d vector where {d}-d was expected; the index is unchanged", .{ v.len, e.dim });
            return error.UpdateFailed;
        }
        return w.gpa.dupe(u8, std.mem.sliceAsBytes(v));
    }

    /// Whether a passage with this text hash already has a vector to reuse.
    fn isIndexed(w: *Writer, text_hash: []const u8) !bool {
        if (w.get_vec == null) return false;
        const f = w.find_by_hash;
        defer f.reset();
        try f.bindText(1, text_hash);
        return f.step();
    }

    fn reportProgress(w: *Writer, embedded: usize) void {
        const out = w.progress orelse return;
        if (embedded % progress_every != 0 and embedded != w.to_embed) return;
        out.print("devlog-index: embedded {d}/{d} passages\n", .{ embedded, w.to_embed }) catch {};
        out.flush() catch {};
    }

    fn getEmbedder(w: *Writer) !Embedder {
        if (w.embedder) |e| return e;
        const e = w.provider.getFn(w.provider.ptr) catch |err| {
            if (w.diag.message.len == 0)
                w.diag.message = try std.fmt.allocPrint(w.arena, "cannot load the embedding model ({s}); the index is unchanged", .{@errorName(err)});
            return error.EmbeddingUnavailable;
        };
        var idiag: index.Diag = .{};
        w.ix.ensureVec(w.arena, e.dim, &idiag) catch |err| switch (err) {
            error.ModelMismatch => {
                w.diag.message = idiag.message;
                return error.ModelMismatch;
            },
            else => |x| return x,
        };
        if (w.insert_vec == null) try w.prepareVec();
        w.embedder = e;
        return e;
    }

    fn deletePassage(w: *Writer, id: i64) !void {
        if (w.delete_vec) |dv| {
            try dv.bindInt(1, id);
            try dv.run();
        }
        try w.delete_fts.bindInt(1, id);
        try w.delete_fts.run();
        try w.delete_passage.bindInt(1, id);
        try w.delete_passage.run();
    }
};

/// The real embedder: the pinned GGUF model, downloaded on first need into
/// the per-user cache (or a given file, for tests).
pub const ModelProvider = struct {
    gpa: Allocator,
    io: Io,
    /// The GGUF file to load.
    model_path: [:0]const u8,
    /// Download from here when `model_path` is absent; null to never download.
    download_url: ?[]const u8,
    /// `.document` for indexing, `.query` for a query (design D2 prefixes).
    task: embed_mod.Task = .document,
    model: ?model_mod.Model = null,
    embedder: ?embed_mod.Embedder = null,

    /// The cached pinned model under `$HOME/.devlog-index/models/`.
    pub fn pinned(arena: Allocator, gpa: Allocator, io: Io, home: []const u8) !ModelProvider {
        const parsed = try model_url.parse(model_url.pinned_url);
        return .{
            .gpa = gpa,
            .io = io,
            .model_path = try model_url.cachePathZ(arena, home, parsed),
            .download_url = model_url.pinned_url,
        };
    }

    /// The cached pinned model, for a query: never downloads (that would
    /// break the query latency budget); `get` fails with `ModelNotCached`.
    pub fn cachedForQuery(arena: Allocator, gpa: Allocator, io: Io, home: []const u8) !ModelProvider {
        var mp = try pinned(arena, gpa, io, home);
        mp.download_url = null;
        mp.task = .query;
        return mp;
    }

    pub fn provider(mp: *ModelProvider) Provider {
        return .{ .ptr = mp, .getFn = get };
    }

    fn get(ptr: *anyopaque) anyerror!Embedder {
        const mp: *ModelProvider = @ptrCast(@alignCast(ptr));
        // Loaded once: query and eval ask for the embedder on every query.
        if (mp.embedder) |e| return .{ .ptr = mp, .dim = e.dim, .embedFn = embedText };
        if (mp.download_url) |url|
            _ = try download.ensureCached(mp.gpa, mp.io, mp.model_path, url)
        else
            Io.Dir.cwd().access(mp.io, mp.model_path, .{}) catch return error.ModelNotCached;
        model_mod.initBackend();
        errdefer model_mod.deinitBackend();
        mp.model = try model_mod.Model.loadFromFile(mp.model_path, .{ .quiet = true });
        errdefer {
            mp.model.?.deinit();
            mp.model = null;
        }
        mp.embedder = try embed_mod.Embedder.init(mp.model.?, true);
        return .{ .ptr = mp, .dim = mp.embedder.?.dim, .embedFn = embedText };
    }

    fn embedText(ptr: *anyopaque, gpa: Allocator, text: []const u8) anyerror![]f32 {
        const mp: *ModelProvider = @ptrCast(@alignCast(ptr));
        return mp.embedder.?.embed(gpa, mp.task, text);
    }

    pub fn deinit(mp: *ModelProvider) void {
        if (mp.embedder) |*e| e.deinit();
        if (mp.model) |*m| {
            m.deinit();
            model_mod.deinitBackend();
        }
        mp.* = undefined;
    }
};

// ---- tests ----

const testing = std.testing;
const Stub = @import("testutil.zig").Stub;
const Fixture = @import("testutil.zig").Fixture;

const new_note =
    \\# Decision: token audience
    \\
    \\Tokens are requested with the API audience only, never a wildcard, so a leaked token is useless elsewhere.
    \\
;

test "update: first run indexes the fixture; nothing changed computes no embeddings" {
    var f = try Fixture.init();
    defer f.deinit();
    var stub: Stub = .{};

    const first = try f.update("", &stub, false);
    try testing.expectEqual(@as(usize, 19), first.added);
    try testing.expectEqual(@as(usize, 0), first.changed + first.removed + first.unchanged);
    try testing.expect(first.passages_total > 19);
    try testing.expectEqual(first.passages_total, first.passages_embedded + first.passages_reused);
    try testing.expectEqual(@as(usize, 1), stub.loads);

    // Every passage has its FTS row and its vector.
    const n: i64 = @intCast(first.passages_total);
    try testing.expectEqual(n, try f.count("SELECT count(*) FROM passages_fts"));
    try testing.expectEqual(n, try f.count("SELECT count(*) FROM passages_vec"));
    try testing.expectEqual(@as(i64, 0), try f.count("SELECT count(*) FROM passages WHERE text LIKE '%-MARKER%' AND text NOT LIKE '%ACTIVE-DELTA-MARKER%'"));
    try testing.expectEqual(@as(i64, 1), try f.count(
        \\SELECT count(*) FROM files WHERE member = 'alpha' AND change = 'add-retry' AND archived = 1
        \\  AND kind = 'stopped' AND note_time = '2026-03-12 09:15'
    ));

    const loads = stub.loads;
    const embeds = stub.embeds;
    const second = try f.update("", &stub, false);
    try testing.expectEqual(@as(usize, 0), second.filesChanged());
    try testing.expectEqual(@as(usize, 19), second.unchanged);
    try testing.expectEqual(@as(usize, 0), second.passages_embedded);
    try testing.expectEqual(embeds, stub.embeds);
    try testing.expectEqual(loads, stub.loads); // the model is not even loaded
}

test "update: one new note in one member, run from another member" {
    var f = try Fixture.init();
    defer f.deinit();
    var stub: Stub = .{};
    const before = try f.update("", &stub, false);

    try f.write("alpha/openspec/changes/add-cache/devlog/20260402-0900-decision-token-audience.md", new_note);
    const r = try f.update("beta/openspec", &stub, false);
    try testing.expectEqual(@as(usize, 1), r.added);
    try testing.expectEqual(@as(usize, 0), r.changed + r.removed);
    try testing.expectEqual(@as(usize, 1), r.passages_embedded);
    try testing.expectEqual(before.passages_total + 1, r.passages_total);
    try testing.expectEqual(@as(i64, 1), try f.count("SELECT count(*) FROM passages p JOIN files f ON f.id = p.file_id WHERE f.rel LIKE '%token-audience%'"));
}

test "update: a changed file is re-chunked, reusing vectors of unchanged passages" {
    var f = try Fixture.init();
    defer f.deinit();
    var stub: Stub = .{};
    _ = try f.update("", &stub, false);

    const rel = "alpha/openspec/changes/archive/2026-03-10-add-retry/design.md";
    const old = try f.tmp.dir.readFileAlloc(testing.io, rel, f.arena(), .unlimited);
    try f.write(rel, try std.fmt.allocPrint(f.arena(), "{s}\n## Rollout\n\nBehind a flag for a week.\n", .{old}));
    const r = try f.update("", &stub, false);
    try testing.expectEqual(@as(usize, 1), r.changed);
    try testing.expectEqual(@as(usize, 1), r.passages_embedded); // only the new section
    try testing.expectEqual(@as(usize, 3), r.passages_reused);
    try testing.expectEqual(@as(i64, 4), try f.count("SELECT count(*) FROM passages p JOIN files f ON f.id = p.file_id WHERE f.rel LIKE '%add-retry/design.md'"));
    try testing.expectEqual(try f.count("SELECT count(*) FROM passages"), try f.count("SELECT count(*) FROM passages_vec"));
    try testing.expectEqual(try f.count("SELECT count(*) FROM passages"), try f.count("SELECT count(*) FROM passages_fts"));
}

test "update: archiving a change marks its passages archived and drops its spec delta" {
    var f = try Fixture.init();
    defer f.deinit();
    var stub: Stub = .{};
    _ = try f.update("", &stub, false);
    const marker = "SELECT count(*) FROM passages_fts WHERE passages_fts MATCH '\"ACTIVE-DELTA-MARKER\"'";
    try testing.expectEqual(@as(i64, 1), try f.count(marker));

    try f.tmp.dir.rename("alpha/openspec/changes/add-cache", f.tmp.dir, "alpha/openspec/changes/archive/2026-04-02-add-cache", testing.io);
    const r = try f.update("", &stub, false);
    try testing.expectEqual(@as(usize, 3), r.added); // proposal, tasks, note at their new paths
    try testing.expectEqual(@as(usize, 4), r.removed); // ... and the delta, now archived
    try testing.expectEqual(@as(usize, 0), r.passages_embedded); // same text: vectors reused
    try testing.expectEqual(@as(i64, 0), try f.count("SELECT count(*) FROM files WHERE change = 'add-cache' AND archived = 0"));
    try testing.expectEqual(@as(i64, 3), try f.count("SELECT count(*) FROM files WHERE change = 'add-cache' AND archived = 1"));
    try testing.expectEqual(@as(i64, 0), try f.count(marker));
}

test "update: a deleted file's passages are gone from every table" {
    var f = try Fixture.init();
    defer f.deinit();
    var stub: Stub = .{};
    const before = try f.update("", &stub, false);

    try f.tmp.dir.deleteFile(testing.io, "alpha/openspec/changes/archive/2026-03-10-add-retry/devlog/20260310-1015-decision-retry-policy.md");
    const r = try f.update("", &stub, false);
    try testing.expectEqual(@as(usize, 1), r.removed);
    try testing.expect(r.passages_total < before.passages_total);
    try testing.expectEqual(@as(i64, 0), try f.count("SELECT count(*) FROM files WHERE rel LIKE '%retry-policy%'"));
    try testing.expectEqual(@as(i64, 0), try f.count("SELECT count(*) FROM passages_fts WHERE passages_fts MATCH 'thundering'"));
    const n: i64 = @intCast(r.passages_total);
    try testing.expectEqual(n, try f.count("SELECT count(*) FROM passages_vec"));
}

test "update: a missing member is reported and its passages kept" {
    var f = try Fixture.init();
    defer f.deinit();
    var stub: Stub = .{};
    const before = try f.update("", &stub, false);

    try f.tmp.dir.rename("beta", f.tmp.dir, "beta-moved", testing.io);
    const r = try f.update("alpha", &stub, false);
    try testing.expectEqual(@as(usize, 1), r.missing_members.len);
    try testing.expectEqualStrings("beta", r.missing_members[0].declared);
    try testing.expectEqual(@as(usize, 0), r.removed);
    try testing.expectEqual(before.passages_total, r.passages_total);
}

test "update: the model failing to load leaves the index unchanged" {
    var f = try Fixture.init();
    defer f.deinit();
    var stub: Stub = .{};
    const before = try f.update("", &stub, false);

    try f.write("alpha/openspec/changes/add-cache/devlog/20260402-0900-decision-token-audience.md", new_note);
    try f.tmp.dir.deleteFile(testing.io, "beta/openspec/specs/api/spec.md");
    var broken: Stub = .{ .fail_load = true };
    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, f.root, &wdiag);
    var diag: Diag = .{};
    try testing.expectError(error.EmbeddingUnavailable, run(f.arena(), testing.allocator, testing.io, ws, .{ .provider = broken.provider(), .model_url = "test://stub" }, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "index is unchanged") != null);

    // Neither the deletion nor anything else was applied.
    try testing.expectEqual(@as(i64, @intCast(before.passages_total)), try f.count("SELECT count(*) FROM passages"));
    try testing.expectEqual(@as(i64, 19), try f.count("SELECT count(*) FROM files"));
}

test "update: interrupted mid-embedding leaves the previous index usable" {
    var f = try Fixture.init();
    defer f.deinit();
    var stub: Stub = .{};
    const before = try f.update("", &stub, false);

    try f.write("alpha/openspec/changes/add-cache/devlog/20260402-0900-decision-token-audience.md", new_note);
    try f.write("beta/openspec/changes/archive/2026-03-20-init-api/devlog/20260321-0900-note-followup.md", "# Follow-up\n\nAnother new note.\n");
    var flaky: Stub = .{ .fail_after = 1 }; // the first new note embeds, the second fails
    try testing.expectError(error.EmbeddingUnavailable, f.update("", &flaky, false));
    try testing.expectEqual(@as(i64, @intCast(before.passages_total)), try f.count("SELECT count(*) FROM passages"));
    try testing.expectEqual(@as(i64, 0), try f.count("SELECT count(*) FROM files WHERE rel LIKE '%token-audience%'"));

    const r = try f.update("", &stub, false);
    try testing.expectEqual(@as(usize, 2), r.added);
}

test "update: model mismatch is refused; --rebuild replaces the index" {
    var f = try Fixture.init();
    defer f.deinit();
    var stub: Stub = .{};
    const first = try f.update("", &stub, false);

    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, f.root, &wdiag);
    var diag: Diag = .{};
    try testing.expectError(error.ModelMismatch, run(f.arena(), testing.allocator, testing.io, ws, .{ .provider = stub.provider(), .model_url = "test://other" }, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "test://stub") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "test://other") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, index.rebuild_command) != null);

    // A reader holding the index open across the rebuild sees the new index.
    var reader = try f.db();
    defer reader.close();
    try testing.expectEqual(@as(?i64, 1), try reader.oneInt("SELECT count(*) FROM settings WHERE value = 'test://stub'"));

    diag = .{};
    const rebuilt = try run(f.arena(), testing.allocator, testing.io, ws, .{ .provider = stub.provider(), .model_url = "test://other", .rebuild = true }, &diag);
    try testing.expectEqual(@as(usize, 19), rebuilt.added);
    try testing.expectEqual(first.passages_total, rebuilt.passages_total);
    try testing.expectEqual(first.passages_total, rebuilt.passages_embedded + rebuilt.passages_reused);
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(testing.io, ".devlog-index/index.db.rebuild", .{}));
    try testing.expectEqual(@as(?i64, 1), try reader.oneInt("SELECT count(*) FROM settings WHERE value = 'test://other'"));
    try testing.expectEqual(first.passages_total, @as(usize, @intCast((try reader.oneInt("SELECT count(*) FROM passages_vec")).?)));

    // The rebuilt index is pinned to the new model.
    diag = .{};
    const again = try run(f.arena(), testing.allocator, testing.io, ws, .{ .provider = stub.provider(), .model_url = "test://other" }, &diag);
    try testing.expectEqual(@as(usize, 0), again.filesChanged());
}

test "update with the real model (DEVLOG_INDEX_TEST_MODEL)" {
    const env = std.c.getenv("DEVLOG_INDEX_TEST_MODEL") orelse return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var mp: ModelProvider = .{ .gpa = testing.allocator, .io = testing.io, .model_path = std.mem.span(env), .download_url = null };
    defer mp.deinit();

    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, f.root, &wdiag);
    var diag: Diag = .{};
    const r = try run(f.arena(), testing.allocator, testing.io, ws, .{ .provider = mp.provider() }, &diag);
    try testing.expectEqual(@as(usize, 19), r.added);
    try testing.expectEqual(@as(i64, @intCast(r.passages_total)), try f.count("SELECT count(*) FROM passages_vec"));
    var d = try f.db();
    defer d.close();
    try testing.expectEqual(@as(?i64, 768), try d.oneInt("SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'dim'"));
}

test "snapshot: a file that vanished since discovery is left out, so its indexed copy is removed" {
    var f = try Fixture.init();
    defer f.deinit();
    var stub: Stub = .{};
    _ = try f.update("", &stub, false);

    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, f.root, &wdiag);
    const srcs = try sources.discover(f.arena(), testing.io, ws);
    // Delete one discovered file before the snapshot reads it.
    try Io.Dir.cwd().deleteFile(testing.io, srcs[0].path);
    var diag: Diag = .{};
    const snap = try takeSnapshot(f.arena(), testing.io, srcs, &diag);
    try testing.expectEqual(srcs.len - 1, snap.len);
    for (snap) |s| try testing.expect(!std.mem.eql(u8, s.src.path, srcs[0].path));

    const r = try f.update("", &stub, false);
    try testing.expectEqual(@as(usize, 1), r.removed);
}

test "update: progress counts the passages to embed, excluding reusable ones" {
    var f = try Fixture.init();
    defer f.deinit();
    var stub: Stub = .{};
    var progress: Io.Writer.Allocating = .init(f.arena());

    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, f.root, &wdiag);
    var diag: Diag = .{};
    const first = try run(f.arena(), testing.allocator, testing.io, ws, .{ .provider = stub.provider(), .model_url = "test://stub", .progress = &progress.writer }, &diag);
    const want_first = try std.fmt.allocPrint(f.arena(), "devlog-index: {d} passages to embed\n", .{first.passages_embedded});
    try testing.expect(std.mem.startsWith(u8, progress.written(), want_first));
    const done = try std.fmt.allocPrint(f.arena(), "embedded {d}/{d} passages\n", .{ first.passages_embedded, first.passages_embedded });
    try testing.expect(std.mem.endsWith(u8, progress.written(), done));

    // Archiving: everything reusable, so nothing to embed and no progress.
    progress.clearRetainingCapacity();
    try f.tmp.dir.rename("alpha/openspec/changes/add-cache", f.tmp.dir, "alpha/openspec/changes/archive/2026-04-02-add-cache", testing.io);
    _ = try run(f.arena(), testing.allocator, testing.io, ws, .{ .provider = stub.provider(), .model_url = "test://stub", .progress = &progress.writer }, &diag);
    try testing.expectEqualStrings("", progress.written());
}

test "ModelProvider loads the model once however often it is asked (DEVLOG_INDEX_TEST_MODEL)" {
    const env = std.c.getenv("DEVLOG_INDEX_TEST_MODEL") orelse return error.SkipZigTest;
    var mp: ModelProvider = .{ .gpa = testing.allocator, .io = testing.io, .model_path = std.mem.span(env), .download_url = null, .task = .query };
    defer mp.deinit();
    const p = mp.provider();
    const first = try p.getFn(p.ptr);
    const handle = mp.model.?.handle;
    for (0..3) |_| {
        const again = try p.getFn(p.ptr);
        try testing.expectEqual(first.dim, again.dim);
        try testing.expectEqual(handle, mp.model.?.handle);
    }
}

test "update: a vector of the wrong length is refused with a message, the index unchanged" {
    var f = try Fixture.init();
    defer f.deinit();
    var short: Stub = .{ .short_vectors = true };
    var wdiag: workspace.Diag = .{};
    const ws = try workspace.resolve(f.arena(), testing.io, f.root, &wdiag);
    var diag: Diag = .{};
    try testing.expectError(error.UpdateFailed, run(f.arena(), testing.allocator, testing.io, ws, .{ .provider = short.provider(), .model_url = "test://stub" }, &diag));
    try testing.expectEqualStrings("the model returned a 7-d vector where 8-d was expected; the index is unchanged", diag.message);
}
