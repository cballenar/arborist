const std = @import("std");
const Dir = std.Io.Dir;
const io_util = @import("../io_util.zig");
const Context = io_util.Context;
const config = @import("../config.zig");
const context = @import("../context.zig");
const git = @import("../git.zig");
const naming = @import("../naming.zig");
const ddev = @import("../engine/ddev.zig");

const db_help_text =
    \\Usage:
    \\  gar db <action> [options]
    \\  gar dbi [options]
    \\  gar dbe [options]
    \\  gar dbp [options]
    \\
    \\Actions:
    \\  import [--file <path>] [--target <branch>]                          Import SQL dump into database (alias: gar dbi)
    \\  export [--file <path>] [--target <branch>]                          Export database to SQL dump (alias: gar dbe)
    \\  provision [--clone|--backup] [--file <path>] [--target <branch>]    Provision database and run post-provision commands (alias: gar dbp)
    \\
    \\Options:
    \\  --file <path>       Path to SQL dump (relative to current directory)
    \\  --target <branch>   Target branch/database (defaults to current worktree or tracking branch)
    \\  --clone             Clone running default database (db) instead of importing backup
    \\  --backup            Import latest backup dump from DB_BACKUP_PATH
    \\  --skip-db           Skip database import/clone and only run post-provision commands
    \\
;

const import_help_text =
    \\Usage: gar db import [--file <path>] [--target <branch>]
    \\Alias: gar dbi [--file <path>] [--target <branch>]
    \\
    \\Options:
    \\  --file <path>       Path to SQL dump (relative to current working directory).
    \\                      If omitted, imports the latest dump from DB_BACKUP_PATH.
    \\  --target <branch>   Target branch/database (defaults to current worktree or tracking branch).
    \\
;

const export_help_text =
    \\Usage: gar db export [--file <path>] [--target <branch>]
    \\Alias: gar dbe [--file <path>] [--target <branch>]
    \\
    \\Options:
    \\  --file <path>       Destination path for SQL dump (relative to current working directory).
    \\                      If omitted, saves a timestamped dump into DB_BACKUP_PATH.
    \\  --target <branch>   Target branch/database to export (defaults to current worktree or tracking branch).
    \\
;

const provision_help_text =
    \\Usage: gar db provision [--clone|--backup] [--file <path>] [--target <branch>] [--skip-db]
    \\Alias: gar dbp [--clone|--backup] [--file <path>] [--target <branch>] [--skip-db]
    \\
    \\Options:
    \\  --clone             Clone the running default database (db) into the target database.
    \\  --backup            Import the latest dump from DB_BACKUP_PATH into the target database.
    \\  --file <path>       Import a specific SQL dump (relative to current working directory).
    \\  --target <branch>   Target branch/worktree (defaults to current worktree or tracking branch).
    \\  --skip-db           Skip database import/clone and only execute post-provision commands.
    \\
;

pub fn run(ctx: *const Context, args: []const []const u8) !void {
    const action = if (args.len > 0) args[0] else "";
    if (action.len == 0 or
        std.mem.eql(u8, action, "-h") or
        std.mem.eql(u8, action, "--help") or
        std.mem.eql(u8, action, "help"))
    {
        ctx.logRaw(db_help_text);
        return;
    }

    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};
    try runAction(ctx, action, sub_args);
}

