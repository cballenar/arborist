const std = @import("std");
const io_util = @import("../io_util.zig");
const Context = io_util.Context;
const context = @import("../context.zig");
const config = @import("../config.zig");
const naming = @import("../naming.zig");

pub fn run(ctx: *const Context, args: []const []const u8) !void {
    if (args.len > 0) {
        const arg0 = args[0];
        if (std.mem.eql(u8, arg0, "-h") or std.mem.eql(u8, arg0, "--help") or std.mem.eql(u8, arg0, "help")) {
            ctx.log(
                \\Usage: gar info
                \\
                \\Show engine, current branch, database name, and site URL for the active worktree.
            , .{});
            return;
        }
    }

    const hub_dir = context.requireHubDir(ctx);
    const cfg = try config.ArboristConfig.load(ctx, hub_dir);

    const active = try context.detectActiveWorktree(ctx, hub_dir);
    const current_branch = active.branch orelse cfg.default_branch;

    const is_default = std.ascii.eqlIgnoreCase(current_branch, cfg.default_branch);
    const target_db = if (is_default)
        "db"
    else
        try naming.getDbName(ctx.arena, current_branch);

    var site_url: []const u8 = "";
    if (std.mem.eql(u8, cfg.env_engine, "ddev")) {
        const domain_info = try config.getDdevDomainInfo(ctx, hub_dir);
        if (domain_info.base_domain.len > 0) {
            if (!is_default) {
                const subdomain = try naming.getWtDirName(ctx.arena, current_branch);
                site_url = try std.fmt.allocPrint(ctx.arena, "{s}://{s}.{s}", .{
                    domain_info.scheme,
                    subdomain,
                    domain_info.base_domain,
                });
            } else {
                site_url = try std.fmt.allocPrint(ctx.arena, "{s}://{s}", .{
                    domain_info.scheme,
                    domain_info.base_domain,
                });
            }
        } else {
            site_url = "<unknown>";
        }
    } else {
        site_url = try std.fmt.allocPrint(ctx.arena, "<unsupported engine: {s}>", .{cfg.env_engine});
    }

    ctx.log("Engine:         {s}", .{cfg.env_engine});
    ctx.log("Current Branch: {s}", .{current_branch});
    ctx.log("DB Name:        {s}", .{target_db});
    ctx.log("URL:            {s}", .{site_url});
}
