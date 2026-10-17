//! Single-text embedding over a loaded llama.cpp model.
//!
//! Provenance: adapted from memlite `src/embed.zig` at 749b246
//! (daemonicai/memlite): nomic task prefixes and title-first truncation
//! added (design D2), test env var renamed, threads set to the performance-core
//! count (llama.cpp defaults to 4). Holds an embedding-mode `llama_context` (pooling = MEAN,
//! embeddings = true) tied to the Model from §6. `embed(text)` tokenizes,
//! runs a single forward pass, pulls the pooled sequence embedding, and
//! L2-normalizes it for cosine retrieval.

const std = @import("std");
const c = @import("llama_c");
const model_mod = @import("model.zig");

const Allocator = std.mem.Allocator;

/// Threads for embedding: the performance cores on Apple silicon (mixing in
/// efficiency cores slows each step to their pace), else every logical CPU.
pub fn embedThreads() i32 {
    if (@import("builtin").os.tag == .macos) {
        var n: c_int = 0;
        var len: usize = @sizeOf(c_int);
        if (std.c.sysctlbyname("hw.perflevel0.physicalcpu", &n, &len, null, 0) == 0 and n > 0) return n;
    }
    const n = std.Thread.getCpuCount() catch return 4;
    return @intCast(@max(1, @min(n, 64)));
}

pub const Error = error{
    ContextInitFailed,
    TokenizeFailed,
    DecodeFailed,
    EmbeddingsUnavailable,
} || Allocator.Error;

/// nomic-embed-text is trained with a task prefix on every input: passages
/// as `search_document:`, questions as `search_query:` (design D2).
pub const Task = enum {
    document,
    query,

    pub fn prefix(self: Task) []const u8 {
        return switch (self) {
            .document => "search_document: ",
            .query => "search_query: ",
        };
    }
};

/// The model input for `text`: its task prefix, then the text. Passages
/// already begin with their title (design D7), so the title directly follows
/// the prefix and is the last thing truncation would remove. Caller owns.
pub fn prefixed(gpa: Allocator, task: Task, text: []const u8) Allocator.Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ task.prefix(), text });
}

/// Fit a token sequence into `max` tokens by dropping from the end of the
/// text, so the prefix and title at the start survive. The final token (the
/// tokenizer's end marker, e.g. BERT's [SEP]) is kept as the last token.
/// Returns a prefix-slice of `tokens`; mutates `tokens[max - 1]`.
pub fn fitTokens(comptime T: type, tokens: []T, max: usize) []T {
    std.debug.assert(max >= 2);
    if (tokens.len <= max) return tokens;
    tokens[max - 1] = tokens[tokens.len - 1];
    return tokens[0..max];
}

