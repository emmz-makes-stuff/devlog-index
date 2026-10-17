//! GGUF model lifecycle wrapper over the llama.cpp.zig bindings.
//!
//! Provenance: copied from memlite `src/model.zig` at 749b246
//! (daemonicai/memlite); the stderr redirect is factored out as `Quiet` so
//! the embedder can reuse it, and the log callback is a no-op rather than
//! null (null restores llama.cpp's stderr logger). Owns the llama_backend init/free pair and the
//! `llama_model *`.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("llama_c");

pub const Error = error{
    BackendInitFailed,
    ModelLoadFailed,
    ContextInitFailed,
    TokenizeFailed,
    DecodeFailed,
    EmbeddingsUnavailable,
};

/// One-shot backend init. Idempotency is the caller's job — call once
/// before any Model.load and free at process exit.
pub fn initBackend() void {
    c.llama_backend_init();
    // Silence llama.cpp's log output. A null callback would restore its
    // default stderr logger (memlite's original call did that), so install a
    // no-op instead.
    c.llama_log_set(discardLog, null);
}

fn discardLog(_: c.enum_ggml_log_level, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {}

pub fn deinitBackend() void {
    c.llama_backend_free();
}

/// Redirects stderr to the null device until `restore`, to silence
/// llama.cpp's direct `fprintf(stderr, …)` chatter. If the null device can't
/// be opened or `dup` fails, stderr is left intact.
pub const Quiet = struct {
    saved: c_int = -1,

    // llama.cpp writes through the C runtime's stderr, so on Windows the
    // redirect has to go through the CRT's file descriptors too: `std.c`
    // models Windows fds as handles, and `SetStdHandle` would not touch fd 2.
    const crt = struct {
        extern "c" fn _open(path: [*:0]const u8, oflag: c_int, ...) c_int;
        extern "c" fn _dup(fd: c_int) c_int;
        extern "c" fn _dup2(old: c_int, new: c_int) c_int;
        extern "c" fn _close(fd: c_int) c_int;
        const o_wronly = 0x0001;
    };

    const stderr_fd: c_int = 2;

    pub fn begin(on: bool) Quiet {
        if (!on) return .{};
        if (builtin.os.tag == .windows) {
            const null_fd = crt._open("NUL", crt.o_wronly);
            if (null_fd < 0) return .{};
            defer _ = crt._close(null_fd);
            const saved = crt._dup(stderr_fd);
            if (saved >= 0) _ = crt._dup2(null_fd, stderr_fd);
            return .{ .saved = saved };
        }
        const dev_null = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
        if (dev_null < 0) return .{};
        defer _ = std.c.close(dev_null);
        const saved = std.c.dup(std.posix.STDERR_FILENO);
        if (saved >= 0) _ = std.c.dup2(dev_null, std.posix.STDERR_FILENO);
        return .{ .saved = saved };
    }

    pub fn restore(self: Quiet) void {
        if (self.saved < 0) return;
        if (builtin.os.tag == .windows) {
            _ = crt._dup2(self.saved, stderr_fd);
            _ = crt._close(self.saved);
            return;
        }
        _ = std.c.dup2(self.saved, std.posix.STDERR_FILENO);
        _ = std.c.close(self.saved);
    }
};

pub const LoadOptions = struct {
    /// When true, silence direct `fprintf(stderr, …)` chatter from the
    /// llama.cpp loader (`llama_model_loader:`, `print_info:`,
    /// `load_tensors:`, `create_tensor:`) by redirecting STDERR_FILENO to
    /// `/dev/null` (`NUL` on Windows) for the duration of `llama_model_load_from_file`. The
    /// callback path (covered by `llama_log_set(null, null)` in
    /// `initBackend`) is unaffected. Where the null device cannot be opened or `dup` fails the load proceeds with
    /// stderr intact rather than failing.
    quiet: bool = false,
};

pub const Model = struct {
    handle: *c.llama_model,

    /// Load a GGUF file from disk. CPU-only (n_gpu_layers = 0).
    pub fn loadFromFile(path: [:0]const u8, opts: LoadOptions) Error!Model {
        var params = c.llama_model_default_params();
        params.n_gpu_layers = 0;

        const quiet = Quiet.begin(opts.quiet);
        defer quiet.restore();

        const m = c.llama_model_load_from_file(path.ptr, params);
        if (m == null) return Error.ModelLoadFailed;
        return .{ .handle = m.? };
    }

    pub fn deinit(self: *Model) void {
        c.llama_model_free(self.handle);
        self.* = undefined;
    }

    /// Embedding dimension reported by the GGUF model. This is the N that
    /// goes into vec0's `FLOAT[N]` declaration.
    pub fn embeddingDim(self: Model) u32 {
        const n = c.llama_model_n_embd(self.handle);
        std.debug.assert(n > 0);
        return @intCast(n);
    }

    /// Maximum context the model was trained on. Used by the embedding
    /// context to size n_ctx safely.
    pub fn trainedCtxLen(self: Model) u32 {
        const n = c.llama_model_n_ctx_train(self.handle);
        return if (n > 0) @intCast(n) else 0;
    }
};
