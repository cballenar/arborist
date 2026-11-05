const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const io_util = @import("io_util.zig");
const Context = io_util.Context;

pub const ArboristConfig = struct {
    env_engine: []const u8 = "ddev",
    webroot: []const u8 = "docroot",
    framework: []const u8 = "drupal",
    sparse_excludes: []const u8 = "!/.ddev/ !/.lando.yml !/.lando/ !/docker-compose.yml",
    db_backup_path: []const u8 = "backups",
    db_provision_strategy: []const u8 = "backup",
    default_branch: []const u8 = "develop",
    protected_branches: []const u8 = "",
    prune_targets: []const u8 = "both",
    post_provision_cmd: []const u8 = "",

    pub fn load(ctx: *const Context, hub_dir: []const u8) !ArboristConfig {
        var cfg = ArboristConfig{};
        const cfg_path = try Dir.path.join(ctx.arena, &.{ hub_dir, ".arborist" });
        if (io_util.readFileAlloc(ctx.arena, ctx.io, cfg_path)) |content| {
            cfg = try parse(ctx.arena, content);
        }
        if (cfg.protected_branches.len == 0) {
            cfg.protected_branches = try std.fmt.allocPrint(
                ctx.arena,
                "{s},develop,main,master,production,staging",
                .{cfg.default_branch},
            );
        }
        return cfg;
    }

    pub fn parse(allocator: Allocator, content: []const u8) !ArboristConfig {
        var cfg = ArboristConfig{};
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            var key = std.mem.trim(u8, line[0..eq_idx], " \t");
            if (std.mem.startsWith(u8, key, "export ")) {
                key = std.mem.trim(u8, key["export ".len..], " \t");
            }
            const raw_val = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
            const val = try unquoteValue(allocator, raw_val);

            if (std.mem.eql(u8, key, "ENV_ENGINE")) {
                if (val.len > 0) cfg.env_engine = val;
            } else if (std.mem.eql(u8, key, "WEBROOT")) {
                if (val.len > 0) cfg.webroot = val;
            } else if (std.mem.eql(u8, key, "FRAMEWORK")) {
                if (val.len > 0) cfg.framework = val;
            } else if (std.mem.eql(u8, key, "SPARSE_EXCLUDES")) {
                if (val.len > 0) cfg.sparse_excludes = val;
            } else if (std.mem.eql(u8, key, "DB_BACKUP_PATH")) {
                if (val.len > 0) cfg.db_backup_path = val;
            } else if (std.mem.eql(u8, key, "DB_PROVISION_STRATEGY")) {
                if (val.len > 0) cfg.db_provision_strategy = val;
            } else if (std.mem.eql(u8, key, "DEFAULT_BRANCH")) {
                if (val.len > 0) cfg.default_branch = val;
            } else if (std.mem.eql(u8, key, "PROTECTED_BRANCHES")) {
                if (val.len > 0) cfg.protected_branches = val;
            } else if (std.mem.eql(u8, key, "PRUNE_TARGETS")) {
                if (val.len > 0) cfg.prune_targets = val;
            } else if (std.mem.eql(u8, key, "POST_PROVISION_CMD")) {
                cfg.post_provision_cmd = val;
            }
        }
        return cfg;
    }

    pub fn write(self: ArboristConfig, ctx: *const Context, hub_dir: []const u8) !void {
        const escaped_post = try escapeDoubleQuotes(ctx.arena, self.post_provision_cmd);
        const content = try std.fmt.allocPrint(
            ctx.arena,
            \\ENV_ENGINE={s}
            \\WEBROOT={s}
            \\FRAMEWORK={s}
            \\SPARSE_EXCLUDES="{s}"
            \\DB_BACKUP_PATH="{s}"
            \\DB_PROVISION_STRATEGY="{s}"
            \\DEFAULT_BRANCH="{s}"
            \\PROTECTED_BRANCHES="{s}"
            \\PRUNE_TARGETS="{s}"
            \\POST_PROVISION_CMD="{s}"
            \\
        ,
            .{
                self.env_engine,
                self.webroot,
                self.framework,
                self.sparse_excludes,
                self.db_backup_path,
                self.db_provision_strategy,
                self.default_branch,
                self.protected_branches,
                self.prune_targets,
                escaped_post,
            },
        );
        const cfg_path = try Dir.path.join(ctx.arena, &.{ hub_dir, ".arborist" });
        try io_util.writeFile(ctx.io, cfg_path, content, false);
    }
};

fn unquoteValue(allocator: Allocator, raw: []const u8) ![]u8 {
    var s = raw;
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\''))) {
        const quote = s[0];
        s = s[1 .. s.len - 1];
        if (quote == '"') {
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < s.len) : (i += 1) {
                if (s[i] == '\\' and i + 1 < s.len and (s[i + 1] == '"' or s[i + 1] == '\\')) {
                    try out.append(allocator, s[i + 1]);
                    i += 1;
                } else {
                    try out.append(allocator, s[i]);
                }
            }
            return out.toOwnedSlice(allocator);
        }
        return allocator.dupe(u8, s);
    }
    // Strip inline comment if unquoted
    if (std.mem.indexOf(u8, s, " #")) |comment_idx| {
        s = std.mem.trimEnd(u8, s[0..comment_idx], " \t");
    }
    return allocator.dupe(u8, s);
}