pub fn runAction(ctx: *const Context, action: []const u8, args: []const []const u8) !void {
    var file_arg: []const u8 = "";
    var target_arg: []const u8 = "";
    var strategy_override: []const u8 = "";
    var skip_db = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--file")) {
            if (i + 1 < args.len) {
                file_arg = args[i + 1];
                i += 1;
            }
        } else if (std.mem.startsWith(u8, arg, "--file=")) {
            file_arg = arg["--file=".len..];
        } else if (std.mem.eql(u8, arg, "--target")) {
            if (i + 1 < args.len) {
                target_arg = args[i + 1];
                i += 1;
            }
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            target_arg = arg["--target=".len..];
        } else if (std.mem.eql(u8, arg, "--clone")) {
            strategy_override = "clone";
        } else if (std.mem.eql(u8, arg, "--backup")) {
            strategy_override = "backup";
        } else if (std.mem.eql(u8, arg, "--skip-db")) {
            skip_db = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) {
            if (std.mem.eql(u8, action, "import")) {
                ctx.logRaw(import_help_text);
            } else if (std.mem.eql(u8, action, "export")) {
                ctx.logRaw(export_help_text);
            } else if (std.mem.eql(u8, action, "provision")) {
                ctx.logRaw(provision_help_text);
            } else {
                ctx.log("Unknown action: {s}", .{action});
            }
            return;
        } else if (file_arg.len == 0 and !std.mem.startsWith(u8, arg, "-")) {
            file_arg = arg;
        } else {
            ctx.errorExit("Unknown option for gar db {s}: {s}", .{ action, arg });
        }
    }

    const hub_dir = context.requireHubDir(ctx);
    const cfg = try config.ArboristConfig.load(ctx, hub_dir);

    var default_branch = cfg.default_branch;
    if (default_branch.len == 0 or std.mem.eql(u8, default_branch, "HEAD")) {
        default_branch = try git.detectDefaultBranch(ctx, hub_dir);
    }

    const active = try context.detectActiveWorktree(ctx, hub_dir);
    const current_branch = active.branch orelse "";
    const current_wt_top = active.wt_top orelse "";

    var target_branch = if (target_arg.len > 0)
        target_arg
    else if (current_branch.len > 0)
        current_branch
    else
        default_branch;

    var target_db = try resolveTargetDb(ctx.arena, target_branch, default_branch);

    if (std.mem.eql(u8, action, "import")) {
        var resolved_file: []const u8 = "";
        if (file_arg.len > 0) {
            resolved_file = try resolveUserFilePath(ctx, file_arg, false);
            if (!io_util.fileExists(ctx.io, resolved_file)) {
                ctx.errorExit("Specified database dump file not found: {s}", .{resolved_file});
            }
        } else {
            if (ddev.getLatestBackupFile(ctx, hub_dir, cfg.db_backup_path)) |bf| {
                resolved_file = bf;
            } else {
                const rel_backup = try Dir.path.join(ctx.arena, &.{ hub_dir, cfg.db_backup_path });
                if (cfg.db_backup_path.len > 0 and
                    !io_util.pathExists(ctx.io, cfg.db_backup_path) and
                    !io_util.pathExists(ctx.io, rel_backup))
                {
                    ctx.errorExit("Configured DB_BACKUP_PATH does not exist: {s}", .{cfg.db_backup_path});
                } else {
                    const disp = if (cfg.db_backup_path.len > 0) cfg.db_backup_path else "backups";
                    ctx.errorExit("No database dump files found in directory: {s}", .{disp});
                }
            }
        }

        ctx.log("Importing database dump into '\x1b[36m{s}\x1b[0m'...", .{target_db});
        ctx.log("Source file: {s}", .{resolved_file});
        if (std.mem.eql(u8, cfg.env_engine, "ddev")) {
            if (!std.mem.eql(u8, target_db, "db")) {
                try ddev.createDatabase(ctx, hub_dir, target_db);
            }
            const code = try ddev.importDb(ctx, hub_dir, target_db, resolved_file);
            if (code != 0) std.process.exit(code);
            ctx.log("Database '\x1b[32m{s}\x1b[0m' imported successfully.", .{target_db});
        } else {
            ctx.errorExit("Database import for engine '{s}' is not yet implemented.", .{cfg.env_engine});
        }
        return;
    }

    if (std.mem.eql(u8, action, "export")) {
        var resolved_file: []const u8 = "";
        if (file_arg.len > 0) {
            resolved_file = try resolveUserFilePath(ctx, file_arg, true);
        } else {
            const backup_target = if (std.mem.startsWith(u8, cfg.db_backup_path, "/"))
                cfg.db_backup_path
            else
                try Dir.path.join(ctx.arena, &.{ hub_dir, cfg.db_backup_path });

            if (io_util.dirExists(ctx.io, backup_target) or std.mem.indexOfScalar(u8, cfg.db_backup_path, '.') == null) {
                try io_util.makePath(ctx.io, backup_target);
                const ts = try currentTimestampString(ctx);
                resolved_file = try std.fmt.allocPrint(ctx.arena, "{s}/{s}_{s}.sql.gz", .{ backup_target, target_db, ts });
            } else {
                if (Dir.path.dirname(backup_target)) |parent| {
                    try io_util.makePath(ctx.io, parent);
                }
                resolved_file = backup_target;
            }
        }

        ctx.log("Exporting database '\x1b[36m{s}\x1b[0m'...", .{target_db});
        ctx.log("Destination: {s}", .{resolved_file});
        if (std.mem.eql(u8, cfg.env_engine, "ddev")) {
            const code = try ddev.exportDb(ctx, hub_dir, target_db, resolved_file);
            if (code != 0) std.process.exit(code);
            ctx.log("Database exported successfully to {s}", .{resolved_file});
        } else {
            ctx.errorExit("Database export for engine '{s}' is not yet implemented.", .{cfg.env_engine});
        }
        return;
    }

    if (std.mem.eql(u8, action, "provision")) {
        var target_wt_path: []const u8 = "";
        const target_wt_dir = try naming.getWtDirName(ctx.arena, target_branch);
        const cand_wt_dir = try Dir.path.join(ctx.arena, &.{ hub_dir, target_wt_dir });
        const cand_raw = try Dir.path.join(ctx.arena, &.{ hub_dir, target_branch });

        if (target_arg.len == 0 and current_wt_top.len > 0 and io_util.dirExists(ctx.io, current_wt_top)) {
            const cur_rel = Dir.path.basename(current_wt_top);
            const cand_cur = try Dir.path.join(ctx.arena, &.{ hub_dir, cur_rel });
            if (io_util.dirExists(ctx.io, cand_cur)) {
                target_wt_path = cand_cur;
            } else {
                target_wt_path = current_wt_top;
            }
        } else if (io_util.dirExists(ctx.io, cand_wt_dir)) {
            target_wt_path = cand_wt_dir;
        } else if (io_util.dirExists(ctx.io, cand_raw)) {
            target_wt_path = cand_raw;
        } else {
            const worktrees = try git.listWorktrees(ctx, hub_dir);
            for (worktrees) |wt| {
                const parsed_branch = wt.branch orelse continue;
                const parsed_dir_name = try naming.getWtDirName(ctx.arena, parsed_branch);
                if (std.mem.eql(u8, parsed_branch, target_branch) or
                    std.mem.eql(u8, parsed_dir_name, target_branch) or
                    std.ascii.eqlIgnoreCase(parsed_branch, target_branch) or
                    std.mem.eql(u8, parsed_dir_name, target_wt_dir))
                {
                    const rel_p = Dir.path.basename(wt.path);
                    const cand = try Dir.path.join(ctx.arena, &.{ hub_dir, rel_p });
                    if (io_util.dirExists(ctx.io, cand)) {
                        target_wt_path = cand;
                    } else {
                        target_wt_path = wt.path;
                    }
                    target_branch = parsed_branch;
                    break;
                }
            }
        }

        if (target_wt_path.len == 0 or !io_util.dirExists(ctx.io, target_wt_path)) {
            ctx.errorExit("Worktree for branch '{s}' not found in {s}.", .{ target_branch, hub_dir });
        }

        target_db = try resolveTargetDb(ctx.arena, target_branch, default_branch);

        if (!skip_db) {
            if (std.mem.eql(u8, cfg.env_engine, "ddev")) {
                if (!std.mem.eql(u8, target_db, "db")) {
                    try ddev.createDatabase(ctx, hub_dir, target_db);
                }

                if (file_arg.len > 0) {
                    const resolved_file = try resolveUserFilePath(ctx, file_arg, false);
                    if (!io_util.fileExists(ctx.io, resolved_file)) {
                        ctx.errorExit("Specified database dump file not found: {s}", .{resolved_file});
                    }
                    ctx.log("Importing database dump into '\x1b[36m{s}\x1b[0m'...", .{target_db});
                    ctx.log("Source file: {s}", .{resolved_file});
                    const code = try ddev.importDb(ctx, hub_dir, target_db, resolved_file);
                    if (code != 0) std.process.exit(code);
                    ctx.log("Database '\x1b[32m{s}\x1b[0m' ready.", .{target_db});
                } else {
                    const provision_strategy = if (strategy_override.len > 0)
                        strategy_override
                    else if (cfg.db_provision_strategy.len > 0)
                        cfg.db_provision_strategy
                    else
                        "backup";

                    if (std.mem.eql(u8, provision_strategy, "clone")) {
                        if (std.mem.eql(u8, target_db, "db")) {
                            ctx.log("Target is default database 'db'; skipping self-clone.", .{});
                        } else {
                            ctx.log("Cloning default database into '\x1b[36m{s}\x1b[0m'...", .{target_db});
                            const code = try ddev.cloneDatabase(ctx, hub_dir, "db", target_db);
                            if (code != 0) std.process.exit(code);
                            ctx.log("Isolated database '\x1b[32m{s}\x1b[0m' ready.", .{target_db});
                        }
                    } else {
                        if (ddev.getLatestBackupFile(ctx, hub_dir, cfg.db_backup_path)) |backup_file| {
                            ctx.log("Importing backup dump into '\x1b[36m{s}\x1b[0m'...", .{target_db});
                            ctx.log("Source: {s}", .{backup_file});
                            const code = try ddev.importDb(ctx, hub_dir, target_db, backup_file);
                            if (code != 0) std.process.exit(code);
                            ctx.log("Isolated database '\x1b[32m{s}\x1b[0m' ready.", .{target_db});
                        } else if (!std.mem.eql(u8, target_db, "db")) {
                            const disp = if (cfg.db_backup_path.len > 0) cfg.db_backup_path else "backups";
                            ctx.log("No database backup dump found in '{s}'. Falling back to cloning default database...", .{disp});
                            const code = try ddev.cloneDatabase(ctx, hub_dir, "db", target_db);
                            if (code != 0) std.process.exit(code);
                            ctx.log("Isolated database '\x1b[32m{s}\x1b[0m' ready.", .{target_db});
                        } else {
                            const disp = if (cfg.db_backup_path.len > 0) cfg.db_backup_path else "backups";
                            ctx.errorExit("No database dump files found in directory: {s}", .{disp});
                        }
                    }
                }
            } else {
                ctx.errorExit("Database provisioning for engine '{s}' is not yet implemented.", .{cfg.env_engine});
            }
        }

        var post_cmd = cfg.post_provision_cmd;
        if (post_cmd.len == 0 and std.mem.eql(u8, cfg.framework, "drupal")) {
            post_cmd = "ddev drush updb -y && ddev drush cim -y && ddev drush cr && ddev drush uli";
        }

        if (post_cmd.len > 0) {
            ddev.flushEnvSync(ctx, cfg.env_engine, hub_dir);
            const wt_rel_name = Dir.path.basename(target_wt_path);
            ctx.log("Running post-provision commands in '{s}'...", .{wt_rel_name});
            const code = try io_util.runShellCommand(ctx, post_cmd, target_wt_path);
            if (code != 0) {
                ctx.errorExit("Post-provision command failed with exit code {d}. Aborted remaining commands.", .{code});
            }
        }

        ctx.log("Provisioning complete for '{s}' ({s}).", .{ target_branch, target_db });
        return;
    }

    ctx.errorExit("Unknown database action: {s}\nRun 'gar db' to see available actions.", .{action});
}

