const std = @import("std");
const io_util = @import("../io_util.zig");
const Context = io_util.Context;
const context = @import("../context.zig");
const config = @import("../config.zig");
const naming = @import("../naming.zig");
const git = @import("../git.zig");
const ddev = @import("../engine/ddev.zig");

const WorkspaceRow = struct {
    is_active: bool,
    icon: []const u8,
    status_text: []const u8,
    branch: []const u8,
    wt_rel: []const u8,
    db_name: []const u8,
    db_display: []const u8,
    db_status: []const u8,
    url: []const u8,
};

pub fn run(ctx: *const Context, args: []const []const u8) !void {
    var show_all = false;
    var verbose = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            show_all = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-av") or std.mem.eql(u8, arg, "-va")) {
            show_all = true;
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            ctx.log(
                \\Usage: gar list [options]
                \\
                \\List active worktrees, status, and site URLs.
                \\
                \\Options:
                \\  -a, --all        Also list Git branches without worktrees
                \\  -v, --verbose    Show detailed multi-line workspace information
                \\  -h, --help       Show this help message
            , .{});
            return;
        }
    }

    const hub_dir = context.requireHubDir(ctx);
    const cfg = try config.ArboristConfig.load(ctx, hub_dir);

    var ddev_running = false;
    var existing_dbs: [][]const u8 = &.{};
    if (std.mem.eql(u8, cfg.env_engine, "ddev")) {
        const db_res = try ddev.queryDatabases(ctx, hub_dir, true);
        ddev_running = db_res.running;
        existing_dbs = db_res.dbs;
    }

    const domain_info = if (std.mem.eql(u8, cfg.env_engine, "ddev"))
        try config.getDdevDomainInfo(ctx, hub_dir)
    else
        config.DdevDomainInfo{ .project_name = "", .project_tld = "", .scheme = "https", .base_domain = "" };

    const real_hub = try io_util.realPathOrCopy(ctx.arena, ctx.io, hub_dir);
    const real_invoc = try io_util.realPathOrCopy(ctx.arena, ctx.io, ctx.invocation_dir);

    const active_info = try context.detectActiveWorktree(ctx, hub_dir);
    const current_wt_top: ?[]const u8 = if (active_info.wt_top) |top|
        try io_util.realPathOrCopy(ctx.arena, ctx.io, top)
    else
        null;

    var current_active_branch: []const u8 = "";
    if (active_info.branch) |b| {
        current_active_branch = b;
    } else {
        const hub_head = try io_util.runCapture(ctx, &.{ "git", "-C", hub_dir, "rev-parse", "--abbrev-ref", "HEAD" }, null);
        if (hub_head.success()) {
            const hb = std.mem.trim(u8, hub_head.stdout, " \t\r\n");
            if (hb.len > 0 and !std.mem.eql(u8, hb, "HEAD")) {
                current_active_branch = try ctx.arena.dupe(u8, hb);
            }
        }
        if (current_active_branch.len == 0) {
            current_active_branch = cfg.default_branch;
        }
    }

    ctx.log("=== Git Arborist Workspaces & Databases ===", .{});
    ctx.log("Hub: {s}", .{hub_dir});
    if (std.mem.eql(u8, cfg.env_engine, "ddev") and !ddev_running) {
        ctx.log("\x1b[33mNote:\x1b[0m DDEV is not running. Database status cannot be queried.", .{});
    }
    ctx.log("", .{});

    var processed_branches: std.ArrayList([]const u8) = .empty;
    var processed_dbs: std.ArrayList([]const u8) = .empty;
    var rows: std.ArrayList(WorkspaceRow) = .empty;

    const wts = try git.listWorktrees(ctx, hub_dir);
    const real_hub_slash = try std.fmt.allocPrint(ctx.arena, "{s}/", .{real_hub});

    for (wts) |wt| {
        if (wt.is_bare) continue;
        const branch = wt.branch orelse continue;

        const real_wt = try io_util.realPathOrCopy(ctx.arena, ctx.io, wt.path);
        const wt_rel = if (std.mem.startsWith(u8, real_wt, real_hub_slash))
            try std.fmt.allocPrint(ctx.arena, "./{s}", .{real_wt[real_hub_slash.len..]})
        else
            wt.path;

        try processed_branches.append(ctx.arena, branch);

        const db_name = if (std.mem.eql(u8, branch, cfg.default_branch))
            "db"
        else
            try naming.getDbName(ctx.arena, branch);
        try processed_dbs.append(ctx.arena, db_name);

        const track = if (!std.mem.eql(u8, branch, "detached"))
            try git.getBranchTrack(ctx, hub_dir, branch)
        else
            "";

        var is_active = false;
        if (current_wt_top) |wt_top| {
            const real_wt_slash = try std.fmt.allocPrint(ctx.arena, "{s}/", .{real_wt});
            if (std.ascii.eqlIgnoreCase(real_wt, wt_top) or std.ascii.eqlIgnoreCase(branch, current_active_branch)) {
                is_active = true;
            } else if (std.ascii.eqlIgnoreCase(real_invoc, real_wt) or
                (real_invoc.len > real_wt_slash.len and std.ascii.startsWithIgnoreCase(real_invoc, real_wt_slash)))
            {
                is_active = true;
            }
        } else {
            if (std.ascii.eqlIgnoreCase(branch, current_active_branch)) {
                is_active = true;
            }
        }

        var icon: []const u8 = "⚪";
        var status_text: []const u8 = "Valid";

        if (is_active) {
            icon = "🟢";
            status_text = if (std.mem.eql(u8, track, "[gone]")) "Current ([gone])" else "Current";
        } else if (std.mem.eql(u8, track, "[gone]")) {
            icon = "🔴";
            status_text = "Orphaned ([gone])";
        } else if (naming.isInCommaList(branch, cfg.protected_branches)) {
            icon = "🟡";
            status_text = "Protected";
        }

        var db_status: []const u8 = "Ready";
        var db_display: []const u8 = db_name;
        if (!ddev_running) {
            db_status = "Unknown";
            db_display = db_name;
        } else if (std.mem.eql(u8, branch, cfg.default_branch)) {
            if (naming.isInSlice("db", existing_dbs)) {
                db_status = "Default";
                db_display = "db";
            } else {
                db_status = "Missing";
                db_display = "Missing";
            }
        } else {
            if (naming.isInSliceCi(db_name, existing_dbs)) {
                db_status = "Ready";
                db_display = db_name;
            } else {
                db_status = "Missing";
                db_display = "Missing";
            }
        }

        const url = if (domain_info.base_domain.len > 0) blk: {
            if (std.ascii.eqlIgnoreCase(branch, cfg.default_branch)) {
                break :blk try std.fmt.allocPrint(ctx.arena, "{s}://{s} ({s})", .{
                    domain_info.scheme,
                    domain_info.base_domain,
                    branch,
                });
            } else {
                const subdomain = try naming.getWtDirName(ctx.arena, branch);
                break :blk try std.fmt.allocPrint(ctx.arena, "{s}://{s}.{s}", .{
                    domain_info.scheme,
                    subdomain,
                    domain_info.base_domain,
                });
            }
        } else branch;

        try rows.append(ctx.arena, .{
            .is_active = is_active,
            .icon = icon,
            .status_text = status_text,
            .branch = branch,
            .wt_rel = wt_rel,
            .db_name = db_name,
            .db_display = db_display,
            .db_status = db_status,
            .url = url,
        });
    }

    // 2. Databases in MySQL without worktree
    if (ddev_running) {
        for (existing_dbs) |db| {
            if (!naming.isInSliceCi(db, processed_dbs.items)) {
                var icon: []const u8 = "🔴";
                var status_text: []const u8 = "Orphaned";
                var db_status: []const u8 = "Orphaned";

                if (std.mem.eql(u8, db, "db")) {
                    icon = "🟡";
                    status_text = "Protected";
                    db_status = "Default";
                }

                try rows.append(ctx.arena, .{
                    .is_active = false,
                    .icon = icon,
                    .status_text = status_text,
                    .branch = "<none>",
                    .wt_rel = "<none>",
                    .db_name = db,
                    .db_display = db,
                    .db_status = db_status,
                    .url = try std.fmt.allocPrint(ctx.arena, "Database: {s}", .{db}),
                });
            }
        }
    }

    // 3. Optional: List branches without worktrees when --all is passed
    if (show_all) {
        const local_branches = try git.listLocalBranches(ctx, hub_dir);
        for (local_branches) |lb| {
            if (!naming.isInSlice(lb.name, processed_branches.items)) {
                const db_name = if (std.mem.eql(u8, lb.name, cfg.default_branch))
                    "db"
                else
                    try naming.getDbName(ctx.arena, lb.name);

                var icon: []const u8 = "⚪";
                var status_text: []const u8 = "No worktree";
                if (std.mem.eql(u8, lb.track, "[gone]")) {
                    icon = "🔴";
                    status_text = "Orphaned ([gone])";
                } else if (naming.isInCommaList(lb.name, cfg.protected_branches)) {
                    icon = "🟡";
                    status_text = "Protected";
                }

                var db_status: []const u8 = "No worktree";
                var db_display: []const u8 = "Missing";
                if (ddev_running) {
                    if (naming.isInSliceCi(db_name, existing_dbs)) {
                        db_status = "Ready";
                        db_display = db_name;
                    }
                } else {
                    db_status = "Unknown";
                    db_display = db_name;
                }

                try rows.append(ctx.arena, .{
                    .is_active = false,
                    .icon = icon,
                    .status_text = status_text,
                    .branch = lb.name,
                    .wt_rel = "<none>",
                    .db_name = db_name,
                    .db_display = db_display,
                    .db_status = db_status,
                    .url = try std.fmt.allocPrint(ctx.arena, "Branch: {s}", .{lb.name}),
                });
            }
        }
    }

    // Sort order: 1. Current workspace, 2. Protected branches, 3. Remaining workspaces
    var sorted: std.ArrayList(WorkspaceRow) = .empty;
    for (rows.items) |r| {
        if (r.is_active) try sorted.append(ctx.arena, r);
    }
    for (rows.items) |r| {
        if (!r.is_active and std.mem.eql(u8, r.status_text, "Protected")) try sorted.append(ctx.arena, r);
    }
    for (rows.items) |r| {
        if (!r.is_active and !std.mem.eql(u8, r.status_text, "Protected")) try sorted.append(ctx.arena, r);
    }

    if (verbose) {
        for (sorted.items) |r| {
            const cur_suffix = if (r.is_active) " (current)" else "";
            ctx.log("Branch:    {s}{s}", .{ r.branch, cur_suffix });
            ctx.log("Status:    {s} {s}", .{ r.icon, r.status_text });
            ctx.log("Worktree:  {s}", .{r.wt_rel});
            ctx.log("Database:  {s} ({s})", .{ r.db_name, r.db_status });
            ctx.log("URL:       {s}", .{r.url});
            ctx.log("", .{});
        }
        return;
    }

    // Compact table
    var max_s: usize = 6; // "STATUS"
    var max_u: usize = 3; // "URL"
    for (sorted.items) |r| {
        if (r.status_text.len > max_s) max_s = r.status_text.len;
        if (r.url.len > max_u) max_u = r.url.len;
    }

    const visual_status_width = max_s + 3;
    const sep_s = try repeatChar(ctx.arena, '-', visual_status_width);
    const sep_u = try repeatChar(ctx.arena, '-', max_u);
    const header_s = try padRight(ctx.arena, "STATUS", visual_status_width);

    ctx.log("{s}  URL", .{header_s});
    ctx.log("{s}  {s}", .{ sep_s, sep_u });

    for (sorted.items) |r| {
        const padded_status = try padRight(ctx.arena, r.status_text, max_s);
        ctx.log("{s} {s}  {s}", .{ r.icon, padded_status, r.url });
    }
}

fn repeatChar(allocator: std.mem.Allocator, ch: u8, count: usize) ![]u8 {
    const buf = try allocator.alloc(u8, count);
    @memset(buf, ch);
    return buf;
}

fn padRight(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    if (text.len >= width) return allocator.dupe(u8, text);
    const buf = try allocator.alloc(u8, width);
    @memcpy(buf[0..text.len], text);
    @memset(buf[text.len..], ' ');
    return buf;
}