pub const Embedder = struct {
    ctx: *c.llama_context,
    vocab: *const c.llama_vocab,
    dim: u32,
    n_ctx: u32,
    /// A context without KV memory (embedding models such as nomic-bert)
    /// runs through `llama_encode`; `llama_decode` would reroute there anyway.
    encoder: bool,
    quiet: bool,

    /// Open an embedding-mode context over `model`. The Model must outlive
    /// the Embedder. CPU-only — params.n_gpu_layers stays at the default 0.
    ///
    /// When `quiet` is true, stderr is redirected to /dev/null for the
    /// duration of `llama_init_from_model` to suppress the verbose
    /// context-construction diagnostics (graceful fallback).
    pub fn init(model: model_mod.Model, quiet: bool) Error!Embedder {
        var params = c.llama_context_default_params();
        params.embeddings = true;
        params.pooling_type = c.LLAMA_POOLING_TYPE_MEAN;
        params.no_perf = true;
        const threads = embedThreads();
        params.n_threads = threads;
        params.n_threads_batch = threads;

        const n_ctx_train = model.trainedCtxLen();
        const n_ctx: u32 = if (n_ctx_train > 0) n_ctx_train else 2048;
        params.n_ctx = n_ctx;
        // Single-shot embedding: process the whole input as one batch.
        params.n_batch = n_ctx;
        params.n_ubatch = n_ctx;

        // Suppress context-creation stderr chatter when quiet.
        const silenced = model_mod.Quiet.begin(quiet);
        defer silenced.restore();

        const ctx = c.llama_init_from_model(model.handle, params);
        if (ctx == null) return Error.ContextInitFailed;

        const vocab_ptr = c.llama_model_get_vocab(model.handle);
        std.debug.assert(vocab_ptr != null);

        return .{
            .ctx = ctx.?,
            .vocab = vocab_ptr.?,
            .dim = model.embeddingDim(),
            .n_ctx = n_ctx,
            .encoder = c.llama_get_memory(ctx.?) == null,
            .quiet = quiet,
        };
    }

    pub fn deinit(self: *Embedder) void {
        // llama_free reports its compute buffer size on stderr.
        const silenced = model_mod.Quiet.begin(self.quiet);
        defer silenced.restore();
        c.llama_free(self.ctx);
        self.* = undefined;
    }

    /// Embed `text` for `task` (prefixed, and truncated from the end to the
    /// model's context) into a freshly allocated, L2-normalized `[]f32` of
    /// length `self.dim`. Caller owns the returned slice.
    pub fn embed(self: *Embedder, gpa: Allocator, task: Task, text: []const u8) Error![]f32 {
        const input = try prefixed(gpa, task, text);
        defer gpa.free(input);

        // Two-call tokenize: probe required length, then fill. Special-token
        // parsing is off: passage text is data, and a literal "[SEP]" in a
        // note must not become a control token.
        const need = -c.llama_tokenize(
            self.vocab,
            input.ptr,
            @intCast(input.len),
            null,
            0,
            true, // add_special: BERT [CLS]/[SEP]
            false, // parse_special
        );
        if (need <= 0) return Error.TokenizeFailed;

        const all_tokens = try gpa.alloc(c.llama_token, @intCast(need));
        defer gpa.free(all_tokens);

        const got = c.llama_tokenize(
            self.vocab,
            input.ptr,
            @intCast(input.len),
            all_tokens.ptr,
            @intCast(all_tokens.len),
            true,
            false,
        );
        if (got < 0 or got != need) return Error.TokenizeFailed;
        const tokens = fitTokens(c.llama_token, all_tokens, self.n_ctx);

        // Build a single-sequence batch covering all tokens.
        var batch = c.llama_batch_init(@intCast(tokens.len), 0, 1);
        defer c.llama_batch_free(batch);

        var i: usize = 0;
        while (i < tokens.len) : (i += 1) {
            batch.token[i] = tokens[i];
            batch.pos[i] = @intCast(i);
            batch.n_seq_id[i] = 1;
            batch.seq_id[i][0] = 0;
            // Pooling needs logits set on every position so the pooled
            // embedding can be computed; for MEAN pooling llama.cpp
            // requires all tokens flagged.
            batch.logits[i] = 1;
        }
        batch.n_tokens = @intCast(tokens.len);

        const rc = if (self.encoder) c.llama_encode(self.ctx, batch) else c.llama_decode(self.ctx, batch);
        if (rc != 0) return Error.DecodeFailed;

        const emb_ptr = c.llama_get_embeddings_seq(self.ctx, 0);
        if (emb_ptr == null) return Error.EmbeddingsUnavailable;

        const out = try gpa.alloc(f32, self.dim);
        @memcpy(out, emb_ptr[0..self.dim]);

        // L2 normalize so cosine-similarity reduces to a dot product.
        var sum: f32 = 0;
        for (out) |v| sum += v * v;
        const norm = std.math.sqrt(sum);
        if (norm > 0) {
            for (out) |*v| v.* /= norm;
        }
        return out;
    }
};

// ---- Tests ----
//
// These run only when `$DEVLOG_INDEX_TEST_MODEL` points at a GGUF file (so CI
// without a model just sees a skip). Point it at the cached model, e.g.
// ~/.devlog-index/models/nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q5_K_M.gguf.

