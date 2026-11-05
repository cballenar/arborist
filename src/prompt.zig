const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const io_util = @import("io_util.zig");
const Context = io_util.Context;

pub fn isStdinTty(ctx: *const Context) bool {
    return File.stdin().isTty(ctx.io) catch false;
}

pub fn readLine(ctx: *const Context, prompt_msg: []const u8, prefer_tty: bool) ?[]const u8 {
    if (prompt_msg.len > 0) {
        ctx.logRaw(prompt_msg);
    }

    var tty_file: ?File = null;
    defer if (tty_file) |f| f.close(ctx.io);

    const input_file: File = blk: {
        if (prefer_tty and isStdinTty(ctx)) {
            if (Dir.cwd().openFile(ctx.io, "/dev/tty", .{ .mode = .read_only })) |f| {
                tty_file = f;
                break :blk f;
            } else |_| {}
        }
        break :blk File.stdin();
    };

    return readLineFromFile(ctx, input_file);
}

fn readLineFromFile(ctx: *const Context, file: File) ?[]const u8 {
    var list: std.ArrayList(u8) = .empty;
    var byte_buf: [1]u8 = undefined;
    var got_any = false;

    while (true) {
        var slices = [_][]u8{byte_buf[0..]};
        const n = file.readStreaming(ctx.io, &slices) catch break;
        if (n == 0) break;
        got_any = true;
        if (byte_buf[0] == '\n') break;
        if (byte_buf[0] != '\r') {
            list.append(ctx.arena, byte_buf[0]) catch break;
        }
    }

    if (!got_any and list.items.len == 0) return null;
    return list.items;
}

pub fn confirm(ctx: *const Context, prompt_msg: []const u8, default_yes: bool, prefer_tty: bool) bool {
    const resp_opt = readLine(ctx, prompt_msg, prefer_tty);
    const resp = if (resp_opt) |r| std.mem.trim(u8, r, " \t\r\n") else "";
    if (resp.len == 0) return default_yes;
    return resp[0] == 'y' or resp[0] == 'Y';
}

pub const TimeoutConfirmResult = struct {
    confirmed: bool,
    timed_out: bool,
};

pub fn confirmWithTimeout(
    ctx: *const Context,
    prompt_msg: []const u8,
    timeout_secs: u32,
    default_yes: bool,
) TimeoutConfirmResult {
    if (prompt_msg.len > 0) {
        ctx.logRaw(prompt_msg);
    }

    var tty_file: ?File = null;
    defer if (tty_file) |f| f.close(ctx.io);

    const input_file: File = blk: {
        if (isStdinTty(ctx)) {
            if (Dir.cwd().openFile(ctx.io, "/dev/tty", .{ .mode = .read_only })) |f| {
                tty_file = f;
                break :blk f;
            } else |_| {}
        }
        break :blk File.stdin();
    };

    var pfd = [1]std.posix.pollfd{.{
        .fd = input_file.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    const timeout_ms: i32 = @intCast(timeout_secs * 1000);
    const ready = std.posix.poll(&pfd, timeout_ms) catch 0;
    if (ready == 0) {
        ctx.logRaw("\n");
        return .{ .confirmed = default_yes, .timed_out = true };
    }

    const resp_opt = readLineFromFile(ctx, input_file);
    const resp = if (resp_opt) |r| std.mem.trim(u8, r, " \t\r\n") else "";
    if (resp.len == 0) {
        return .{ .confirmed = default_yes, .timed_out = false };
    }
    return .{
        .confirmed = (resp[0] == 'y' or resp[0] == 'Y'),
        .timed_out = false,
    };
}
