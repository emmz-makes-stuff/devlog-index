//! Workspace config (`devlog-index.json`): parsing, walk-up resolution from
//! the working directory (nearest wins), member status, and `init`.
//!
//! Everything returned is allocated in the caller's arena. Failures that the
//! user must act on fill `Diag.message` (naming the file) before returning an
//! error, so the CLI can print it as-is.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const config_basename = "devlog-index.json";
/// Beside the config: holds `index.db` and `golden.json` (D4).
pub const data_dirname = ".devlog-index";

pub const no_workspace_message =
    "no workspace found (no " ++ config_basename ++ " in this directory or any parent); " ++
    "create one in the workspace root with: devlog-index init <name> <member>...";

pub const Diag = struct {
    message: []const u8 = "",
};

pub const Config = struct {
    name: []const u8,
    /// Member paths as written in the config.
    members: []const []const u8,
};

pub const MemberStatus = enum {
    ok,
    /// The path does not exist (or is not a directory).
    missing,
    /// The directory exists but has no `openspec/` directory.
    no_openspec,

    pub fn describe(s: MemberStatus) []const u8 {
        return switch (s) {
            .ok => "ok",
            .missing => "not found",
            .no_openspec => "has no openspec/ directory",
        };
    }
};

pub const Member = struct {
    /// As written in the config.
    declared: []const u8,
    /// Absolute and normalised: relative paths resolve against the root.
    path: []const u8,
    status: MemberStatus,
};

pub const Workspace = struct {
    name: []const u8,
    /// Absolute directory holding the config.
    root: []const u8,
    config_path: []const u8,
    members: []const Member,

    pub fn dataDir(ws: Workspace, arena: Allocator) Allocator.Error![]const u8 {
        return std.fs.path.join(arena, &.{ ws.root, data_dirname });
    }
};

pub const ParseError = error{InvalidConfig} || Allocator.Error;

/// Parse and validate config text. Rejects unknown fields, an empty name, an
/// empty member list, empty member paths and members that resolve to the same
/// path. `root` is only used for that duplicate check.
pub fn parse(arena: Allocator, root: []const u8, bytes: []const u8, diag: *Diag) ParseError!Config {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| {
        return fail(arena, diag, "invalid JSON ({s})", .{@errorName(err)});
    };
    const obj = switch (value) {
        .object => |o| o,
        else => return fail(arena, diag, "expected a JSON object with \"name\" and \"members\"", .{}),
    };

    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "name") and !std.mem.eql(u8, key, "members"))
            return fail(arena, diag, "unknown field \"{s}\" (allowed: \"name\", \"members\")", .{key});
    }

    const name = switch (obj.get("name") orelse return fail(arena, diag, "missing \"name\"", .{})) {
        .string => |s| s,
        else => return fail(arena, diag, "\"name\" must be a string", .{}),
    };
    const items = switch (obj.get("members") orelse return fail(arena, diag, "missing \"members\"", .{})) {
        .array => |a| a.items,
        else => return fail(arena, diag, "\"members\" must be an array of paths", .{}),
    };

    const members = try arena.alloc([]const u8, items.len);
    for (items, members) |item, *m| {
        m.* = switch (item) {
            .string => |s| s,
            else => return fail(arena, diag, "\"members\" must be an array of paths", .{}),
        };
    }

    const config: Config = .{ .name = name, .members = members };
    try validate(arena, root, config, diag);
    return config;
}

/// The rules `parse` enforces beyond JSON shape; `init` uses them too, so it
/// can never write a config that `parse` would reject.
pub fn validate(arena: Allocator, root: []const u8, config: Config, diag: *Diag) ParseError!void {
    if (std.mem.trim(u8, config.name, " \t\r\n").len == 0)
        return fail(arena, diag, "\"name\" must not be empty", .{});
    if (config.members.len == 0)
        return fail(arena, diag, "\"members\" must list at least one member path", .{});

    const resolved = try arena.alloc([]const u8, config.members.len);
    for (config.members, resolved, 0..) |m, *r, i| {
        if (m.len == 0) return fail(arena, diag, "member paths must not be empty", .{});
        r.* = try resolveMember(arena, root, m);
        for (resolved[0..i], config.members[0..i]) |prev, prev_declared| {
            if (std.mem.eql(u8, prev, r.*))
                return fail(arena, diag, "members \"{s}\" and \"{s}\" are the same path", .{ prev_declared, m });
            // The folder name is the member's label in the index and in results.
            if (std.mem.eql(u8, std.fs.path.basename(prev), std.fs.path.basename(r.*)))
                return fail(arena, diag, "members \"{s}\" and \"{s}\" have the same folder name, which labels them; rename one", .{ prev_declared, m });
        }
    }
}