const testing = std.testing;

fn testModelPath() ?[:0]const u8 {
    const env = std.c.getenv("DEVLOG_INDEX_TEST_MODEL") orelse return null;
    return std.mem.span(env);
}

test "embed returns dim-N L2-normalized vector; similar texts cosine-correlate" {
    const path = testModelPath() orelse return error.SkipZigTest;

    model_mod.initBackend();
    defer model_mod.deinitBackend();

    var model = try model_mod.Model.loadFromFile(path, .{ .quiet = true });
    defer model.deinit();

    var emb = try Embedder.init(model, true);
    defer emb.deinit();
    try testing.expectEqual(@as(u32, 768), emb.dim);

    const a = try emb.embed(testing.allocator, .query, "milk no sugar, please");
    defer testing.allocator.free(a);
    const b = try emb.embed(testing.allocator, .document, "I take my tea with milk and no sugar");
    defer testing.allocator.free(b);
    const c_unrelated = try emb.embed(testing.allocator, .document, "the quick brown fox jumps over the lazy dog");
    defer testing.allocator.free(c_unrelated);

    try testing.expectEqual(emb.dim, @as(u32, @intCast(a.len)));

    // L2 norm ≈ 1.
    var norm_a: f32 = 0;
    for (a) |v| norm_a += v * v;
    try testing.expectApproxEqAbs(@as(f32, 1.0), norm_a, 0.001);

    // Cosine similarity (a·b) for related strings should exceed (a·c).
    var sim_ab: f32 = 0;
    var sim_ac: f32 = 0;
    for (a, b, c_unrelated) |x, y, z| {
        sim_ab += x * y;
        sim_ac += x * z;
    }
    try testing.expect(sim_ab > sim_ac);
}

test "an input longer than the context is truncated, not refused" {
    const path = testModelPath() orelse return error.SkipZigTest;

    model_mod.initBackend();
    defer model_mod.deinitBackend();

    var model = try model_mod.Model.loadFromFile(path, .{ .quiet = true });
    defer model.deinit();

    var emb = try Embedder.init(model, true);
    defer emb.deinit();

    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(testing.allocator);
    try long.appendSlice(testing.allocator, "Decision: retry policy\n\n");
    for (0..emb.n_ctx) |_| try long.appendSlice(testing.allocator, "backoff jitter ");

    const v = try emb.embed(testing.allocator, .document, long.items);
    defer testing.allocator.free(v);
    try testing.expectEqual(@as(usize, emb.dim), v.len);
}

test "prefixed puts the task prefix first" {
    const doc = try prefixed(testing.allocator, .document, "Decision: retry policy\n\nWe retry twice.");
    defer testing.allocator.free(doc);
    try testing.expectEqualStrings("search_document: Decision: retry policy\n\nWe retry twice.", doc);

    const q = try prefixed(testing.allocator, .query, "why retry twice?");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("search_query: why retry twice?", q);
}

test "fitTokens leaves a short sequence alone" {
    var tokens = [_]i32{ 101, 7, 8, 102 };
    const fitted = fitTokens(i32, &tokens, 8);
    try testing.expectEqualSlices(i32, &.{ 101, 7, 8, 102 }, fitted);
}

test "fitTokens keeps the start (prefix and title) and the end marker" {
    // [CLS] prefix title body body body body [SEP]
    var tokens = [_]i32{ 101, 1, 2, 3, 4, 5, 6, 102 };
    const fitted = fitTokens(i32, &tokens, 5);
    try testing.expectEqualSlices(i32, &.{ 101, 1, 2, 3, 102 }, fitted);
}

test "fitTokens at exactly the limit is unchanged" {
    var tokens = [_]i32{ 101, 1, 2, 102 };
    const fitted = fitTokens(i32, &tokens, 4);
    try testing.expectEqualSlices(i32, &.{ 101, 1, 2, 102 }, fitted);
}
