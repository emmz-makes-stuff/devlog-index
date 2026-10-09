const std = @import("std");
const bench = @import("bench.zig");

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

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help");
}

test {
    _ = @import("sqlite.zig");
    _ = @import("model.zig");
    _ = @import("model_url.zig");
    _ = @import("download.zig");
    _ = @import("embed.zig");
}