/// Absolute paths are used as-is; relative ones resolve against `root`.
/// Either way the result is normalised (`.` and `..` removed).
pub fn resolveMember(arena: Allocator, root: []const u8, declared: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.isAbsolute(declared)) return std.fs.path.resolve(arena, &.{declared});
    return std.fs.path.resolve(arena, &.{ root, declared });
}

pub fn memberStatus(io: Io, path: []const u8) MemberStatus {
    const cwd = Io.Dir.cwd();
    var dir = cwd.openDir(io, path, .{}) catch return .missing;
    defer dir.close(io);
    var spec_dir = dir.openDir(io, "openspec", .{}) catch return .no_openspec;
    spec_dir.close(io);
    return .ok;
}

pub const ResolveError = error{ NoWorkspace, InvalidConfig, ReadFailed } || Allocator.Error;

/// Find the nearest config at or above `start` (an absolute directory) and
/// load it. On `NoWorkspace`, `diag.message` is `no_workspace_message`.
pub fn resolve(arena: Allocator, io: Io, start: []const u8, diag: *Diag) ResolveError!Workspace {
    std.debug.assert(std.fs.path.isAbsolute(start));
    const cwd = Io.Dir.cwd();
    var dir: ?[]const u8 = try std.fs.path.resolve(arena, &.{start});
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const candidate = try std.fs.path.join(arena, &.{ d, config_basename });
        cwd.access(io, candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                diag.message = try std.fmt.allocPrint(arena, "{s}: cannot access ({s})", .{ candidate, @errorName(err) });
                return error.ReadFailed;
            },
        };
        return load(arena, io, d, candidate, diag);
    }
    diag.message = no_workspace_message;
    return error.NoWorkspace;
}

const max_config_bytes = 1024 * 1024;

fn load(arena: Allocator, io: Io, root: []const u8, config_path: []const u8, diag: *Diag) ResolveError!Workspace {
    const bytes = Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(max_config_bytes)) catch |err| {
        diag.message = try std.fmt.allocPrint(arena, "{s}: cannot read ({s})", .{ config_path, @errorName(err) });
        return error.ReadFailed;
    };
    const config = parse(arena, root, bytes, diag) catch |err| switch (err) {
        error.InvalidConfig => {
            diag.message = try std.fmt.allocPrint(arena, "{s}: {s}", .{ config_path, diag.message });
            return error.InvalidConfig;
        },
        else => |e| return e,
    };

    const members = try arena.alloc(Member, config.members.len);
    for (config.members, members) |declared, *m| {
        const path = try resolveMember(arena, root, declared);
        m.* = .{ .declared = declared, .path = path, .status = memberStatus(io, path) };
    }
    return .{ .name = config.name, .root = root, .config_path = config_path, .members = members };
}

pub const InitError = error{ ConfigExists, InvalidConfig, WriteFailed } || Allocator.Error;

/// Write a new config into `dir` (whose absolute path is `root`). Refuses to
/// touch an existing config. Members that are missing or lack `openspec/`
/// are still written, with one warning each on `warn`.
pub fn init(
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    root: []const u8,
    name: []const u8,
    members: []const []const u8,
    warn: *Io.Writer,
    diag: *Diag,
) InitError!void {
    const config: Config = .{ .name = name, .members = members };
    validate(arena, root, config, diag) catch |err| switch (err) {
        error.InvalidConfig => {
            diag.message = try std.fmt.allocPrint(arena, "init: {s}", .{diag.message});
            return error.InvalidConfig;
        },
        else => |e| return e,
    };

    var aw: Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(config, .{ .whitespace = .indent_2 }, &aw.writer) catch return error.OutOfMemory;
    aw.writer.writeByte('\n') catch return error.OutOfMemory;

    const config_path = try std.fs.path.join(arena, &.{ root, config_basename });
    var file = dir.createFile(io, config_basename, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            diag.message = try std.fmt.allocPrint(arena, "{s} already exists; not overwriting it", .{config_path});
            return error.ConfigExists;
        },
        else => {
            diag.message = try std.fmt.allocPrint(arena, "{s}: cannot create ({s})", .{ config_path, @errorName(err) });
            return error.WriteFailed;
        },
    };
    file.writeStreamingAll(io, aw.written()) catch |err| {
        file.close(io);
        dir.deleteFile(io, config_basename) catch {};
        diag.message = try std.fmt.allocPrint(arena, "{s}: write failed ({s})", .{ config_path, @errorName(err) });
        return error.WriteFailed;
    };
    file.close(io);

    for (members) |m| {
        const status = memberStatus(io, try resolveMember(arena, root, m));
        if (status != .ok)
            warn.print("devlog-index: warning: member \"{s}\" {s}\n", .{ m, status.describe() }) catch {};
    }
}

