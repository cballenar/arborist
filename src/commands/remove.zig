const std = @import("std");
const Dir = std.Io.Dir;
const io_util = @import("../io_util.zig");
const Context = io_util.Context;
const config = @import("../config.zig");
const context = @import("../context.zig");
const git = @import("../git.zig");
const naming = @import("../naming.zig");
const prompt = @import("../prompt.zig");
const ddev = @import("../engine/ddev.zig");

const help_text =
    \\Usage: gar remove [options] <branch>
    \\
    \\Remove a worktree, branch, and drop isolated database.
    \\
    \\Options:
    \\  -f, --force, -y    Skip confirmation prompt and drop isolated database
    \\  -h, --help         Show this help message
    \\
;

pub fn run(ctx: *const Context, args: []const []const u8) !void {
    var force = false;
    var target: []const u8 = "";

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-y")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            ctx.logRaw(help_text);
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            ctx.errorExit("Unknown option: {s}\nUsage: gar remove [-f|--force] <branch>", .{arg});
        } else {
            if (target.len == 0) {
                target = arg;
            }
        }
    }

    if (target.len == 0) {
        ctx.errorExit("Usage: gar remove [-f|--force] <branch>", .{});
    }

    const hub_dir = context.requireHubDir(ctx);
    const cfg = try config.ArboristConfig.load(ctx, hub_dir);

    const target_wt_dir = try naming.getWtDirName(ctx.arena, target);
    var wt_to_remove: []const u8 = "";
    var branch_to_remove: []const u8 = "";

    const hub_slash = try std.fmt.allocPrint(ctx.arena, "{s}/", .{hub_dir});
    const hub_target = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ hub_dir, target });
    const hub_target_wt = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ hub_dir, target_wt_dir });

    const worktrees = try git.listWorktrees(ctx, hub_dir);
    for (worktrees) |wt| {
        const b = wt.branch orelse continue;
        if (b.len == 0) continue;
        const rel_wt = if (std.mem.startsWith(u8, wt.path, hub_slash))
            wt.path[hub_slash.len..]
        else
            wt.path;
        const sanitized_b = try naming.getWtDirName(ctx.arena, b);

        if (std.mem.eql(u8, b, target) or
            std.mem.eql(u8, rel_wt, target) or
            std.mem.eql(u8, sanitized_b, target) or
            std.mem.eql(u8, wt.path, target) or
            std.mem.eql(u8, wt.path, hub_target) or
            std.mem.eql(u8, wt.path, hub_target_wt) or
            std.ascii.eqlIgnoreCase(b, target) or
            std.ascii.eqlIgnoreCase(rel_wt, target) or
            std.mem.eql(u8, sanitized_b, target_wt_dir))
        {
            wt_to_remove = wt.path;
            branch_to_remove = b;
            break;
        }
    }

    if (wt_to_remove.len == 0) {
        if (io_util.dirExists(ctx.io, hub_target_wt)) {
            wt_to_remove = hub_target_wt;
            branch_to_remove = target;
        } else if (io_util.dirExists(ctx.io, hub_target)) {
            wt_to_remove = hub_target;
            branch_to_remove = target;
        } else {
            ctx.errorExit("Worktree '{s}' not found in {s}.", .{ target, hub_dir });
        }
    } else {
        const rel_p = Dir.path.basename(wt_to_remove);
        const cand = try Dir.path.join(ctx.arena, &.{ hub_dir, rel_p });
        if (io_util.dirExists(ctx.io, cand)) {
            wt_to_remove = cand;
        }
    }

    if (std.mem.eql(u8, branch_to_remove, cfg.default_branch) or
        naming.isInCommaList(branch_to_remove, cfg.protected_branches))
    {
        ctx.errorExit("Cannot remove protected branch '{s}'.", .{branch_to_remove});
    }

    const display_name = if (std.mem.startsWith(u8, wt_to_remove, hub_slash))
        wt_to_remove[hub_slash.len..]
    else
        wt_to_remove;

    var safety_warnings: std.ArrayList([]const u8) = .empty;

    if (io_util.dirExists(ctx.io, wt_to_remove)) {
        if (io_util.runCapture(ctx, &.{ "git", "-C", wt_to_remove, "status", "--porcelain" }, hub_dir)) |res| {
            const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
            if (trimmed.len > 0) {
                const msg = try std.fmt.allocPrint(ctx.arena, "Worktree '{s}' has uncommitted changes.", .{display_name});
                try safety_warnings.append(ctx.arena, msg);
            }
        } else |_| {}
    }

    const head_ref = try std.fmt.allocPrint(ctx.arena, "refs/heads/{s}", .{branch_to_remove});
    if (git.showRefVerify(ctx, hub_dir, head_ref)) {
        var upstream_ref: []const u8 = "";
        var upstream_track: []const u8 = "";

        if (io_util.runCapture(ctx, &.{ "git", "-C", hub_dir, "for-each-ref", "--format=%(upstream:short)", head_ref }, null)) |res| {
            if (res.success()) upstream_ref = std.mem.trim(u8, res.stdout, " \t\r\n");
        } else |_| {}

        if (io_util.runCapture(ctx, &.{ "git", "-C", hub_dir, "for-each-ref", "--format=%(upstream:track)", head_ref }, null)) |res| {
            if (res.success()) upstream_track = std.mem.trim(u8, res.stdout, " \t\r\n");
        } else |_| {}

        var remote_compare_ref: []const u8 = "";
        if (upstream_ref.len > 0 and !std.mem.eql(u8, upstream_track, "[gone]")) {
            const cand_ref = try std.fmt.allocPrint(ctx.arena, "refs/remotes/{s}", .{upstream_ref});
            if (git.showRefVerify(ctx, hub_dir, cand_ref)) {
                remote_compare_ref = cand_ref;
            }
        }
        if (remote_compare_ref.len == 0) {
            const origin_ref = try std.fmt.allocPrint(ctx.arena, "refs/remotes/origin/{s}", .{branch_to_remove});
            if (git.showRefVerify(ctx, hub_dir, origin_ref)) {
                remote_compare_ref = origin_ref;
            }
        }

        if (remote_compare_ref.len == 0) {
            if (!std.mem.eql(u8, upstream_track, "[gone]")) {
                const msg = try std.fmt.allocPrint(ctx.arena, "Branch '{s}' only exists locally (never pushed to remote).", .{branch_to_remove});
                try safety_warnings.append(ctx.arena, msg);
            }
        } else {
            const range = try std.fmt.allocPrint(ctx.arena, "{s}..{s}", .{ remote_compare_ref, head_ref });
            var ahead_count: usize = 0;
            if (io_util.runCapture(ctx, &.{ "git", "-C", hub_dir, "rev-list", "--count", range }, null)) |res| {
                if (res.success()) {
                    const count_str = std.mem.trim(u8, res.stdout, " \t\r\n");
                    ahead_count = std.fmt.parseInt(usize, count_str, 10) catch 0;
                }
            } else |_| {}

            if (ahead_count > 0) {
                const msg = try std.fmt.allocPrint(ctx.arena, "Branch '{s}' has {d} unpushed commit(s).", .{ branch_to_remove, ahead_count });
                try safety_warnings.append(ctx.arena, msg);
            }
        }
    }

    if (safety_warnings.items.len > 0 and !force and !ctx.isAutoYes()) {
        for (safety_warnings.items) |warn_msg| {
            ctx.log("⚠️  Warning: {s}", .{warn_msg});
        }
        const confirmed = prompt.confirm(
            ctx,
            "Are you sure you want to permanently delete this worktree and local branch? [y/N]: ",
            false,
            true,
        );
        if (!confirmed) {
            ctx.log("Removal cancelled.", .{});
            return;
        }
    }

    const db_name = try naming.getDbName(ctx.arena, branch_to_remove);
    var drop_db = false;

    if (force or ctx.isAutoYes()) {
        drop_db = true;
        if (!force and ctx.isAutoYes()) {
            ctx.log("Auto-confirming database drop for tests.", .{});
        }
    } else {
        const p_msg = try std.fmt.allocPrint(ctx.arena, "Drop the isolated database ({s}) if it exists? [Y/n]: ", .{db_name});
        drop_db = prompt.confirm(ctx, p_msg, true, true);
    }

    ctx.log("Removing worktree '{s}'...", .{display_name});
    const rm_code = try io_util.runInheritStderr(ctx, &.{ "git", "worktree", "remove", "--force", wt_to_remove }, hub_dir);
    if (rm_code != 0) {
        std.process.exit(rm_code);
    }
    _ = io_util.runQuiet(ctx, &.{ "git", "branch", "-D", branch_to_remove }, hub_dir);

    var parent_opt = Dir.path.dirname(wt_to_remove);
    while (parent_opt) |p| {
        if (std.mem.eql(u8, p, hub_dir) or std.mem.eql(u8, p, "/")) break;
        Dir.cwd().deleteDir(ctx.io, p) catch break;
        parent_opt = Dir.path.dirname(p);
    }

    if (drop_db) {
        if (std.mem.eql(u8, cfg.env_engine, "ddev")) {
            ctx.log("Dropping database {s}...", .{db_name});
            try ddev.dropDatabase(ctx, hub_dir, db_name, true);
            const legacy_db = try naming.getLegacyDbName(ctx.arena, branch_to_remove);
            if (!std.mem.eql(u8, legacy_db, db_name)) {
                try ddev.dropDatabase(ctx, hub_dir, legacy_db, true);
            }
        } else {
            ctx.log("Automated database dropping for {s} is not yet implemented.", .{cfg.env_engine});
        }
    }

    ctx.log("Worktree '{s}' dropped.", .{display_name});
}
