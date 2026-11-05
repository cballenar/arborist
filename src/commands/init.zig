const std = @import("std");
const Dir = std.Io.Dir;
const io_util = @import("../io_util.zig");
const Context = io_util.Context;
const config = @import("../config.zig");
const git = @import("../git.zig");
const naming = @import("../naming.zig");
const prompt = @import("../prompt.zig");
const templates = @import("../templates.zig");

const help_text =
    \\Usage: gar init <repo_url> [hub_dir]
    \\
    \\Initialize a new Arborist Hub and provision baseline worktree.
    \\
    \\Arguments:
    \\  <repo_url>   Git repository URL to clone (HTTPS, SSH, or local path)
    \\  [hub_dir]    Directory name for the hub (defaults to repository name)
    \\
;

pub fn run(ctx: *const Context, args: []const []const u8) !void {
    const repo_url = if (args.len > 0) args[0] else "";
    var hub_dir_arg = if (args.len > 1) args[1] else "";

    if (std.mem.eql(u8, repo_url, "-h") or
        std.mem.eql(u8, repo_url, "--help") or
        std.mem.eql(u8, repo_url, "help"))
    {
        ctx.logRaw(help_text);
        return;
    }

    if (repo_url.len == 0) {
        ctx.errorExit("Usage: gar init <repo_url> [hub_dir]", .{});
    }

    if (hub_dir_arg.len == 0) {
        const clean_url = std.mem.trimEnd(u8, repo_url, "/");
        var raw_name = Dir.path.basename(clean_url);
        if (std.mem.endsWith(u8, raw_name, ".git")) {
            raw_name = raw_name[0 .. raw_name.len - 4];
        }
        if (raw_name.len == 0 or std.mem.eql(u8, raw_name, "/") or std.mem.eql(u8, raw_name, ".")) {
            ctx.errorExit("Could not infer directory name from repository URL: {s}\nUsage: gar init <repo_url> [hub_dir]", .{repo_url});
        }
        hub_dir_arg = raw_name;
    }

    ctx.log("Initializing Arborist Hub in {s}...", .{hub_dir_arg});
    const hub_dir = if (std.mem.startsWith(u8, hub_dir_arg, "/"))
        try Dir.path.resolve(ctx.arena, &.{hub_dir_arg})
    else
        try Dir.path.resolve(ctx.arena, &.{ ctx.invocation_dir, hub_dir_arg });

    try io_util.makePath(ctx.io, hub_dir);

    // Clone as bare repository into .git
    const clone_code = try io_util.runInheritStderr(ctx, &.{ "git", "clone", "--bare", repo_url, ".git" }, hub_dir);
    if (clone_code != 0) std.process.exit(clone_code);

    _ = try io_util.runInheritStderr(ctx, &.{ "git", "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*" }, hub_dir);
    _ = io_util.runQuiet(ctx, &.{ "git", "fetch", "origin" }, hub_dir);

    // Analyze HEAD
    var files: []const u8 = "";
    if (io_util.runCapture(ctx, &.{ "git", "ls-tree", "--name-only", "HEAD" }, hub_dir)) |ls_res| {
        if (ls_res.success()) files = ls_res.stdout;
    } else |_| {}

    const has_ddev = hasExactLine(files, ".ddev");
    const has_lando = hasExactLine(files, ".lando.yml");
    const has_docker = hasExactLine(files, "docker-compose.yml");

    var env_engine: []const u8 = "ddev";
    if (!ctx.isAutoYes()) {
        ctx.log("Detected environments: ", .{});
        if (has_ddev) ctx.log(" - DDEV", .{});
        if (has_lando) ctx.log(" - Lando", .{});
        if (has_docker) ctx.log(" - Docker", .{});
        ctx.log("Which environment engine will this Hub use?", .{});
        ctx.log("1) DDEV\n2) Lando\n3) Docker", .{});
        if (prompt.readLine(ctx, "Select engine (1-3): ", true)) |sel| {
            const trimmed = std.mem.trim(u8, sel, " \t\r\n");
            if (std.mem.eql(u8, trimmed, "2") or std.ascii.eqlIgnoreCase(trimmed, "lando")) {
                env_engine = "lando";
            } else if (std.mem.eql(u8, trimmed, "3") or std.ascii.eqlIgnoreCase(trimmed, "docker")) {
                env_engine = "docker";
            }
        }
    }

    ctx.log("Extracting environment configuration to the hub...", .{});
    if (std.mem.eql(u8, env_engine, "ddev")) {
        _ = io_util.runQuiet(ctx, &.{ "bash", "-c", "git archive HEAD .ddev/ | tar -x >/dev/null 2>&1 || true" }, hub_dir);
    } else if (std.mem.eql(u8, env_engine, "lando")) {
        _ = io_util.runQuiet(ctx, &.{ "bash", "-c", "git archive HEAD .lando.yml | tar -x >/dev/null 2>&1 || true; git archive HEAD .lando/ | tar -x >/dev/null 2>&1 || true" }, hub_dir);
    } else if (std.mem.eql(u8, env_engine, "docker")) {
        _ = io_util.runQuiet(ctx, &.{ "bash", "-c", "git archive HEAD docker-compose.yml | tar -x >/dev/null 2>&1 || true" }, hub_dir);
    }

    // 2. Sparse-Checkout Rules
    var sparse_excludes: []const u8 = "!/.ddev/ !/.lando.yml !/.lando/ !/docker-compose.yml";
    if (!ctx.isAutoYes()) {
        if (prompt.readLine(ctx, "Any other heavy directories to exclude from all worktrees? (comma-separated, e.g., docs,tests) [none]: ", true)) |extra_raw| {
            const extra = std.mem.trim(u8, extra_raw, " \t\r\n");
            if (extra.len > 0) {
                var buf: std.ArrayList(u8) = .empty;
                try buf.appendSlice(ctx.arena, sparse_excludes);
                var it = std.mem.splitScalar(u8, extra, ',');
                while (it.next()) |item| {
                    const dir = std.mem.trim(u8, item, " \t\r\n");
                    if (dir.len > 0) {
                        const part = try std.fmt.allocPrint(ctx.arena, " !/{s}/", .{dir});
                        try buf.appendSlice(ctx.arena, part);
                    }
                }
                sparse_excludes = buf.items;
            }
        }
    }

    // 3. Webroot & Framework
    var guess_webroot: []const u8 = "docroot";
    if (hasExactLine(files, "web")) guess_webroot = "web";
    if (hasExactLine(files, "public")) guess_webroot = "public";

    var webroot = guess_webroot;
    if (!ctx.isAutoYes()) {
        const p_msg = try std.fmt.allocPrint(ctx.arena, "Where is the public webroot? (Detected: '{s}') [{s}]: ", .{ guess_webroot, guess_webroot });
        if (prompt.readLine(ctx, p_msg, true)) |inp| {
            const trimmed = std.mem.trim(u8, inp, " \t\r\n");
            if (trimmed.len > 0) webroot = trimmed;
        }
    }

    var framework: []const u8 = "unknown";
    const settings_rel = try std.fmt.allocPrint(ctx.arena, "{s}/sites/default/settings.php", .{webroot});
    const settings_abs = try Dir.path.join(ctx.arena, &.{ hub_dir, settings_rel });
    if (io_util.fileExists(ctx.io, settings_abs) or
        io_util.runQuiet(ctx, &.{ "git", "ls-tree", "--name-only", "HEAD", settings_rel }, hub_dir))
    {
        framework = "drupal";
        ctx.log("Detected framework: Drupal", .{});
    }

    // 4. Database Backup Path
    var guess_backup_path: []const u8 = "backups";
    if (hasExactLine(files, ".ddev/db-backups")) guess_backup_path = ".ddev/db-backups";
    if (hasExactLine(files, "backups")) guess_backup_path = "backups";
    if (hasExactLine(files, "dumps")) guess_backup_path = "dumps";

    var db_backup_path = guess_backup_path;
    if (!ctx.isAutoYes()) {
        const p_msg = try std.fmt.allocPrint(ctx.arena, "Database backup path relative to hub root? [{s}]: ", .{guess_backup_path});
        if (prompt.readLine(ctx, p_msg, true)) |inp| {
            const trimmed = std.mem.trim(u8, inp, " \t\r\n");
            if (trimmed.len > 0) db_backup_path = trimmed;
        }
    }
    const backup_abs = if (std.mem.startsWith(u8, db_backup_path, "/"))
        db_backup_path
    else
        try Dir.path.join(ctx.arena, &.{ hub_dir, db_backup_path });
    try io_util.makePath(ctx.io, backup_abs);

    // 5. Default Branch
    var default_branch = try git.detectDefaultBranch(ctx, hub_dir);
    if (!ctx.isAutoYes()) {
        const p_msg = try std.fmt.allocPrint(ctx.arena, "What is the main tracking branch? (Detected: '{s}') [{s}]: ", .{ default_branch, default_branch });
        if (prompt.readLine(ctx, p_msg, true)) |inp| {
            const trimmed = std.mem.trim(u8, inp, " \t\r\n");
            if (trimmed.len > 0) default_branch = trimmed;
        }
    }

    // 6. Post-provision Commands
    var post_provision_cmd: []const u8 = "";
    if (std.mem.eql(u8, framework, "drupal")) {
        const suggested = "ddev drush updb -y && ddev drush cim -y && ddev drush cr && ddev drush uli";
        if (ctx.isAutoYes()) {
            post_provision_cmd = suggested;
        } else {
            const p_msg = try std.fmt.allocPrint(ctx.arena, "Post-provision command for new branches? [{s}]: ", .{suggested});
            if (prompt.readLine(ctx, p_msg, true)) |inp| {
                const trimmed = std.mem.trim(u8, inp, " \t\r\n");
                post_provision_cmd = if (trimmed.len > 0) trimmed else suggested;
            } else {
                post_provision_cmd = suggested;
            }
        }
    } else if (!ctx.isAutoYes()) {
        if (prompt.readLine(ctx, "Post-provision command for new branches? (e.g., composer install) [none]: ", true)) |inp| {
            post_provision_cmd = std.mem.trim(u8, inp, " \t\r\n");
        }
    }

    const protected_branches = try std.fmt.allocPrint(ctx.arena, "{s},develop,main,master", .{default_branch});
    const cfg = config.ArboristConfig{
        .env_engine = env_engine,
        .webroot = webroot,
        .framework = framework,
        .sparse_excludes = sparse_excludes,
        .db_backup_path = db_backup_path,
        .db_provision_strategy = "backup",
        .default_branch = default_branch,
        .protected_branches = protected_branches,
        .prune_targets = "both",
        .post_provision_cmd = post_provision_cmd,
    };
    try cfg.write(ctx, hub_dir);

    ctx.log("Configuring Git hooks and automated remote branch pruning...", .{});
    try templates.installGitHooks(ctx, hub_dir);

    const def_wt_dir = try naming.getWtDirName(ctx.arena, default_branch);
    const def_wt_abs = try Dir.path.join(ctx.arena, &.{ hub_dir, def_wt_dir });

    ctx.log("Provisioning main worktree ({s})...", .{default_branch});
    const wt_code = try io_util.runInheritStderr(ctx, &.{ "git", "worktree", "add", def_wt_dir, default_branch }, hub_dir);
    if (wt_code != 0) std.process.exit(wt_code);

    var sparse_argv: std.ArrayList([]const u8) = .empty;
    try sparse_argv.appendSlice(ctx.arena, &.{ "git", "-C", def_wt_abs, "sparse-checkout", "set", "--no-cone", "/*" });
    var sp_it = std.mem.tokenizeAny(u8, sparse_excludes, " \t\r\n");
    while (sp_it.next()) |tok| {
        try sparse_argv.append(ctx.arena, tok);
    }
    const sp_code = try io_util.runInheritStderr(ctx, sparse_argv.items, def_wt_abs);
    if (sp_code != 0) std.process.exit(sp_code);

    if (std.mem.eql(u8, framework, "drupal")) {
        var inject = true;
        if (!ctx.isAutoYes()) {
            const p_msg = try std.fmt.allocPrint(ctx.arena, "Auto-inject Arborist DB routing into {s}/sites/default/settings.local.php? [Y/n]: ", .{webroot});
            inject = prompt.confirm(ctx, p_msg, true, true);
        }
        if (inject) {
            ctx.log("Injecting settings.workspace.php...", .{});
            const site_default_dir = try Dir.path.join(ctx.arena, &.{ def_wt_abs, webroot, "sites", "default" });
            try io_util.makePath(ctx.io, site_default_dir);

            const def_quoted = try std.fmt.allocPrint(ctx.arena, "'{s}'", .{default_branch});
            const rendered_ws = try std.mem.replaceOwned(u8, ctx.arena, templates.settings_workspace_php, "'develop'", def_quoted);
            const ws_path = try Dir.path.join(ctx.arena, &.{ site_default_dir, "settings.workspace.php" });
            try io_util.writeFile(ctx.io, ws_path, rendered_ws, false);

            const local_php_path = try Dir.path.join(ctx.arena, &.{ site_default_dir, "settings.local.php" });
            const existing_local = io_util.readFileAlloc(ctx.arena, ctx.io, local_php_path) orelse "";
            if (std.mem.indexOf(u8, existing_local, "settings.workspace.php") == null) {
                try io_util.appendFile(ctx.arena, ctx.io, local_php_path, "\nrequire __DIR__ . '/settings.workspace.php';\n");
            }

            const dev_services_dst = try Dir.path.join(ctx.arena, &.{ def_wt_abs, webroot, "sites", "development.services.yml" });
            const dev_services_src = try Dir.path.join(ctx.arena, &.{ def_wt_abs, webroot, "core", "assets", "scaffold", "files", "development.services.yml" });
            if (!io_util.fileExists(ctx.io, dev_services_dst) and io_util.fileExists(ctx.io, dev_services_src)) {
                try io_util.copyFile(ctx.arena, ctx.io, dev_services_src, dev_services_dst, false);
            }

            const env_dst = try Dir.path.join(ctx.arena, &.{ def_wt_abs, ".env" });
            const env_example = try Dir.path.join(ctx.arena, &.{ def_wt_abs, ".env.example" });
            if (!io_util.fileExists(ctx.io, env_dst) and io_util.fileExists(ctx.io, env_example)) {
                ctx.log("Seeding .env from .env.example...", .{});
                try io_util.copyFile(ctx.arena, ctx.io, env_example, env_dst, false);
            }
        }
    }

    try templates.normalizeWorktreeGitdir(ctx, def_wt_abs);

    if (std.mem.eql(u8, env_engine, "ddev")) {
        ctx.log("Injecting wildcard Nginx config...", .{});
        try templates.writeWorkspaceNginxConf(ctx, hub_dir, webroot, default_branch);

        const domain_info = try config.getDdevDomainInfo(ctx, hub_dir);
        const project_name = if (domain_info.project_name.len > 0)
            domain_info.project_name
        else
            Dir.path.basename(hub_dir);

        ctx.log("Configuring DDEV wildcard routing...", .{});
        const add_host_arg = try std.fmt.allocPrint(ctx.arena, "--additional-hostnames=*.{s}", .{project_name});
        _ = io_util.runInheritStderr(ctx, &.{ "ddev", "config", add_host_arg }, hub_dir) catch {};

        ctx.log("Updating DDEV hub docroot...", .{});
        const docroot_rel = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ def_wt_dir, webroot });
        const docroot_arg = try std.fmt.allocPrint(ctx.arena, "--docroot={s}", .{docroot_rel});
        const comp_arg = try std.fmt.allocPrint(ctx.arena, "--composer-root={s}", .{def_wt_dir});
        _ = io_util.runInheritStderr(ctx, &.{ "ddev", "config", docroot_arg, comp_arg }, hub_dir) catch {};

        try config.updateDdevConfigYaml(ctx, hub_dir, project_name, docroot_rel, def_wt_dir, true, true);

        ctx.log("Injecting DDEV command wrappers...", .{});
        try templates.installDdevCommandWrappers(ctx, hub_dir);

        ctx.log("Configuring DDEV Mutagen exclusions...", .{});
        try templates.configureDdevMutagen(ctx, hub_dir, webroot, db_backup_path);
    }

    if (!ctx.isAutoYes()) {
        if (prompt.readLine(ctx, "Any other permanent worktrees to provision now? (comma-separated) [none]: ", true)) |extra_raw| {
            const extra = std.mem.trim(u8, extra_raw, " \t\r\n");
            if (extra.len > 0) {
                var it = std.mem.splitScalar(u8, extra, ',');
                while (it.next()) |item| {
                    const b = std.mem.trim(u8, item, " \t\r\n");
                    if (b.len == 0) continue;
                    ctx.log("Provisioning extra branch: {s}", .{b});
                    const extra_wt_dir = try naming.getWtDirName(ctx.arena, b);
                    const extra_wt_abs = try Dir.path.join(ctx.arena, &.{ hub_dir, extra_wt_dir });
                    const c1 = try io_util.runInheritStderr(ctx, &.{ "git", "worktree", "add", extra_wt_dir, b }, hub_dir);
                    if (c1 != 0) {
                        _ = try io_util.runInheritStderr(ctx, &.{ "git", "worktree", "add", extra_wt_dir, "-b", b }, hub_dir);
                    }
                    var ex_sparse: std.ArrayList([]const u8) = .empty;
                    try ex_sparse.appendSlice(ctx.arena, &.{ "git", "-C", extra_wt_abs, "sparse-checkout", "set", "--no-cone", "/*" });
                    var sp2 = std.mem.tokenizeAny(u8, sparse_excludes, " \t\r\n");
                    while (sp2.next()) |tok| {
                        try ex_sparse.append(ctx.arena, tok);
                    }
                    _ = try io_util.runInheritStderr(ctx, ex_sparse.items, extra_wt_abs);
                    try templates.normalizeWorktreeGitdir(ctx, extra_wt_abs);
                    if (std.mem.eql(u8, framework, "drupal")) {
                        try templates.provisionDrupalWorktree(ctx, hub_dir, extra_wt_abs, cfg);
                    }
                }
            }
        }
    }

    ctx.log("\nArborist hub initialized successfully.", .{});
    ctx.log("You can now start your environment at the hub root.", .{});
}

fn hasExactLine(content: []const u8, target: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.eql(u8, line, target)) return true;
    }
    return false;
}
