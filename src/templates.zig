const std = @import("std");
const Dir = std.Io.Dir;
const io_util = @import("io_util.zig");
const Context = io_util.Context;
const config = @import("config.zig");
const naming = @import("naming.zig");

pub const mutagen_yml = @embedFile("template_mutagen_yml");
pub const settings_workspace_php = @embedFile("template_settings_workspace_php");
pub const workspace_nginx_conf = @embedFile("template_workspace_nginx_conf");
pub const ddev_drush = @embedFile("template_ddev_drush");
pub const ddev_npm = @embedFile("template_ddev_npm");
pub const ddev_twig_debug = @embedFile("template_ddev_twig_debug");

pub fn normalizeWorktreeGitdir(ctx: *const Context, wt_dir: []const u8) !void {
    const git_file = try Dir.path.join(ctx.arena, &.{ wt_dir, ".git" });
    if (!io_util.fileExists(ctx.io, git_file)) return;

    const content = io_util.readFileAlloc(ctx.arena, ctx.io, git_file) orelse return;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "gitdir:")) {
            const gitdir_path = std.mem.trim(u8, line["gitdir:".len..], " \t");
            if (std.mem.startsWith(u8, gitdir_path, "/") and
                std.mem.indexOf(u8, gitdir_path, "/.git/worktrees/") != null)
            {
                const wt_id = Dir.path.basename(gitdir_path);
                const parent_dir = Dir.path.dirname(wt_dir) orelse return;
                const cand_wt_meta = try Dir.path.join(ctx.arena, &.{ parent_dir, ".git", "worktrees", wt_id });
                if (io_util.dirExists(ctx.io, cand_wt_meta)) {
                    const new_content = try std.fmt.allocPrint(ctx.arena, "gitdir: ../.git/worktrees/{s}\n", .{wt_id});
                    try io_util.writeFile(ctx.io, git_file, new_content, false);
                }
            }
            break;
        }
    }
}

pub fn renameWorktreeDirSafe(ctx: *const Context, hub_dir: []const u8, old_abs: []const u8, new_abs: []const u8) !void {
    const tmp_mv = try Dir.path.join(ctx.arena, &.{ hub_dir, ".tmp_gar_renaming_wt" });
    if (io_util.pathExists(ctx.io, tmp_mv)) {
        Dir.cwd().deleteTree(ctx.io, tmp_mv) catch {};
    }
    try Dir.cwd().rename(old_abs, Dir.cwd(), tmp_mv, ctx.io);
    _ = io_util.runQuiet(ctx, &.{ "git", "-C", hub_dir, "worktree", "repair", tmp_mv }, null);
    try Dir.cwd().rename(tmp_mv, Dir.cwd(), new_abs, ctx.io);
    _ = io_util.runQuiet(ctx, &.{ "git", "-C", hub_dir, "worktree", "repair", new_abs }, null);
}

pub fn ensureGitExcludePatterns(ctx: *const Context, hub_dir: []const u8) !void {
    const info_dir = try Dir.path.join(ctx.arena, &.{ hub_dir, ".git", "info" });
    try io_util.makePath(ctx.io, info_dir);
    const exclude_file = try Dir.path.join(ctx.arena, &.{ info_dir, "exclude" });

    const existing = io_util.readFileAlloc(ctx.arena, ctx.io, exclude_file) orelse "";
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.arena, existing);
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '\n') {
        try buf.append(ctx.arena, '\n');
    }

    const patterns = [_][]const u8{
        "settings.workspace.php",
        "settings.local.php",
        "settings.ddev.php",
        "development.services.yml",
        ".env",
        ".env.local",
    };

    var modified = existing.len == 0;
    for (patterns) |pat| {
        if (!hasExactLine(buf.items, pat)) {
            try buf.appendSlice(ctx.arena, pat);
            try buf.append(ctx.arena, '\n');
            modified = true;
        }
    }

    if (modified or !io_util.fileExists(ctx.io, exclude_file)) {
        try io_util.writeFile(ctx.io, exclude_file, buf.items, false);
    }
}

fn hasExactLine(content: []const u8, target: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.eql(u8, line, target)) return true;
    }
    return false;
}

