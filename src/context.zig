const std = @import("std");
const Dir = std.Io.Dir;
const io_util = @import("io_util.zig");
const Context = io_util.Context;

pub fn findHubDir(ctx: *const Context) ?[]const u8 {
    var cur: []const u8 = ctx.invocation_dir;
    while (!std.mem.eql(u8, cur, "/") and cur.len > 0) {
        const git_dir = Dir.path.join(ctx.arena, &.{ cur, ".git" }) catch break;
        const ddev_dir = Dir.path.join(ctx.arena, &.{ cur, ".ddev" }) catch break;
        const arb_file = Dir.path.join(ctx.arena, &.{ cur, ".arborist" }) catch break;

        if ((io_util.dirExists(ctx.io, git_dir) and io_util.dirExists(ctx.io, ddev_dir)) or
            io_util.fileExists(ctx.io, arb_file))
        {
            return cur;
        }
        cur = Dir.path.dirname(cur) orelse "/";
    }
    return null;
}

pub fn requireHubDir(ctx: *const Context) []const u8 {
    return findHubDir(ctx) orelse {
        ctx.errorExit("Not inside a gar hub. Could not find .git and config together.", .{});
    };
}

pub const ActiveWorktreeInfo = struct {
    branch: ?[]const u8,
    wt_top: ?[]const u8,
};

pub fn detectActiveWorktree(ctx: *const Context, hub_dir: []const u8) !ActiveWorktreeInfo {
    const hub_prefix = try std.fmt.allocPrint(ctx.arena, "{s}/", .{hub_dir});
    if (!std.mem.eql(u8, ctx.invocation_dir, hub_dir) and std.mem.startsWith(u8, ctx.invocation_dir, hub_prefix)) {
        const top_res = try io_util.runCapture(ctx, &.{ "git", "-C", ctx.invocation_dir, "rev-parse", "--show-toplevel" }, null);
        if (top_res.success()) {
            const raw_top = std.mem.trim(u8, top_res.stdout, " \t\r\n");
            if (raw_top.len > 0 and !std.mem.eql(u8, raw_top, hub_dir)) {
                const head_res = try io_util.runCapture(ctx, &.{ "git", "-C", raw_top, "rev-parse", "--abbrev-ref", "HEAD" }, null);
                var branch: []const u8 = "";
                if (head_res.success()) {
                    const b = std.mem.trim(u8, head_res.stdout, " \t\r\n");
                    if (b.len > 0 and !std.mem.eql(u8, b, "HEAD")) {
                        branch = try ctx.arena.dupe(u8, b);
                    }
                }
                if (branch.len == 0) {
                    if (std.mem.startsWith(u8, raw_top, hub_prefix)) {
                        branch = try ctx.arena.dupe(u8, raw_top[hub_prefix.len..]);
                    } else {
                        branch = try ctx.arena.dupe(u8, Dir.path.basename(raw_top));
                    }
                }
                return .{
                    .branch = branch,
                    .wt_top = try ctx.arena.dupe(u8, raw_top),
                };
            }
        }
    }
    return .{ .branch = null, .wt_top = null };
}