fn escapeDoubleQuotes(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input) |c| {
        if (c == '\\' or c == '"') {
            try out.append(allocator, '\\');
        }
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

pub const DdevDomainInfo = struct {
    project_name: []const u8,
    project_tld: []const u8,
    scheme: []const u8,
    base_domain: []const u8,
};

pub fn getDdevDomainInfo(ctx: *const Context, hub_dir: []const u8) !DdevDomainInfo {
    var proj_name: []const u8 = "";
    var proj_tld: []const u8 = "ddev.site";

    const ddev_cfg_path = try Dir.path.join(ctx.arena, &.{ hub_dir, ".ddev", "config.yaml" });
    if (io_util.readFileAlloc(ctx.arena, ctx.io, ddev_cfg_path)) |content| {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (std.mem.startsWith(u8, line, "name:")) {
                if (proj_name.len == 0) {
                    const val = std.mem.trim(u8, line["name:".len..], " \t\"'");
                    if (val.len > 0) proj_name = try ctx.arena.dupe(u8, val);
                }
            } else if (std.mem.startsWith(u8, line, "project_tld:")) {
                const val = std.mem.trim(u8, line["project_tld:".len..], " \t\"'");
                if (val.len > 0) proj_tld = try ctx.arena.dupe(u8, val);
            }
        }
    }

    var scheme = ctx.envOrDefault("DDEV_SCHEME", "https");
    var base_domain: []const u8 = "";

    if (ctx.env("DDEV_PRIMARY_URL")) |primary_url| {
        if (primary_url.len > 0) {
            if (std.mem.indexOf(u8, primary_url, "://")) |sep_idx| {
                scheme = primary_url[0..sep_idx];
                const after_scheme = primary_url[sep_idx + 3 ..];
                if (std.mem.indexOfScalar(u8, after_scheme, '/')) |slash_idx| {
                    base_domain = after_scheme[0..slash_idx];
                } else {
                    base_domain = after_scheme;
                }
            } else {
                base_domain = primary_url;
            }
        }
    } else if (proj_name.len > 0) {
        base_domain = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ proj_name, proj_tld });
    }

    return .{
        .project_name = proj_name,
        .project_tld = proj_tld,
        .scheme = scheme,
        .base_domain = base_domain,
    };
}

pub fn updateDdevConfigYaml(
    ctx: *const Context,
    hub_dir: []const u8,
    project_name: []const u8,
    docroot_rel: []const u8,
    composer_root_rel: []const u8,
    ensure_hostnames: bool,
    ensure_docroot: bool,
) !void {
    const ddev_cfg_path = try Dir.path.join(ctx.arena, &.{ hub_dir, ".ddev", "config.yaml" });
    const content = io_util.readFileAlloc(ctx.arena, ctx.io, ddev_cfg_path) orelse return;

    var out_lines: std.ArrayList([]const u8) = .empty;
    var found_hostnames = false;
    var found_docroot = false;
    var found_composer_root = false;

    const wildcard_needle = try std.fmt.allocPrint(ctx.arena, "*.{s}", .{project_name});
    const has_wildcard_already = std.mem.indexOf(u8, content, wildcard_needle) != null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (ensure_hostnames and !has_wildcard_already and std.mem.startsWith(u8, line, "additional_hostnames:")) {
            found_hostnames = true;
            try out_lines.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "additional_hostnames: [\"*.{s}\"]", .{project_name}));
        } else if (ensure_docroot and std.mem.startsWith(u8, line, "docroot:")) {
            found_docroot = true;
            try out_lines.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "docroot: {s}", .{docroot_rel}));
        } else if (std.mem.startsWith(u8, line, "composer_root:")) {
            found_composer_root = true;
            try out_lines.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "composer_root: {s}", .{composer_root_rel}));
        } else {
            try out_lines.append(ctx.arena, line);
        }
    }

    // Remove trailing empty line before appending new keys so we don't leave blank gaps
    if (out_lines.items.len > 0 and out_lines.items[out_lines.items.len - 1].len == 0) {
        _ = out_lines.pop();
    }

    if (ensure_hostnames and !has_wildcard_already and !found_hostnames) {
        try out_lines.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "additional_hostnames: [\"*.{s}\"]", .{project_name}));
    }
    if (ensure_docroot and !found_docroot) {
        try out_lines.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "docroot: {s}", .{docroot_rel}));
    }
    if (!found_composer_root) {
        try out_lines.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "composer_root: {s}", .{composer_root_rel}));
    }

    var buf: std.ArrayList(u8) = .empty;
    for (out_lines.items) |l| {
        try buf.appendSlice(ctx.arena, l);
        try buf.append(ctx.arena, '\n');
    }
    try io_util.writeFile(ctx.io, ddev_cfg_path, buf.items, false);
}

test "ArboristConfig parse and override" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const sample =
        \\ENV_ENGINE=ddev
        \\WEBROOT=docroot
        \\DEFAULT_BRANCH="main"
        \\POST_PROVISION_CMD="ddev drush cr"
        \\POST_PROVISION_CMD=""
    ;
    const cfg = try ArboristConfig.parse(arena.allocator(), sample);
    try std.testing.expectEqualStrings("ddev", cfg.env_engine);
    try std.testing.expectEqualStrings("main", cfg.default_branch);
    try std.testing.expectEqualStrings("", cfg.post_provision_cmd);
}
