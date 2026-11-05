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
    \\Usage: gar prune [options]
    \\
    \\Prune orphaned worktrees, branches, and isolated databases.
    \\
    \\Options:
    \\  -f, --force     Skip confirmation prompt and prune clean resources
    \\  --dry-run       Show what would be pruned without deleting anything
    \\  --hook          Non-interactive mode for Git hooks (exits if engine offline)
    \\  -h, --help      Show this help message
    \\
;

pub fn run(ctx: *const Context, args: []const []const u8) !void {
    var force = false;
    var dry_run = false;
    var is_hook = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--hook")) {
            is_hook = true;
            force = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            ctx.logRaw(help_text);
            return;
        } else {
            ctx.errorExit("Unknown option: {s}\nUsage: gar prune [-f|--force] [--dry-run]", .{arg});
        }
    }

    const hub_dir = context.requireHubDir(ctx);
    const cfg = try config.ArboristConfig.load(ctx, hub_dir);

    const post_merge_hook = try Dir.path.join(ctx.arena, &.{ hub_dir, ".git", "hooks", "post-merge" });
    if (!io_util.fileExists(ctx.io, post_merge_hook)) {
        templates.installGitHooks(ctx, hub_dir) catch {};
    }

    var ddev_running = false;
    var existing_dbs: []const []const u8 = &.{};
    if (std.mem.eql(u8, cfg.env_engine, "ddev")) {
        const db_q = try ddev.queryDatabases(ctx, hub_dir, true);
        ddev_running = db_q.running;
        existing_dbs = db_q.dbs;
    }

    if (is_hook and std.mem.eql(u8, cfg.env_engine, "ddev") and !ddev_running) {
        return;
    }

    var prune_wts: std.ArrayList([]const u8) = .empty;
    var prune_branches: std.ArrayList([]const u8) = .empty;
    var prune_dbs: std.ArrayList([]const u8) = .empty;
    var dirty_wts: std.ArrayList([]const u8) = .empty;
    var active_wts: std.ArrayList([]const u8) = .empty;

    const worktrees = try git.listWorktrees(ctx, hub_dir);

    var all_heads: std.ArrayList([]const u8) = .empty;
    var all_tracks: std.ArrayList([]const u8) = .empty;

    if (io_util.runCapture(ctx, &.{ "git", "-C", hub_dir, "for-each-ref", "--format=%(refname:short)|%(upstream:track)", "refs/heads" }, null)) |res| {
        if (res.success()) {
            var lines = std.mem.splitScalar(u8, res.stdout, '\n');
            while (lines.next()) |raw_line| {
                const line = std.mem.trimEnd(u8, raw_line, "\r");
                if (line.len == 0) continue;
                if (std.mem.indexOfScalar(u8, line, '|')) |sep_idx| {
                    const bname = line[0..sep_idx];
                    const btrack = line[sep_idx + 1 ..];
                    if (bname.len > 0) {
                        try all_heads.append(ctx.arena, try ctx.arena.dupe(u8, bname));
                        try all_tracks.append(ctx.arena, try ctx.arena.dupe(u8, btrack));
                    }
                }
            }
        }
    } else |_| {}

    for (all_heads.items, 0..) |b, idx| {
        const tr = all_tracks.items[idx];
        if (std.mem.eql(u8, tr, "[gone]") and !naming.isInCommaList(b, cfg.protected_branches)) {
            var found_wt: []const u8 = "";
            for (worktrees) |wt| {
                if (wt.is_bare) continue;
                const wt_b = wt.branch orelse continue;
                if (std.mem.eql(u8, wt_b, b)) {
                    found_wt = wt.path;
                    break;
                }
            }

            var skip_branch = false;
            if (found_wt.len > 0 and io_util.dirExists(ctx.io, found_wt)) {
                const found_wt_slash = try std.fmt.allocPrint(ctx.arena, "{s}/", .{found_wt});
                if (std.mem.eql(u8, ctx.invocation_dir, found_wt) or
                    std.mem.startsWith(u8, ctx.invocation_dir, found_wt_slash))
                {
                    try active_wts.append(ctx.arena, b);
                    skip_branch = true;
                } else if (isWorktreeDirtyExcludingInjected(ctx, found_wt)) {
                    try dirty_wts.append(ctx.arena, b);
                    skip_branch = true;
                } else {
                    try prune_wts.append(ctx.arena, found_wt);
                }
            }

            if (!skip_branch) {
                try prune_branches.append(ctx.arena, b);
                const db_name = try naming.getDbName(ctx.arena, b);
                if (ddev_running) {
                    for (existing_dbs) |edb| {
                        if (std.ascii.eqlIgnoreCase(edb, db_name)) {
                            try prune_dbs.append(ctx.arena, edb);
                        }
                    }
                }
            }
        }
    }

    if (ddev_running) {
        for (existing_dbs) |db| {
            if (std.mem.eql(u8, db, "db")) continue;

            var already_queued = false;
            for (prune_dbs.items) |qd| {
                if (std.mem.eql(u8, qd, db)) {
                    already_queued = true;
                    break;
                }
            }
            if (already_queued) continue;

            var has_branch = false;
            for (all_heads.items) |b| {
                const b_db = try naming.getDbName(ctx.arena, b);
                if (std.ascii.eqlIgnoreCase(b_db, db)) {
                    has_branch = true;
                    break;
                }
            }

            if (!has_branch) {
                var is_prot = false;
                var pb_it = std.mem.tokenizeAny(u8, cfg.protected_branches, ", ");
                while (pb_it.next()) |pb| {
                    const pb_db = try naming.getDbName(ctx.arena, pb);
                    if (std.ascii.eqlIgnoreCase(pb_db, db)) {
                        is_prot = true;
                        break;
                    }
                }
                if (!is_prot) {
                    try prune_dbs.append(ctx.arena, db);
                }
            }
        }
    }

    for (dirty_wts.items) |b_name| {
        ctx.log("\x1b[33m⚠️  Skipping dirty worktree '{s}' (has uncommitted changes). Clean or commit before pruning.\x1b[0m", .{b_name});
    }
    for (active_wts.items) |b_name| {
        ctx.log("\x1b[33m⚠️  Skipping active worktree '{s}' (currently in use).\x1b[0m", .{b_name});
    }

    const total_targets = prune_wts.items.len + prune_branches.items.len + prune_dbs.items.len;
    if (total_targets == 0) {
        if (!is_hook) {
            ctx.log("No orphaned worktrees or databases found. Everything is in sync.", .{});
        }
        return;
    }

    ctx.log("The following orphaned resources were found:", .{});
    for (prune_wts.items) |wt| {
        ctx.log("  • Worktree: ./{s}", .{Dir.path.basename(wt)});
    }
    for (prune_branches.items) |b| {
        ctx.log("  • Branch:   {s} (remote [gone])", .{b});
    }
    for (prune_dbs.items) |db| {
        ctx.log("  • Database: {s}", .{db});
    }
    ctx.log("", .{});

    if (dry_run) {
        ctx.log("Dry-run mode: No resources were removed.", .{});
        return;
    }

    if (!force) {
        if (!ctx.isAutoYes()) {
            if (!prompt.confirm(ctx, "Prune these orphaned resources? [y/N]: ", false, true)) {
                ctx.log("Pruning cancelled.", .{});
                return;
            }
        }
    }

    var count_wts: usize = 0;
    var count_branches: usize = 0;
    var count_dbs: usize = 0;

    if (std.mem.eql(u8, cfg.prune_targets, "both") or std.mem.eql(u8, cfg.prune_targets, "worktree")) {
        for (prune_wts.items) |wt| {
            ctx.log("Removing worktree {s}...", .{Dir.path.basename(wt)});
            if (!io_util.runQuiet(ctx, &.{ "git", "-C", hub_dir, "worktree", "remove", "--force", wt }, hub_dir)) {
                Dir.cwd().deleteTree(ctx.io, wt) catch {};
            }
            count_wts += 1;
        }
        for (prune_branches.items) |b| {
            ctx.log("Deleting branch {s}...", .{b});
            _ = io_util.runQuiet(ctx, &.{ "git", "-C", hub_dir, "branch", "-D", b }, hub_dir);
            count_branches += 1;
        }
        _ = io_util.runQuiet(ctx, &.{ "git", "-C", hub_dir, "worktree", "prune" }, hub_dir);
    }

    if (std.mem.eql(u8, cfg.prune_targets, "both") or std.mem.eql(u8, cfg.prune_targets, "db")) {
        if (std.mem.eql(u8, cfg.env_engine, "ddev") and ddev_running) {
            for (prune_dbs.items) |db| {
                ctx.log("Dropping database {s}...", .{db});
                try ddev.dropDatabase(ctx, hub_dir, db, true);
                count_dbs += 1;
            }
        }
    }

    ctx.log("✅ Pruning complete: removed {d} worktree(s), deleted {d} branch(es), dropped {d} database(s).", .{ count_wts, count_branches, count_dbs });
}

fn isWorktreeDirtyExcludingInjected(ctx: *const Context, wt_path: []const u8) bool {
    const res = io_util.runCapture(ctx, &.{ "git", "-C", wt_path, "status", "--porcelain" }, null) catch return false;
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "settings.workspace.php") != null or
            std.mem.indexOf(u8, line, "settings.local.php") != null or
            std.mem.indexOf(u8, line, "settings.ddev.php") != null or
            std.mem.indexOf(u8, line, "development.services.yml") != null)
        {
            continue;
        }
        return true;
    }
    return false;
}