fn resolveTargetDb(allocator: std.mem.Allocator, target_branch: []const u8, default_branch: []const u8) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(target_branch, default_branch) or
        std.ascii.eqlIgnoreCase(target_branch, "db") or
        std.ascii.eqlIgnoreCase(target_branch, "default"))
    {
        return "db";
    }
    return naming.getDbName(allocator, target_branch);
}

fn resolveUserFilePath(ctx: *const Context, file_arg: []const u8, create_parent: bool) ![]const u8 {
    const raw = if (std.mem.startsWith(u8, file_arg, "/"))
        file_arg
    else
        try Dir.path.join(ctx.arena, &.{ ctx.invocation_dir, file_arg });

    if (Dir.path.dirname(raw)) |parent| {
        if (create_parent) {
            try io_util.makePath(ctx.io, parent);
        }
        if (io_util.dirExists(ctx.io, parent)) {
            const real_parent = try io_util.realPathOrCopy(ctx.arena, ctx.io, parent);
            return Dir.path.join(ctx.arena, &.{ real_parent, Dir.path.basename(raw) });
        }
    }
    return raw;
}

fn currentTimestampString(ctx: *const Context) ![]const u8 {
    if (io_util.runCapture(ctx, &.{ "date", "+%Y%m%d_%H%M%S" }, null)) |res| {
        if (res.success()) {
            const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
            if (trimmed.len > 0) return ctx.arena.dupe(u8, trimmed);
        }
    } else |_| {}
    return "00000000_000000";
}