pub fn provisionDrupalWorktree(
    ctx: *const Context,
    hub_dir: []const u8,
    wt_dir: []const u8,
    cfg: config.ArboristConfig,
) !void {
    const site_dir = try Dir.path.join(ctx.arena, &.{ wt_dir, cfg.webroot, "sites", "default" });
    const def_wt_dir = try naming.getWtDirName(ctx.arena, cfg.default_branch);
    const def_site_dir = try Dir.path.join(ctx.arena, &.{ hub_dir, def_wt_dir, cfg.webroot, "sites", "default" });

    try io_util.makePath(ctx.io, site_dir);
    try ensureGitExcludePatterns(ctx, hub_dir);

    // 1. settings.workspace.php
    const ws_php_path = try Dir.path.join(ctx.arena, &.{ site_dir, "settings.workspace.php" });
    const def_quoted = try std.fmt.allocPrint(ctx.arena, "'{s}'", .{cfg.default_branch});
    const rendered_ws_php = try std.mem.replaceOwned(u8, ctx.arena, settings_workspace_php, "'develop'", def_quoted);
    try io_util.writeFile(ctx.io, ws_php_path, rendered_ws_php, false);

    // 2. settings.ddev.php
    const ddev_php_path = try Dir.path.join(ctx.arena, &.{ site_dir, "settings.ddev.php" });
    if (std.mem.eql(u8, cfg.env_engine, "ddev") and !io_util.fileExists(ctx.io, ddev_php_path)) {
        const def_ddev_php = try Dir.path.join(ctx.arena, &.{ def_site_dir, "settings.ddev.php" });
        if (io_util.fileExists(ctx.io, def_ddev_php)) {
            try io_util.copyFile(ctx.arena, ctx.io, def_ddev_php, ddev_php_path, false);
        }
    }

    // 3. settings.local.php
    const local_php_path = try Dir.path.join(ctx.arena, &.{ site_dir, "settings.local.php" });
    if (!io_util.fileExists(ctx.io, local_php_path)) {
        const def_local_php = try Dir.path.join(ctx.arena, &.{ def_site_dir, "settings.local.php" });
        if (io_util.fileExists(ctx.io, def_local_php)) {
            try io_util.copyFile(ctx.arena, ctx.io, def_local_php, local_php_path, false);
        } else {
            const snippet =
                \\<?php
                \\if (file_exists(__DIR__ . '/settings.workspace.php')) {
                \\    require __DIR__ . '/settings.workspace.php';
                \\}
                \\
            ;
            try io_util.writeFile(ctx.io, local_php_path, snippet, false);
        }
    } else {
        const existing_local = io_util.readFileAlloc(ctx.arena, ctx.io, local_php_path) orelse "";
        if (std.mem.indexOf(u8, existing_local, "settings.workspace.php") == null) {
            const snippet =
                \\
                \\if (file_exists(__DIR__ . '/settings.workspace.php')) {
                \\    require __DIR__ . '/settings.workspace.php';
                \\}
                \\
            ;
            try io_util.appendFile(ctx.arena, ctx.io, local_php_path, snippet);
        }
    }

    // 4. development.services.yml
    const sites_dir = try Dir.path.join(ctx.arena, &.{ wt_dir, cfg.webroot, "sites" });
    const def_sites_dir = try Dir.path.join(ctx.arena, &.{ hub_dir, def_wt_dir, cfg.webroot, "sites" });
    const dev_services_path = try Dir.path.join(ctx.arena, &.{ sites_dir, "development.services.yml" });
    if (!io_util.fileExists(ctx.io, dev_services_path)) {
        const def_dev_services = try Dir.path.join(ctx.arena, &.{ def_sites_dir, "development.services.yml" });
        const scaffold_dev_services = try Dir.path.join(ctx.arena, &.{ wt_dir, cfg.webroot, "core", "assets", "scaffold", "files", "development.services.yml" });
        if (io_util.fileExists(ctx.io, def_dev_services)) {
            try io_util.copyFile(ctx.arena, ctx.io, def_dev_services, dev_services_path, false);
        } else if (io_util.fileExists(ctx.io, scaffold_dev_services)) {
            try io_util.copyFile(ctx.arena, ctx.io, scaffold_dev_services, dev_services_path, false);
        }
    }

    // 5. .env file handling
    const wt_env = try Dir.path.join(ctx.arena, &.{ wt_dir, ".env" });
    const def_env = try Dir.path.join(ctx.arena, &.{ hub_dir, def_wt_dir, ".env" });
    if (!io_util.fileExists(ctx.io, wt_env)) {
        const wt_env_example = try Dir.path.join(ctx.arena, &.{ wt_dir, ".env.example" });
        if (io_util.fileExists(ctx.io, def_env)) {
            ctx.log("  • Seeding .env from default branch ({s})...", .{cfg.default_branch});
            try io_util.copyFile(ctx.arena, ctx.io, def_env, wt_env, false);
        } else if (io_util.fileExists(ctx.io, wt_env_example)) {
            ctx.log("  • Seeding .env from .env.example...", .{});
            try io_util.copyFile(ctx.arena, ctx.io, wt_env_example, wt_env, false);
        }
    }
}