fn fail(arena: Allocator, diag: *Diag, comptime fmt: []const u8, args: anytype) ParseError {
    diag.message = try std.fmt.allocPrint(arena, fmt, args);
    return error.InvalidConfig;
}

// ---- tests ----

const testing = std.testing;

fn tmpRoot(arena: Allocator, tmp: *testing.TmpDir) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    return arena.dupe(u8, buf[0..n]);
}

fn writeFile(dir: Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(testing.io, parent);
    try dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
}

test "parse accepts name and members" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = .{};
    const c = try parse(arena_state.allocator(), "/w", "{\"name\":\"acme\",\"members\":[\"api\",\"../infra\"]}", &diag);
    try testing.expectEqualStrings("acme", c.name);
    try testing.expectEqual(@as(usize, 2), c.members.len);
    try testing.expectEqualStrings("../infra", c.members[1]);
}

test "parse rejects bad configs with a reason" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { json: []const u8, reason: []const u8 }{
        .{ .json = "{\"name\":\"a\",\"member\":[\"x\"]}", .reason = "unknown field \"member\"" },
        .{ .json = "{\"members\":[\"x\"]}", .reason = "missing \"name\"" },
        .{ .json = "{\"name\":\"a\"}", .reason = "missing \"members\"" },
        .{ .json = "{\"name\":\" \",\"members\":[\"x\"]}", .reason = "\"name\" must not be empty" },
        .{ .json = "{\"name\":\"a\",\"members\":[]}", .reason = "at least one member" },
        .{ .json = "{\"name\":\"a\",\"members\":[\"x\",\"\"]}", .reason = "must not be empty" },
        .{ .json = "{\"name\":\"a\",\"members\":[\"x\",3]}", .reason = "array of paths" },
        .{ .json = "{\"name\":\"a\",\"members\":[\"x\",\"./x\"]}", .reason = "same path" },
        .{ .json = "{\"name\":\"a\",\"members\":[\"/w/x\",\"x\"]}", .reason = "same path" },
        .{ .json = "{\"name\":\"a\",\"members\":[\"a/api\",\"b/api\"]}", .reason = "\"a/api\" and \"b/api\" have the same folder name" },
        .{ .json = "[\"a\"]", .reason = "expected a JSON object" },
        .{ .json = "{\"name\":", .reason = "invalid JSON" },
    };
    for (cases) |case| {
        var diag: Diag = .{};
        try testing.expectError(error.InvalidConfig, parse(arena, "/w", case.json, &diag));
        if (std.mem.indexOf(u8, diag.message, case.reason) == null) {
            std.debug.print("json {s}: got \"{s}\", want \"{s}\"\n", .{ case.json, diag.message, case.reason });
            return error.TestUnexpectedDiag;
        }
    }
}

test "resolveMember: relative to root, absolute as-is, normalised" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("/w/api", try resolveMember(arena, "/w", "api"));
    try testing.expectEqualStrings("/w/api", try resolveMember(arena, "/w", "./api/"));
    try testing.expectEqualStrings("/other/infra", try resolveMember(arena, "/w", "../other/infra"));
    try testing.expectEqualStrings("/abs/x", try resolveMember(arena, "/w", "/abs/x"));
}

test "resolve walks up from a member subdirectory and reports member status" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    try writeFile(tmp.dir, config_basename, "{\"name\":\"acme\",\"members\":[\"api\",\"bare\",\"gone\"]}");
    try writeFile(tmp.dir, "api/openspec/project.md", "");
    try writeFile(tmp.dir, "api/src/main.zig", "");
    try tmp.dir.createDirPath(testing.io, "bare");

    var diag: Diag = .{};
    const start = try std.fs.path.join(arena, &.{ root, "api", "src" });
    const ws = try resolve(arena, testing.io, start, &diag);
    try testing.expectEqualStrings("acme", ws.name);
    try testing.expectEqualStrings(root, ws.root);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ root, config_basename }), ws.config_path);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ root, data_dirname }), try ws.dataDir(arena));
    try testing.expectEqual(@as(usize, 3), ws.members.len);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ root, "api" }), ws.members[0].path);
    try testing.expectEqual(MemberStatus.ok, ws.members[0].status);
    try testing.expectEqual(MemberStatus.no_openspec, ws.members[1].status);
    try testing.expectEqual(MemberStatus.missing, ws.members[2].status);
}

