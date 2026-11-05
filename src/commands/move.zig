const std = @import("std");
const Dir = std.Io.Dir;
const io_util = @import("../io_util.zig");
const Context = io_util.Context;
const config = @import("../config.zig");
const context = @import("../context.zig");
const git = @import("../git.zig");
const naming = @import("../naming.zig");
const prompt = @import("../prompt.zig");
const templates = @import("../templates.zig");
const ddev = @import("../engine/ddev.zig");

const help_text =
    \\Usage: gar move [options] [old_branch] <new_branch>
    \\Aliases: gar mv, gar -m
    \\
    \\Move or rename a worktree, its Git branch, and isolated database.
    \\
    \\Arguments:
    \\  [old_branch]   Existing branch/worktree to rename (defaults to current worktree).
    \\  <new_branch>   New branch/worktree name.
    \\
    \\Options:
    \\  -h, --help     Show this help message
    \\
;

pub fn run(ctx: *const Context, args: []const []const u8) !void {
    if (args.len > 0) {
        const arg0 = args[0];
        if (std.mem.eql(u8, arg0, "-h") or std.mem.eql(u8, arg0, "--help") or std.mem.eql(u8, arg0, "help")) {
            ctx.logRaw(help_text);
            return;
        }
    }

    if (args.len == 0 or args[0].len == 0) {
        ctx.errorExit("Usage: gar move [old_branch] <new_branch>\nAliases: gar mv, gar -m", .{});
    }

    const hub_dir = context.requireHubDir(ctx);
    const cfg = try config.ArboristConfig.load(ctx, hub_dir);
    const hub_slash = try std.fmt.allocPrint(ctx.arena, "{s}/", .{hub_dir});

    var old_branch: []const u8 = "";
    var new_branch: []const u8 = "";

    if (args.len < 2 or args[1].len == 0) {
        new_branch = args[0];
        if (!std.mem.eql(u8, ctx.invocation_dir, hub_dir) and
            std.mem.startsWith(u8, ctx.invocation_dir, hub_slash))
        {
            if (io_util.runCapture(ctx, &.{ "git", "-C", ctx.invocation_dir, "rev-parse", "--show-toplevel" }, null)) |top_res| {
                if (top_res.success()) {
                    const wt_top = std.mem.trim(u8, top_res.stdout, " \t\r\n");
                    if (wt_top.len > 0 and !std.mem.eql(u8, wt_top, hub_dir)) {
                        if (io_util.runCapture(ctx, &.{ "git", "-C", wt_top, "rev-parse", "--abbrev-ref", "HEAD" }, null)) |b_res| {
                            if (b_res.success()) {
                                const b = std.mem.trim(u8, b_res.stdout, " \t\r\n");
                                if (b.len > 0 and !std.mem.eql(u8, b, "HEAD")) {
                                    old_branch = b;
                                } else if (std.mem.startsWith(u8, wt_top, hub_slash)) {
                                    old_branch = wt_top[hub_slash.len..];
                                }
                            }
                        } else |_| {}
                    }
                }
            } else |_| {}
        }
        if (old_branch.len == 0) {
            ctx.errorExit("Cannot infer worktree name from the hub root. Please run from inside a worktree or specify the old branch explicitly.", .{});
        }
    } else {
        old_branch = args[0];
        new_branch = args[1];
    }

    const old_wt_dir = try naming.getWtDirName(ctx.arena, old_branch);
    const new_wt_dir = try naming.getWtDirName(ctx.arena, new_branch);

    var old_path: []const u8 = "";
    const worktrees = try git.listWorktrees(ctx, hub_dir);
    for (worktrees) |wt| {
        const b = wt.branch orelse continue;
        if (b.len == 0) continue;
        const rel_wt = if (std.mem.startsWith(u8, wt.path, hub_slash))
            wt.path[hub_slash.len..]
        else
            wt.path;
        const sanitized_b = try naming.getWtDirName(ctx.arena, b);

        if (std.mem.eql(u8, b, old_branch) or
            std.mem.eql(u8, rel_wt, old_branch) or
            std.mem.eql(u8, sanitized_b, old_branch) or
            std.ascii.eqlIgnoreCase(b, old_branch) or
            std.ascii.eqlIgnoreCase(rel_wt, old_branch) or
            std.mem.eql(u8, sanitized_b, old_wt_dir))
        {
            const rel_p = Dir.path.basename(wt.path);
            const cand = try Dir.path.join(ctx.arena, &.{ hub_dir, rel_p });
            if (io_util.dirExists(ctx.io, cand)) {
                old_path = rel_p;
            } else {
                old_path = rel_wt;
            }
            old_branch = b;
            break;
        }
    }

    if (old_path.len == 0) {
        const cand_raw = try Dir.path.join(ctx.arena, &.{ hub_dir, old_branch });
        const cand_wt = try Dir.path.join(ctx.arena, &.{ hub_dir, old_wt_dir });
        if (io_util.dirExists(ctx.io, cand_raw)) {
            old_path = old_branch;
        } else if (io_util.dirExists(ctx.io, cand_wt)) {
            old_path = old_wt_dir;
        } else {
            ctx.errorExit("Worktree '{s}' does not exist.", .{old_branch});
        }
    }

    const new_abs = try Dir.path.join(ctx.arena, &.{ hub_dir, new_wt_dir });
    if (io_util.dirExists(ctx.io, new_abs) and !std.mem.eql(u8, old_path, new_wt_dir)) {
        ctx.errorExit("Target directory '{s}' already exists.", .{new_wt_dir});
    }

    if (!ctx.isAutoYes()) {
        const p_msg = try std.fmt.allocPrint(ctx.arena, "Are you sure you want to move worktree '{s}' to '{s}'? [y/N]: ", .{ old_branch, new_branch });
        if (!prompt.confirm(ctx, p_msg, false, true)) {
            ctx.log("Move cancelled.", .{});
            return;
        }
    }

    ctx.log("Moving worktree and branch from '{s}' to '{s}'...", .{ old_branch, new_branch });

    const old_abs = try Dir.path.join(ctx.arena, &.{ hub_dir, old_path });
    if (!std.mem.eql(u8, old_path, new_wt_dir)) {
        try templates.renameWorktreeDirSafe(ctx, hub_dir, old_abs, new_abs);
    }

    _ = io_util.runQuiet(ctx, &.{ "git", "-C", hub_dir, "worktree", "repair", new_abs }, null);
    try templates.normalizeWorktreeGitdir(ctx, new_abs);

    const br_code = try io_util.runInheritStderr(ctx, &.{ "git", "-C", hub_dir, "branch", "-m", old_branch, new_branch }, hub_dir);
    if (br_code != 0) {
        std.process.exit(br_code);
    }

    const old_db_name = try naming.getDbName(ctx.arena, old_branch);
    const new_db_name = try naming.getDbName(ctx.arena, new_branch);

    var move_db = false;
    if (ctx.isAutoYes()) {
        move_db = true;
    } else {
        const p_msg = try std.fmt.allocPrint(ctx.arena, "Did this branch have an isolated database ({s}) that needs to be moved? [y/N]: ", .{old_db_name});
        move_db = prompt.confirm(ctx, p_msg, false, true);
    }

    if (move_db) {
        if (std.mem.eql(u8, cfg.env_engine, "ddev")) {
            ctx.log("Migrating database from {s} to {s}...", .{ old_db_name, new_db_name });
            try ddev.createDatabase(ctx, hub_dir, new_db_name);
            _ = try ddev.cloneDatabase(ctx, hub_dir, old_db_name, new_db_name);
            try ddev.dropDatabase(ctx, hub_dir, old_db_name, false);
            ctx.log("Database migrated successfully.", .{});
        } else {
            ctx.log("Automated database moving for {s} is not yet implemented.", .{cfg.env_engine});
        }
    }

    ddev.flushEnvSync(ctx, cfg.env_engine, hub_dir);

    ctx.log("Worktree moved to '{s}'.", .{new_wt_dir});
    ctx.out("{s}/{s}", .{ hub_dir, new_wt_dir });
}
