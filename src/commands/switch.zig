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
    \\Usage: gar switch [options] [branch]
    \\
    \\Switch to a worktree, checkout remote branch, or create a new branch.
    \\
    \\Options:
    \\  -c                 Create and checkout a new branch/worktree
    \\  -y, --yes          Accept default prompts automatically
    \\  --clone            Clone default database instead of importing backup
    \\  --backup           Import latest backup dump instead of cloning DB
    \\  -h, --help         Show this help message
    \\
;

pub fn run(ctx: *const Context, args: []const []const u8) !void {
    var create_flag = false;
    var auto_yes = false;
    var branch: []const u8 = "";
    var strategy_override: []const u8 = "";

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) {
            ctx.logRaw(help_text);
            return;
        } else if (std.mem.eql(u8, arg, "-c")) {
            create_flag = true;
        } else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
            auto_yes = true;
        } else if (std.mem.eql(u8, arg, "--clone")) {
            strategy_override = "clone";
        } else if (std.mem.eql(u8, arg, "--backup")) {
            strategy_override = "backup";
        } else if (std.mem.startsWith(u8, arg, "-")) {
            ctx.errorExit("Unknown option for switch: {s}\nUsage: gar switch [-c] [-y|--yes] [--clone|--backup] [branch]", .{arg});
        } else {
            if (branch.len == 0) {
                branch = arg;
            }
        }
    }

    const hub_dir = context.requireHubDir(ctx);
    const cfg = try config.ArboristConfig.load(ctx, hub_dir);

    const worktrees = try git.listWorktrees(ctx, hub_dir);

    // 1. No branch argument: interactive selection or fallback to DEFAULT_BRANCH
    if (branch.len == 0) {
        var wt_list: std.ArrayList([]const u8) = .empty;
        for (worktrees) |wt| {
            if (wt.branch) |b| {
                if (b.len > 0) try wt_list.append(ctx.arena, b);
            }
        }

        if (wt_list.items.len <= 1 or ctx.isAutoYes() or !prompt.isStdinTty(ctx)) {
            branch = cfg.default_branch;
        } else {
            ctx.log("Select a worktree to switch to:", .{});
            for (wt_list.items, 0..) |wt_b, idx| {
                if (std.mem.eql(u8, wt_b, cfg.default_branch)) {
                    ctx.log("  {d}) {s} (tracking)", .{ idx + 1, wt_b });
                } else {
                    ctx.log("  {d}) {s}", .{ idx + 1, wt_b });
                }
            }
            const p_msg = try std.fmt.allocPrint(ctx.arena, "Select worktree [1-{d}] (default: 1): ", .{wt_list.items.len});
            const resp_opt = prompt.readLine(ctx, p_msg, true);
            const choice_str = if (resp_opt) |r| std.mem.trim(u8, r, " \t\r\n") else "";
            const eff_str = if (choice_str.len == 0) "1" else choice_str;
            const choice = std.fmt.parseInt(usize, eff_str, 10) catch 0;
            if (choice >= 1 and choice <= wt_list.items.len) {
                branch = wt_list.items[choice - 1];
            } else {
                ctx.errorExit("Invalid selection: {s}", .{eff_str});
            }
        }
    }

    const target_wt_dir = try naming.getWtDirName(ctx.arena, branch);
    const norm_branch = try naming.toLowerAlloc(ctx.arena, branch);

    // 2. Existing worktree directory or branch already checked out: switch into it
    var existing_wt: []const u8 = "";
    for (worktrees) |wt| {
        const parsed_branch = wt.branch orelse continue;
        if (parsed_branch.len == 0) continue;
        const parsed_dir_name = try naming.getWtDirName(ctx.arena, parsed_branch);
        const rel_p = Dir.path.basename(wt.path);

        if (std.mem.eql(u8, parsed_branch, branch) or
            std.mem.eql(u8, parsed_dir_name, branch) or
            std.mem.eql(u8, rel_p, branch) or
            std.ascii.eqlIgnoreCase(parsed_branch, branch) or
            std.mem.eql(u8, parsed_dir_name, norm_branch) or
            std.mem.eql(u8, parsed_dir_name, target_wt_dir) or
            std.ascii.eqlIgnoreCase(rel_p, branch))
        {
            const cand = try Dir.path.join(ctx.arena, &.{ hub_dir, rel_p });
            if (io_util.dirExists(ctx.io, cand)) {
                existing_wt = cand;
            } else {
                existing_wt = wt.path;
            }
            branch = parsed_branch;
            break;
        }
    }

    if (existing_wt.len == 0) {
        const cand_wt = try Dir.path.join(ctx.arena, &.{ hub_dir, target_wt_dir });
        const cand_raw = try Dir.path.join(ctx.arena, &.{ hub_dir, branch });
        if (io_util.dirExists(ctx.io, cand_wt)) {
            existing_wt = cand_wt;
        } else if (io_util.dirExists(ctx.io, cand_raw)) {
            existing_wt = cand_raw;
        }
    }

    if (existing_wt.len > 0 and io_util.dirExists(ctx.io, existing_wt)) {
        const cur_dir_name = Dir.path.basename(existing_wt);
        const norm_dir_name = try naming.getWtDirName(ctx.arena, branch);
        if (!std.mem.eql(u8, cur_dir_name, norm_dir_name)) {
            ctx.log("Normalizing worktree directory from '{s}' to '{s}'...", .{ cur_dir_name, norm_dir_name });
            const norm_abs = try Dir.path.join(ctx.arena, &.{ hub_dir, norm_dir_name });
            try templates.renameWorktreeDirSafe(ctx, hub_dir, existing_wt, norm_abs);
            existing_wt = norm_abs;
            ddev.flushEnvSync(ctx, cfg.env_engine, hub_dir);
        }
        try templates.normalizeWorktreeGitdir(ctx, existing_wt);
        if (std.mem.eql(u8, cfg.framework, "drupal")) {
            try templates.provisionDrupalWorktree(ctx, hub_dir, existing_wt, cfg);
        }
        const hub_slash = try std.fmt.allocPrint(ctx.arena, "{s}/", .{hub_dir});
        const rel_part = if (std.mem.startsWith(u8, existing_wt, hub_slash))
            existing_wt[hub_slash.len..]
        else
            existing_wt;
        ctx.log("Switched to worktree './{s}'.", .{rel_part});
        ctx.out("{s}", .{existing_wt});
        return;
    }

    // 3. Worktree does not exist yet: determine whether local, remote, or brand new
    var has_local_branch = git.showRefVerify(ctx, hub_dir, try std.fmt.allocPrint(ctx.arena, "refs/heads/{s}", .{branch}));
    var has_remote_branch = git.showRefVerify(ctx, hub_dir, try std.fmt.allocPrint(ctx.arena, "refs/remotes/origin/{s}", .{branch}));

    if (!create_flag and !has_local_branch and !has_remote_branch) {
        const norm_req = try naming.getWtDirName(ctx.arena, branch);

        const local_branches = try git.listLocalBranches(ctx, hub_dir);
        for (local_branches) |ref_b| {
            const bname = ref_b.name;
            if (bname.len == 0) continue;
            const norm_ref = try naming.getWtDirName(ctx.arena, bname);
            if (std.mem.eql(u8, bname, branch) or
                std.mem.eql(u8, norm_ref, norm_req) or
                std.ascii.eqlIgnoreCase(bname, branch))
            {
                branch = bname;
                has_local_branch = true;
                break;
            }
        }

        if (!has_local_branch) {
            const rem_branches = try git.listRemoteOriginBranches(ctx, hub_dir);
            for (rem_branches) |rem_b| {
                if (rem_b.len == 0) continue;
                const norm_rem = try naming.getWtDirName(ctx.arena, rem_b);
                if (std.mem.eql(u8, rem_b, branch) or
                    std.mem.eql(u8, norm_rem, norm_req) or
                    std.ascii.eqlIgnoreCase(rem_b, branch))
                {
                    branch = rem_b;
                    has_remote_branch = true;
                    break;
                }
            }
        }

        if (!has_local_branch and !has_remote_branch) {
            ctx.log("Branch '{s}' not found in local cache. Fetching from origin...", .{branch});
            _ = io_util.runQuiet(ctx, &.{ "git", "-C", hub_dir, "fetch", "origin", "--quiet" }, hub_dir);
            if (git.showRefVerify(ctx, hub_dir, try std.fmt.allocPrint(ctx.arena, "refs/remotes/origin/{s}", .{branch}))) {
                has_remote_branch = true;
            } else {
                const rem_branches = try git.listRemoteOriginBranches(ctx, hub_dir);
                for (rem_branches) |rem_b| {
                    if (rem_b.len == 0) continue;
                    const norm_rem = try naming.getWtDirName(ctx.arena, rem_b);
                    if (std.mem.eql(u8, rem_b, branch) or
                        std.mem.eql(u8, norm_rem, norm_req) or
                        std.ascii.eqlIgnoreCase(rem_b, branch))
                    {
                        branch = rem_b;
                        has_remote_branch = true;
                        break;
                    }
                }
            }
        }
    }

    const wt_dir_name = try naming.getWtDirName(ctx.arena, branch);
    const wt_abs = try Dir.path.join(ctx.arena, &.{ hub_dir, wt_dir_name });

    if (create_flag) {
        ctx.log("Creating new worktree and branch for '{s}'...", .{branch});
        const code = try io_util.runInheritStderr(ctx, &.{ "git", "-C", hub_dir, "worktree", "add", wt_dir_name, "-b", branch }, hub_dir);
        if (code != 0) std.process.exit(code);
    } else if (has_local_branch) {
        ctx.log("Checking out existing branch into worktree '{s}'...", .{wt_dir_name});
        const code = try io_util.runInheritStderr(ctx, &.{ "git", "-C", hub_dir, "worktree", "add", wt_dir_name, branch }, hub_dir);
        if (code != 0) std.process.exit(code);
    } else if (has_remote_branch) {
        ctx.log("Found remote branch 'origin/{s}'. Checking out tracking worktree...", .{branch});
        const origin_b = try std.fmt.allocPrint(ctx.arena, "origin/{s}", .{branch});
        const code = try io_util.runInheritStderr(ctx, &.{ "git", "-C", hub_dir, "worktree", "add", wt_dir_name, "--track", "-b", branch, origin_b }, hub_dir);
        if (code != 0) std.process.exit(code);
    } else {
        if (!ctx.isAutoYes() and !auto_yes and prompt.isStdinTty(ctx)) {
            const p_msg = try std.fmt.allocPrint(ctx.arena, "Branch '{s}' not found locally or on remote. Create it now? [Y/n]: ", .{branch});
            if (prompt.confirm(ctx, p_msg, true, true)) {
                ctx.log("Creating new worktree and branch for '{s}'...", .{branch});
                const code = try io_util.runInheritStderr(ctx, &.{ "git", "-C", hub_dir, "worktree", "add", wt_dir_name, "-b", branch }, hub_dir);
                if (code != 0) std.process.exit(code);
            } else {
                ctx.log("Switch cancelled.", .{});
                return;
            }
        } else if (ctx.isAutoYes() or auto_yes) {
            ctx.log("Creating new worktree and branch for '{s}'...", .{branch});
            const code = try io_util.runInheritStderr(ctx, &.{ "git", "-C", hub_dir, "worktree", "add", wt_dir_name, "-b", branch }, hub_dir);
            if (code != 0) std.process.exit(code);
        } else {
            ctx.errorExit("Branch '{s}' not found. Use 'gar switch -c {s}' to create it.", .{ branch, branch });
        }
    }

    // Apply sparse-checkout and provision environment
    var sparse_argv: std.ArrayList([]const u8) = .empty;
    try sparse_argv.appendSlice(ctx.arena, &.{ "git", "-C", wt_abs, "sparse-checkout", "set", "--no-cone", "/*" });
    var sp_it = std.mem.tokenizeAny(u8, cfg.sparse_excludes, " \t\r\n");
    while (sp_it.next()) |tok| {
        try sparse_argv.append(ctx.arena, tok);
    }
    const sp_code = try io_util.runInheritStderr(ctx, sparse_argv.items, wt_abs);
    if (sp_code != 0) std.process.exit(sp_code);

    try templates.normalizeWorktreeGitdir(ctx, wt_abs);

    if (std.mem.eql(u8, cfg.framework, "drupal")) {
        try templates.provisionDrupalWorktree(ctx, hub_dir, wt_abs, cfg);
    }

    ddev.flushEnvSync(ctx, cfg.env_engine, hub_dir);

    ctx.log("Worktree provisioned.", .{});

    // Database handling for new worktree
    const db_name = try naming.getDbName(ctx.arena, branch);
    var db_exists = false;
    var legacy_db: []const u8 = "";

    if (std.mem.eql(u8, cfg.env_engine, "ddev")) {
        if (ctx.env("GAR_MOCK_DBS")) |mock_dbs| {
            if (mock_dbs.len > 0) {
                db_exists = naming.isInSpaceListCi(db_name, mock_dbs);
            }
        } else if (ddev.isRunning(ctx, hub_dir)) {
            const db_q = try ddev.queryDatabases(ctx, hub_dir, false);
            for (db_q.dbs) |edb| {
                if (std.mem.eql(u8, edb, db_name)) {
                    db_exists = true;
                    break;
                }
            }
            if (!db_exists) {
                for (db_q.dbs) |edb| {
                    if (std.ascii.eqlIgnoreCase(edb, db_name)) {
                        legacy_db = edb;
                        break;
                    }
                }
            }
        }
    }

    if (legacy_db.len > 0 and !std.mem.eql(u8, legacy_db, db_name)) {
        ctx.log("Migrating legacy capitalized database '{s}' to '{s}'...", .{ legacy_db, db_name });
        try ddev.createDatabase(ctx, hub_dir, db_name);
        _ = try ddev.cloneDatabase(ctx, hub_dir, legacy_db, db_name);
        try ddev.dropDatabase(ctx, hub_dir, legacy_db, false);
        db_exists = true;
    }

    var run_post_provision = false;
    if (db_exists) {
        ctx.log("Found existing isolated database '{s}'. Using it.", .{db_name});
        run_post_provision = true;
    } else {
        var create_db = false;
        if (ctx.isAutoYes() or auto_yes or strategy_override.len > 0) {
            create_db = true;
            if (ctx.isAutoYes()) {
                ctx.log("Auto-confirming database creation for tests.", .{});
            }
        } else if (prompt.isStdinTty(ctx)) {
            const timeout_str = ctx.envOrDefault("GAR_DB_PROMPT_TIMEOUT", "10");
            const timeout_secs = std.fmt.parseInt(u32, timeout_str, 10) catch 10;
            const p_msg = try std.fmt.allocPrint(ctx.arena, "Create an isolated database for this branch? ({s}s timeout) [y/N]: ", .{timeout_str});
            const res = prompt.confirmWithTimeout(ctx, p_msg, timeout_secs, false);
            if (res.timed_out) {
                ctx.log("No response within {s}s; defaulting to No.", .{timeout_str});
            }
            create_db = res.confirmed;
        }

        if (create_db) {
            run_post_provision = true;
            if (std.mem.eql(u8, cfg.env_engine, "ddev")) {
                try ddev.createDatabase(ctx, hub_dir, db_name);
                const provision_strategy = if (strategy_override.len > 0)
                    strategy_override
                else if (cfg.db_provision_strategy.len > 0)
                    cfg.db_provision_strategy
                else
                    "backup";

                if (std.mem.eql(u8, provision_strategy, "clone")) {
                    ctx.log("Cloning default database into {s}...", .{db_name});
                    const code = try ddev.cloneDatabase(ctx, hub_dir, "db", db_name);
                    if (code != 0) std.process.exit(code);
                    ctx.log("Isolated database {s} ready.", .{db_name});
                } else {
                    if (ddev.getLatestBackupFile(ctx, hub_dir, cfg.db_backup_path)) |backup_file| {
                        ctx.log("Importing backup dump into {s}...", .{db_name});
                        ctx.log("Source: {s}", .{backup_file});
                        const code = try ddev.importDb(ctx, hub_dir, db_name, backup_file);
                        if (code != 0) std.process.exit(code);
                        ctx.log("Isolated database {s} ready.", .{db_name});
                    } else {
                        const disp = if (cfg.db_backup_path.len > 0) cfg.db_backup_path else "backups";
                        ctx.log("No database backup dump found in '{s}'. Falling back to cloning default database...", .{disp});
                        const code = try ddev.cloneDatabase(ctx, hub_dir, "db", db_name);
                        if (code != 0) std.process.exit(code);
                        ctx.log("Isolated database {s} ready.", .{db_name});
                    }
                }
            } else {
                ctx.log("Automated database cloning for {s} is not yet implemented.", .{cfg.env_engine});
            }
        } else {
            ctx.log("Using default shared database. Run 'gar db provision' (or 'gar dbp') anytime to provision an isolated database.", .{});
        }
    }

    if (run_post_provision and cfg.post_provision_cmd.len > 0) {
        ddev.flushEnvSync(ctx, cfg.env_engine, hub_dir);
        ctx.log("Running post-provision commands in '{s}'...", .{wt_dir_name});
        const code = try io_util.runShellCommand(ctx, cfg.post_provision_cmd, wt_abs);
        if (code != 0) {
            ctx.log("\x1b[31mError:\x1b[0m Post-provision command failed with exit code {d}. Aborted remaining commands.", .{code});
        }
    }

    ctx.out("{s}/{s}", .{ hub_dir, wt_dir_name });
}
