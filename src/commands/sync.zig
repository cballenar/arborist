const std = @import("std");
const Dir = std.Io.Dir;
const io_util = @import("../io_util.zig");
const Context = io_util.Context;
const config = @import("../config.zig");
const context = @import("../context.zig");
const git = @import("../git.zig");
const naming = @import("../naming.zig");
const templates = @import("../templates.zig");
const ddev = @import("../engine/ddev.zig");

const help_text =
    \\Usage: gar sync
    \\
    \\Re-apply Arborist templates, Git hooks, and command wrappers to the Hub.
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

    const hub_dir = context.requireHubDir(ctx);
    const cfg = try config.ArboristConfig.load(ctx, hub_dir);

    ctx.log("🌳 Synchronizing Arborist Hub configuration...", .{});

    // 1. Sync Git configuration and hooks
    ctx.log("  • Updating Git hooks and fetch configurations...", .{});
    try templates.installGitHooks(ctx, hub_dir);

    // 2. Sync Git exclude patterns
    ctx.log("  • Updating Git exclude patterns...", .{});
    try templates.ensureGitExcludePatterns(ctx, hub_dir);

    // 3. Sync Environment Engine configurations
    if (std.mem.eql(u8, cfg.env_engine, "ddev")) {
        ctx.log("  • Updating DDEV command wrappers...", .{});
        try templates.installDdevCommandWrappers(ctx, hub_dir);

        ctx.log("  • Updating Nginx wildcard configuration...", .{});
        try templates.writeWorkspaceNginxConf(ctx, hub_dir, cfg.webroot, cfg.default_branch);

        ctx.log("  • Verifying DDEV wildcard routing and docroot...", .{});
        const ddev_cfg_path = try Dir.path.join(ctx.arena, &.{ hub_dir, ".ddev", "config.yaml" });
        const ddev_info = try config.getDdevDomainInfo(ctx, hub_dir);
        var project_name: []const u8 = ddev_info.project_name;
        if (project_name.len == 0) {
            project_name = Dir.path.basename(hub_dir);
        }

        const def_wt_dir = try naming.getWtDirName(ctx.arena, cfg.default_branch);
        const add_hostnames_arg = try std.fmt.allocPrint(ctx.arena, "--additional-hostnames=*.{s}", .{project_name});
        const docroot_arg = try std.fmt.allocPrint(ctx.arena, "--docroot={s}/{s}", .{ def_wt_dir, cfg.webroot });
        const comp_root_arg = try std.fmt.allocPrint(ctx.arena, "--composer-root={s}", .{def_wt_dir});

        _ = io_util.runQuiet(ctx, &.{ "ddev", "config", add_hostnames_arg }, hub_dir);
        _ = io_util.runQuiet(ctx, &.{ "ddev", "config", docroot_arg, comp_root_arg }, hub_dir);

        if (io_util.fileExists(ctx.io, ddev_cfg_path)) {
            if (io_util.readFileAlloc(ctx.arena, ctx.io, ddev_cfg_path)) |ddev_content| {
                const updated = try updateComposerRootOnly(ctx.arena, ddev_content, def_wt_dir);
                try io_util.writeFile(ctx.io, ddev_cfg_path, updated, false);
            }
        }

        ctx.log("  • Updating DDEV Mutagen configuration...", .{});
        try templates.configureDdevMutagen(ctx, hub_dir, cfg.webroot, cfg.db_backup_path);
    }

    // 4. Sync and heal all active worktrees
    ctx.log("  • Auditing and healing active worktrees...", .{});
    const worktrees = try git.listWorktrees(ctx, hub_dir);
    for (worktrees) |wt| {
        if (wt.is_bare) continue;
        if (!io_util.dirExists(ctx.io, wt.path)) continue;

        var cur_wt = wt.path;
        const cur_dir_name = Dir.path.basename(cur_wt);
        if (wt.branch) |wt_branch| {
            if (wt_branch.len > 0) {
                const norm_dir_name = try naming.getWtDirName(ctx.arena, wt_branch);
                if (!std.mem.eql(u8, cur_dir_name, norm_dir_name)) {
                    ctx.log("    Normalizing worktree directory '{s}' -> '{s}'...", .{ cur_dir_name, norm_dir_name });
                    const norm_abs = try Dir.path.join(ctx.arena, &.{ hub_dir, norm_dir_name });
                    try templates.renameWorktreeDirSafe(ctx, hub_dir, cur_wt, norm_abs);
                    cur_wt = norm_abs;
                }
            }
        }
        try templates.normalizeWorktreeGitdir(ctx, cur_wt);
        if (std.mem.eql(u8, cfg.framework, "drupal")) {
            try templates.provisionDrupalWorktree(ctx, hub_dir, cur_wt, cfg);
        }
    }

    ddev.flushEnvSync(ctx, cfg.env_engine, hub_dir);

    ctx.log("", .{});
    ctx.log("✅ Arborist hub synchronized successfully!", .{});
    if (std.mem.eql(u8, cfg.env_engine, "ddev") and io_util.runQuiet(ctx, &.{ "ddev", "describe" }, hub_dir)) {
        ctx.log("💡 Run 'ddev restart' to reload Nginx and container configurations.", .{});
    }
}

pub fn runInstallHooks(ctx: *const Context) !void {
    const hub_dir = context.requireHubDir(ctx);
    try templates.installGitHooks(ctx, hub_dir);
    ctx.log("Git Arborist hooks installed successfully in {s}/.git/hooks", .{hub_dir});
}

fn updateComposerRootOnly(allocator: std.mem.Allocator, content: []const u8, composer_root: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var has_composer_root = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |raw_line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "composer_root:")) {
            const repl = try std.fmt.allocPrint(allocator, "composer_root: {s}", .{composer_root});
            try out.appendSlice(allocator, repl);
            has_composer_root = true;
        } else {
            try out.appendSlice(allocator, line);
        }
    }
    if (!has_composer_root) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
        const extra = try std.fmt.allocPrint(allocator, "composer_root: {s}\n", .{composer_root});
        try out.appendSlice(allocator, extra);
    }
    return out.toOwnedSlice(allocator);
}
