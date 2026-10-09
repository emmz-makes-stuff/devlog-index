const std = @import("std");
const bench = @import("bench.zig");
const workspace = @import("workspace.zig");
const update = @import("update.zig");
const status = @import("status.zig");
const model_url = @import("model_url.zig");

const usage =
    \\Usage: devlog-index <command> [options]
    \\
    \\Commands:
    \\  init <name> <member>...   Declare a workspace in the current directory.
    \\  update [--rebuild]        Index the workspace (incremental by default).
    \\  query [--json] [--k N] "<text>"
    \\                            Ranked passages for a plain-language question.
    \\  status [--json]           Index freshness, counts and model presence.
    \\  eval                      Check retrieval against the golden set.
    \\
    \\Options:
    \\  -h, --help                Show this help.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    if (args.len < 2 or isHelp(args[1])) {
        try out.writeAll(usage);
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, args[1], "init")) {
        if (args.len < 4) {
            std.debug.print("usage: devlog-index init <name> <member>...\n", .{});
            std.process.exit(2);
        }
        var stderr_buf: [1024]u8 = undefined;
        var stderr_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buf);
        const root = try std.process.currentPathAlloc(init.io, arena);
        var diag: workspace.Diag = .{};
        workspace.init(arena, init.io, .cwd(), root, args[2], args[3..], &stderr_writer.interface, &diag) catch |err| {
            stderr_writer.interface.flush() catch {};
            switch (err) {
                error.OutOfMemory => return err,
                else => fatal(diag.message),
            }
        };
        try stderr_writer.interface.flush();
        try out.print("devlog-index: created {s}\n", .{workspace.config_basename});
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, args[1], "update")) {
        var rebuild = false;
        for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--rebuild")) rebuild = true else {
                std.debug.print("usage: devlog-index update [--rebuild]\n", .{});
                std.process.exit(2);
            }
        }
        const ws = resolveWorkspace(init, arena);
        for (ws.members) |m| if (m.status != .ok)
            std.debug.print("devlog-index: warning: member \"{s}\" {s}; {s}\n", .{
                m.declared,
                m.status.describe(),
                if (rebuild) "it is left out of the rebuilt index" else "its indexed passages are kept",
            });

        const home = init.environ_map.get("HOME") orelse fatal("HOME is not set; it locates the model cache");
        var mp = try update.ModelProvider.pinned(arena, init.gpa, init.io, home);
        defer mp.deinit();
        const t0 = std.Io.Timestamp.now(init.io, .awake);
        var stderr_buf: [256]u8 = undefined;
        var stderr_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buf);
        var diag: update.Diag = .{};
        const r = update.run(arena, init.gpa, init.io, ws, .{ .rebuild = rebuild, .provider = mp.provider(), .progress = &stderr_writer.interface }, &diag) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => fatal(diag.message),
        };
        const elapsed_ms: u64 = @intCast(@divFloor(std.Io.Timestamp.now(init.io, .awake).nanoseconds - t0.nanoseconds, std.time.ns_per_ms));
        try out.print(
            "devlog-index: {s}: {d} files changed ({d} added, {d} changed, {d} removed), {d} unchanged; " ++
                "{d} passages embedded, {d} reused; {d} passages in the index; {d}.{d:0>1} s\n",
            .{ ws.name, r.filesChanged(), r.added, r.changed, r.removed, r.unchanged, r.passages_embedded, r.passages_reused, r.passages_total, @divFloor(elapsed_ms, 1000), @divFloor(@mod(elapsed_ms, 1000), 100) },
        );
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, args[1], "status")) {
        var json = false;
        for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--json")) json = true else {
                std.debug.print("usage: devlog-index status [--json]\n", .{});
                std.process.exit(2);
            }
        }
        const ws = resolveWorkspace(init, arena);
        const home = init.environ_map.get("HOME") orelse fatal("HOME is not set; it locates the model cache");
        const model_path = try model_url.cachePathZ(arena, home, try model_url.parse(model_url.pinned_url));
        var diag: status.Diag = .{};
        const s = status.gather(arena, init.io, ws, model_path, &diag) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => fatal(diag.message),
        };
        if (json) try status.writeJson(s, out) else try status.writeText(s, out);
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, args[1], "bench-cold")) {
        bench.run(init, args[2..], out) catch |err| switch (err) {
            error.Usage => {
                std.debug.print("usage: devlog-index bench-cold [--setup] <db>\n", .{});
                std.process.exit(2);
            },
            else => return err,
        };
        try out.flush();
        return;
    }

    std.debug.print("devlog-index: unknown command '{s}'\n\n{s}", .{ args[1], usage });
    std.process.exit(2);
}

/// The workspace for every command except `init`, or exit naming `init`.
fn resolveWorkspace(init: std.process.Init, arena: std.mem.Allocator) workspace.Workspace {
    const cwd = std.process.currentPathAlloc(init.io, arena) catch |err|
        fatal(std.fmt.allocPrint(arena, "cannot read the current directory ({s})", .{@errorName(err)}) catch "out of memory");
    var diag: workspace.Diag = .{};
    return workspace.resolve(arena, init.io, cwd, &diag) catch |err| switch (err) {
        error.OutOfMemory => fatal("out of memory"),
        else => fatal(diag.message),
    };
}

fn fatal(message: []const u8) noreturn {
    std.debug.print("devlog-index: {s}\n", .{message});
    std.process.exit(1);
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help");
}

test {
    _ = @import("sqlite.zig");
    _ = @import("model.zig");
    _ = @import("model_url.zig");
    _ = @import("download.zig");
    _ = @import("embed.zig");
    _ = @import("workspace.zig");
    _ = @import("sources.zig");
    _ = @import("chunk.zig");
    _ = @import("db.zig");
    _ = @import("index.zig");
    _ = @import("update.zig");
    _ = @import("freshness.zig");
    _ = @import("status.zig");
}