test "resolve: nearest config wins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    try writeFile(tmp.dir, config_basename, "{\"name\":\"outer\",\"members\":[\"acme\"]}");
    try writeFile(tmp.dir, "acme/" ++ config_basename, "{\"name\":\"acme\",\"members\":[\"api\"]}");
    try tmp.dir.createDirPath(testing.io, "acme/api");

    var diag: Diag = .{};
    const ws = try resolve(arena, testing.io, try std.fs.path.join(arena, &.{ root, "acme", "api" }), &diag);
    try testing.expectEqualStrings("acme", ws.name);
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ root, "acme" }), ws.root);

    const outer = try resolve(arena, testing.io, root, &diag);
    try testing.expectEqualStrings("outer", outer.name);
}

test "resolve: invalid config names the file" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);
    try writeFile(tmp.dir, config_basename, "{\"name\":\"acme\",\"members\":[\"api\"],\"extra\":1}");

    var diag: Diag = .{};
    try testing.expectError(error.InvalidConfig, resolve(arena, testing.io, root, &diag));
    try testing.expect(std.mem.startsWith(u8, diag.message, try std.fs.path.join(arena, &.{ root, config_basename })));
    try testing.expect(std.mem.indexOf(u8, diag.message, "unknown field \"extra\"") != null);
}

test "resolve: no config anywhere names init" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a/b");
    const root = try tmpRoot(arena, &tmp);

    // The temp dir sits under the repo's .zig-cache; a config in the repo or
    // above it would be found first, so only assert when none exists.
    var diag: Diag = .{};
    if (resolve(arena, testing.io, try std.fs.path.join(arena, &.{ root, "a", "b" }), &diag)) |_| {
        return error.SkipZigTest;
    } else |err| {
        try testing.expectEqual(error.NoWorkspace, err);
        try testing.expect(std.mem.indexOf(u8, diag.message, "devlog-index init") != null);
    }
}

test "init writes a config, warns on bad members, and refuses to overwrite" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);
    try writeFile(tmp.dir, "api/openspec/project.md", "");
    try tmp.dir.createDirPath(testing.io, "bare");

    var warn: Io.Writer.Allocating = .init(arena);
    var diag: Diag = .{};
    const members = [_][]const u8{ "api", "bare", "gone" };
    try init(arena, testing.io, tmp.dir, root, "acme", &members, &warn.writer, &diag);

    const written = try tmp.dir.readFileAlloc(testing.io, config_basename, arena, .unlimited);
    const config = try parse(arena, root, written, &diag);
    try testing.expectEqualStrings("acme", config.name);
    try testing.expectEqual(@as(usize, 3), config.members.len);
    for (members, config.members) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expect(std.mem.endsWith(u8, written, "\n"));

    const warnings = warn.written();
    try testing.expect(std.mem.indexOf(u8, warnings, "\"api\"") == null);
    try testing.expect(std.mem.indexOf(u8, warnings, "\"bare\" has no openspec/ directory") != null);
    try testing.expect(std.mem.indexOf(u8, warnings, "\"gone\" not found") != null);

    // Resolution reads what init wrote.
    const ws = try resolve(arena, testing.io, root, &diag);
    try testing.expectEqualStrings("acme", ws.name);

    // A second init fails naming the file and leaves it unchanged.
    diag = .{};
    try testing.expectError(error.ConfigExists, init(arena, testing.io, tmp.dir, root, "other", &.{"x"}, &warn.writer, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, try std.fs.path.join(arena, &.{ root, config_basename })) != null);
    const after = try tmp.dir.readFileAlloc(testing.io, config_basename, arena, .unlimited);
    try testing.expectEqualStrings(written, after);
}

test "init refuses an invalid config without writing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(arena, &tmp);

    var warn: Io.Writer.Allocating = .init(arena);
    var diag: Diag = .{};
    try testing.expectError(error.InvalidConfig, init(arena, testing.io, tmp.dir, root, "acme", &.{ "api", "api/" }, &warn.writer, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "same path") != null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, config_basename, .{}));
}
