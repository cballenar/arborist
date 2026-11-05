const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Allocator = std.mem.Allocator;

pub const Context = struct {
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    environ_map: *std.process.Environ.Map,
    invocation_dir: []const u8,
    exe_path: []const u8,

    pub fn env(self: *const Context, key: []const u8) ?[]const u8 {
        return self.environ_map.get(key);
    }

    pub fn envOrDefault(self: *const Context, key: []const u8, default_val: []const u8) []const u8 {
        if (self.environ_map.get(key)) |val| {
            if (val.len > 0) return val;
        }
        return default_val;
    }

    pub fn isAutoYes(self: *const Context) bool {
        if (self.environ_map.get("GAR_AUTO_YES")) |val| {
            return std.mem.eql(u8, val, "true");
        }
        return false;
    }

    pub fn log(self: *const Context, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.arena, fmt ++ "\n", args) catch return;
        File.stderr().writeStreamingAll(self.io, msg) catch {};
    }

    pub fn logRaw(self: *const Context, text: []const u8) void {
        File.stderr().writeStreamingAll(self.io, text) catch {};
    }

    pub fn out(self: *const Context, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.arena, fmt ++ "\n", args) catch return;
        File.stdout().writeStreamingAll(self.io, msg) catch {};
    }

    pub fn outRaw(self: *const Context, text: []const u8) void {
        File.stdout().writeStreamingAll(self.io, text) catch {};
    }

    pub fn errorExit(self: *const Context, comptime fmt: []const u8, args: anytype) noreturn {
        const msg = std.fmt.allocPrint(self.arena, "\x1b[31mError:\x1b[0m " ++ fmt ++ "\n", args) catch "\x1b[31mError:\x1b[0m fatal error\n";
        File.stderr().writeStreamingAll(self.io, msg) catch {};
        std.process.exit(1);
    }
};

pub fn dirExists(io: Io, path: []const u8) bool {
    if (path.len == 0) return false;
    const st = Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return st.kind == .directory;
}

pub fn fileExists(io: Io, path: []const u8) bool {
    if (path.len == 0) return false;
    const st = Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return st.kind == .file;
}

pub fn pathExists(io: Io, path: []const u8) bool {
    if (path.len == 0) return false;
    _ = Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return true;
}

pub fn isExecutable(io: Io, path: []const u8) bool {
    if (!fileExists(io, path)) return false;
    Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

pub fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8) ?[]u8 {
    return Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch null;
}

pub fn makePath(io: Io, path: []const u8) !void {
    if (path.len == 0 or std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "/")) return;
    try Dir.cwd().createDirPath(io, path);
}

pub fn writeFile(io: Io, path: []const u8, data: []const u8, executable: bool) !void {
    if (Dir.path.dirname(path)) |parent| {
        try makePath(io, parent);
    }
    const perms: File.Permissions = if (executable) .executable_file else .default_file;
    try Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
        .flags = .{
            .truncate = true,
            .permissions = perms,
        },
    });
    if (executable) {
        Dir.cwd().setFilePermissions(io, path, .fromMode(0o755), .{}) catch {};
    }
}

pub fn appendFile(allocator: Allocator, io: Io, path: []const u8, data: []const u8) !void {
    if (Dir.path.dirname(path)) |parent| {
        try makePath(io, parent);
    }
    const existing = readFileAlloc(allocator, io, path) orelse "";
    const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, data });
    try writeFile(io, path, combined, false);
}

pub fn copyFile(allocator: Allocator, io: Io, src: []const u8, dst: []const u8, executable: bool) !void {
    const content = readFileAlloc(allocator, io, src) orelse return error.FileNotFound;
    try writeFile(io, dst, content, executable);
}

pub fn realPathOrCopy(allocator: Allocator, io: Io, path: []const u8) ![]const u8 {
    return Dir.cwd().realPathFileAlloc(io, path, allocator) catch {
        return allocator.dupe(u8, path);
    };
}

pub const CmdResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn success(self: CmdResult) bool {
        return self.term.success();
    }

    pub fn exitCode(self: CmdResult) u8 {
        return switch (self.term) {
            .exited => |code| code,
            else => 1,
        };
    }
};

pub fn runCapture(ctx: *const Context, argv: []const []const u8, cwd_path: ?[]const u8) !CmdResult {
    const cwd_opt: std.process.Child.Cwd = if (cwd_path) |p| .{ .path = p } else .inherit;
    const res = try std.process.run(ctx.arena, ctx.io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .environ_map = ctx.environ_map,
    });
    return .{
        .term = res.term,
        .stdout = res.stdout,
        .stderr = res.stderr,
    };
}

pub fn runQuiet(ctx: *const Context, argv: []const []const u8, cwd_path: ?[]const u8) bool {
    const cwd_opt: std.process.Child.Cwd = if (cwd_path) |p| .{ .path = p } else .inherit;
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .environ_map = ctx.environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(ctx.io) catch return false;
    return term.success();
}

/// Runs a subprocess where both child stdout and stderr are routed to our stderr,
/// preserving our stdout strictly for shell integration (`cd` paths).
pub fn runInheritStderr(ctx: *const Context, argv: []const []const u8, cwd_path: ?[]const u8) !u8 {
    const cwd_opt: std.process.Child.Cwd = if (cwd_path) |p| .{ .path = p } else .inherit;
    var child = try std.process.spawn(ctx.io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .environ_map = ctx.environ_map,
        .stdin = .inherit,
        .stdout = .{ .file = File.stderr() },
        .stderr = .inherit,
    });
    const term = try child.wait(ctx.io);
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

/// Runs a shell pipeline or post-provision command string under `bash -c` with `set -e`.
pub fn runShellCommand(ctx: *const Context, cmd: []const u8, cwd_path: ?[]const u8) !u8 {
    const script = try std.fmt.allocPrint(ctx.arena, "set -e\n{s}", .{cmd});
    return runInheritStderr(ctx, &.{ "bash", "-c", script }, cwd_path);
}

/// Checks if a binary exists in the current PATH.
pub fn commandExists(ctx: *const Context, bin_name: []const u8) bool {
    const path_env = ctx.env("PATH") orelse return false;
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const candidate = Dir.path.join(ctx.arena, &.{ dir, bin_name }) catch continue;
        if (isExecutable(ctx.io, candidate)) return true;
    }
    return false;
}