pub fn installGitHooks(ctx: *const Context, hub_dir: []const u8) !void {
    const hooks_dir = try Dir.path.join(ctx.arena, &.{ hub_dir, ".git", "hooks" });
    try io_util.makePath(ctx.io, hooks_dir);

    _ = io_util.runQuiet(ctx, &.{ "git", "-C", hub_dir, "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*" }, null);
    _ = io_util.runQuiet(ctx, &.{ "git", "-C", hub_dir, "config", "fetch.prune", "true" }, null);

    const post_merge_content =
        \\#!/usr/bin/env bash
        \\# Git Arborist post-merge hook
        \\# Automatically cleans up orphaned databases and worktrees if DDEV is running.
        \\if command -v gar >/dev/null 2>&1; then
        \\    gar prune --hook >/dev/null 2>&1 || true
        \\fi
        \\
    ;
    const post_merge_path = try Dir.path.join(ctx.arena, &.{ hooks_dir, "post-merge" });
    try io_util.writeFile(ctx.io, post_merge_path, post_merge_content, true);

    const ref_tx_content =
        \\#!/usr/bin/env bash
        \\# Git Arborist reference-transaction hook
        \\# Automatically cleans up orphaned databases and worktrees when branches are deleted.
        \\state="$1"
        \\if [ "$state" = "committed" ]; then
        \\    while read -r oldrev newrev refname; do
        \\        if [ "$newrev" = "0000000000000000000000000000000000000000" ] && [[ "$refname" =~ ^refs/heads/ ]]; then
        \\            if command -v gar >/dev/null 2>&1; then
        \\                gar prune --hook >/dev/null 2>&1 || true
        \\                break
        \\            fi
        \\        fi
        \\    done
        \\fi
        \\
    ;
    const ref_tx_path = try Dir.path.join(ctx.arena, &.{ hooks_dir, "reference-transaction" });
    try io_util.writeFile(ctx.io, ref_tx_path, ref_tx_content, true);
}

pub fn installDdevCommandWrappers(ctx: *const Context, hub_dir: []const u8) !void {
    const web_cmds_dir = try Dir.path.join(ctx.arena, &.{ hub_dir, ".ddev", "commands", "web" });
    try io_util.makePath(ctx.io, web_cmds_dir);

    const drush_path = try Dir.path.join(ctx.arena, &.{ web_cmds_dir, "drush" });
    try io_util.writeFile(ctx.io, drush_path, ddev_drush, true);

    const npm_path = try Dir.path.join(ctx.arena, &.{ web_cmds_dir, "npm" });
    try io_util.writeFile(ctx.io, npm_path, ddev_npm, true);

    const twig_path = try Dir.path.join(ctx.arena, &.{ web_cmds_dir, "twig-debug" });
    try io_util.writeFile(ctx.io, twig_path, ddev_twig_debug, true);
}

