const std = @import("std");
const Allocator = std.mem.Allocator;
const io_util = @import("io_util.zig");
const Context = io_util.Context;

pub const WorktreeEntry = struct {
    path: []const u8,
    branch: ?[]const u8,
    is_bare: bool,
};

pub fn listWorktrees(ctx: *const Context, hub_dir: []const u8) ![]WorktreeEntry {
    const res = try io_util.runCapture(ctx, &.{ "git", "-C", hub_dir, "worktree", "list", "--porcelain" }, null);
    if (!res.success()) return &.{};
    return parsePorcelainWorktrees(ctx.arena, res.stdout);
}

pub fn parsePorcelainWorktrees(allocator: Allocator, output: []const u8) ![]WorktreeEntry {
    var list: std.ArrayList(WorktreeEntry) = .empty;
    var cur_wt: ?[]const u8 = null;
    var cur_branch: ?[]const u8 = null;
    var is_bare = false;

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "worktree ")) {
            if (cur_wt) |wt| {
                try list.append(allocator, .{
                    .path = wt,
                    .branch = cur_branch,
                    .is_bare = is_bare,
                });
            }
            cur_wt = try allocator.dupe(u8, std.mem.trimStart(u8, line["worktree ".len..], " \t"));
            cur_branch = null;
            is_bare = false;
        } else if (std.mem.eql(u8, line, "bare")) {
            is_bare = true;
        } else if (std.mem.startsWith(u8, line, "branch refs/heads/")) {
            cur_branch = try allocator.dupe(u8, line["branch refs/heads/".len..]);
        } else if (line.len == 0) {
            if (cur_wt) |wt| {
                try list.append(allocator, .{
                    .path = wt,
                    .branch = cur_branch,
                    .is_bare = is_bare,
                });
                cur_wt = null;
                cur_branch = null;
                is_bare = false;
            }
        }
    }
    if (cur_wt) |wt| {
        try list.append(allocator, .{
            .path = wt,
            .branch = cur_branch,
            .is_bare = is_bare,
        });
    }
    return list.toOwnedSlice(allocator);
}

pub const BranchRef = struct {
    name: []const u8,
    track: []const u8,
    upstream: []const u8,
};

pub fn listLocalBranches(ctx: *const Context, hub_dir: []const u8) ![]BranchRef {
    const res = try io_util.runCapture(
        ctx,
        &.{ "git", "-C", hub_dir, "for-each-ref", "--format=%(refname:short)|%(upstream:track)|%(upstream:short)", "refs/heads" },
        null,
    );
    if (!res.success()) return &.{};

    var list: std.ArrayList(BranchRef) = .empty;
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, '|');
        const bname = parts.next() orelse continue;
        if (bname.len == 0) continue;
        const btrack = parts.next() orelse "";
        const bupstream = parts.next() orelse "";
        try list.append(ctx.arena, .{
            .name = try ctx.arena.dupe(u8, bname),
            .track = try ctx.arena.dupe(u8, btrack),
            .upstream = try ctx.arena.dupe(u8, bupstream),
        });
    }
    return list.toOwnedSlice(ctx.arena);
}

pub fn listRemoteOriginBranches(ctx: *const Context, hub_dir: []const u8) ![][]const u8 {
    const res = try io_util.runCapture(
        ctx,
        &.{ "git", "-C", hub_dir, "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin" },
        null,
    );
    if (!res.success()) return &.{};

    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or std.mem.eql(u8, line, "origin/HEAD") or std.mem.eql(u8, line, "origin")) continue;
        const stripped = if (std.mem.startsWith(u8, line, "origin/")) line["origin/".len..] else line;
        if (stripped.len == 0 or std.mem.eql(u8, stripped, "HEAD")) continue;
        try list.append(ctx.arena, try ctx.arena.dupe(u8, stripped));
    }
    return list.toOwnedSlice(ctx.arena);
}

pub fn showRefVerify(ctx: *const Context, hub_dir: []const u8, ref: []const u8) bool {
    return io_util.runQuiet(ctx, &.{ "git", "-C", hub_dir, "show-ref", "--verify", "--quiet", ref }, null);
}

pub fn getBranchTrack(ctx: *const Context, hub_dir: []const u8, branch: []const u8) ![]const u8 {
    const ref = try std.fmt.allocPrint(ctx.arena, "refs/heads/{s}", .{branch});
    const res = try io_util.runCapture(ctx, &.{ "git", "-C", hub_dir, "for-each-ref", "--format=%(upstream:track)", ref }, null);
    if (!res.success()) return "";
    return ctx.arena.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

pub fn getBranchUpstreamShort(ctx: *const Context, hub_dir: []const u8, branch: []const u8) ![]const u8 {
    const ref = try std.fmt.allocPrint(ctx.arena, "refs/heads/{s}", .{branch});
    const res = try io_util.runCapture(ctx, &.{ "git", "-C", hub_dir, "for-each-ref", "--format=%(upstream:short)", ref }, null);
    if (!res.success()) return "";
    return ctx.arena.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

pub fn detectDefaultBranch(ctx: *const Context, hub_dir: []const u8) ![]const u8 {
    const sym_res = try io_util.runCapture(ctx, &.{ "git", "-C", hub_dir, "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, null);
    if (sym_res.success()) {
        const trimmed = std.mem.trim(u8, sym_res.stdout, " \t\r\n");
        const stripped = if (std.mem.startsWith(u8, trimmed, "origin/")) trimmed["origin/".len..] else trimmed;
        if (stripped.len > 0 and !std.mem.eql(u8, stripped, "HEAD")) {
            return ctx.arena.dupe(u8, stripped);
        }
    }
    const rev_res = try io_util.runCapture(ctx, &.{ "git", "-C", hub_dir, "rev-parse", "--abbrev-ref", "HEAD" }, null);
    if (rev_res.success()) {
        const trimmed = std.mem.trim(u8, rev_res.stdout, " \t\r\n");
        if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "HEAD")) {
            return ctx.arena.dupe(u8, trimmed);
        }
    }
    return "develop";
}

test "parsePorcelainWorktrees" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const sample =
        \\worktree /tmp/hub
        \\bare
        \\
        \\worktree /tmp/hub/develop
        \\HEAD 7301edf000000000000000000000000000000000
        \\branch refs/heads/develop
        \\
        \\worktree /tmp/hub/bsph-dwc-27
        \\HEAD 7301edf000000000000000000000000000000000
        \\branch refs/heads/bsph/dwc-27
        \\
    ;

    const wts = try parsePorcelainWorktrees(arena.allocator(), sample);
    try std.testing.expectEqual(@as(usize, 3), wts.len);
    try std.testing.expect(wts[0].is_bare);
    try std.testing.expect(!wts[1].is_bare);
    try std.testing.expectEqualStrings("/tmp/hub/develop", wts[1].path);
    try std.testing.expectEqualStrings("develop", wts[1].branch.?);
    try std.testing.expectEqualStrings("bsph/dwc-27", wts[2].branch.?);
}