pub fn writeWorkspaceNginxConf(
    ctx: *const Context,
    hub_dir: []const u8,
    webroot: []const u8,
    default_branch: []const u8,
) !void {
    const nginx_dir = try Dir.path.join(ctx.arena, &.{ hub_dir, ".ddev", "nginx_full" });
    try io_util.makePath(ctx.io, nginx_dir);

    const def_branch_nginx = try naming.getWtDirName(ctx.arena, default_branch);
    const webroot_repl = try std.fmt.allocPrint(ctx.arena, "/{s}", .{webroot});

    const step1 = try std.mem.replaceOwned(u8, ctx.arena, workspace_nginx_conf, "/docroot", webroot_repl);
    const step2 = try std.mem.replaceOwned(u8, ctx.arena, step1, "DEFAULT_BRANCH_PLACEHOLDER", def_branch_nginx);

    const out_path = try Dir.path.join(ctx.arena, &.{ nginx_dir, "workspace-nginx.conf" });
    try io_util.writeFile(ctx.io, out_path, step2, false);
}

pub fn configureDdevMutagen(
    ctx: *const Context,
    hub_dir: []const u8,
    webroot: []const u8,
    backup_path: []const u8,
) !void {
    const mutagen_dir = try Dir.path.join(ctx.arena, &.{ hub_dir, ".ddev", "mutagen" });
    const mutagen_file = try Dir.path.join(ctx.arena, &.{ mutagen_dir, "mutagen.yml" });

    if (io_util.fileExists(ctx.io, mutagen_file)) {
        const existing = io_util.readFileAlloc(ctx.arena, ctx.io, mutagen_file) orelse "";
        var managed = false;
        var lines = std.mem.splitScalar(u8, existing, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (std.mem.startsWith(u8, line, "#ddev-generated") or
                std.mem.startsWith(u8, line, "# Managed by Git Arborist"))
            {
                managed = true;
                break;
            }
        }
        if (!managed) return;
    }

    try io_util.makePath(ctx.io, mutagen_dir);

    const hub_real = try io_util.realPathOrCopy(ctx.arena, ctx.io, hub_dir);
    const home = ctx.envOrDefault("HOME", "");

    var resolved_backup = if (backup_path.len > 0) backup_path else "backups";
    if (std.mem.startsWith(u8, resolved_backup, "~/")) {
        resolved_backup = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ home, resolved_backup[2..] });
    } else if (std.mem.eql(u8, resolved_backup, "~")) {
        resolved_backup = home;
    }

    var clean_backup: []const u8 = "";
    const hub_real_slash = try std.fmt.allocPrint(ctx.arena, "{s}/", .{hub_real});
    const hub_dir_slash = try std.fmt.allocPrint(ctx.arena, "{s}/", .{hub_dir});

    if (std.mem.startsWith(u8, resolved_backup, "/")) {
        if (std.mem.startsWith(u8, resolved_backup, hub_real_slash)) {
            clean_backup = resolved_backup[hub_real_slash.len..];
        } else if (std.mem.startsWith(u8, resolved_backup, hub_dir_slash)) {
            clean_backup = resolved_backup[hub_dir_slash.len..];
        }
    } else {
        if (std.mem.startsWith(u8, resolved_backup, "./")) {
            resolved_backup = resolved_backup[2..];
        }
        if (!std.mem.startsWith(u8, resolved_backup, "..") and
            std.mem.indexOf(u8, resolved_backup, "/../") == null)
        {
            clean_backup = resolved_backup;
        }
    }

    clean_backup = std.mem.trim(u8, clean_backup, "/");

    const webroot_repl = try std.fmt.allocPrint(ctx.arena, "/{s}", .{webroot});
    const step1 = try std.mem.replaceOwned(u8, ctx.arena, mutagen_yml, "/docroot", webroot_repl);

    const final_content = if (clean_backup.len > 0) blk: {
        const backup_repl = try std.fmt.allocPrint(ctx.arena, "/{s}", .{clean_backup});
        break :blk try std.mem.replaceOwned(u8, ctx.arena, step1, "/backups", backup_repl);
    } else blk: {
        break :blk try std.mem.replaceOwned(u8, ctx.arena, step1, "        - \"/backups\"\n", "");
    };

    try io_util.writeFile(ctx.io, mutagen_file, final_content, false);
}
