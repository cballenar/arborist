const std = @import("std");
const Dir = std.Io.Dir;
const io_util = @import("../io_util.zig");
const Context = io_util.Context;

pub fn isRunning(ctx: *const Context, hub_dir: ?[]const u8) bool {
    if (!io_util.commandExists(ctx, "ddev")) return false;
    return io_util.runQuiet(ctx, &.{ "ddev", "describe" }, hub_dir);
}

pub fn flushEnvSync(ctx: *const Context, env_engine: []const u8, hub_dir: ?[]const u8) void {
    if (std.mem.eql(u8, env_engine, "ddev")) {
        if (isRunning(ctx, hub_dir)) {
            _ = io_util.runQuiet(ctx, &.{ "ddev", "mutagen", "sync" }, hub_dir);
        }
    }
}

pub const DbQueryResult = struct {
    running: bool,
    dbs: [][]const u8,
};

pub fn queryDatabases(ctx: *const Context, hub_dir: []const u8, filter_db_prefix: bool) !DbQueryResult {
    if (ctx.env("GAR_MOCK_DBS")) |mock_dbs| {
        if (mock_dbs.len > 0) {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, mock_dbs, " \t\r\n");
            while (it.next()) |item| {
                try list.append(ctx.arena, try ctx.arena.dupe(u8, item));
            }
            return .{
                .running = true,
                .dbs = try list.toOwnedSlice(ctx.arena),
            };
        }
    }

    if (!io_util.commandExists(ctx, "ddev")) {
        return .{ .running = false, .dbs = &.{} };
    }

    const res = try io_util.runCapture(ctx, &.{ "ddev", "mysql", "-N", "-e", "SHOW DATABASES;" }, hub_dir);
    if (!res.success()) {
        return .{ .running = false, .dbs = &.{} };
    }

    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |raw_line| {
        // Strip '|' and whitespace just like `tr -d '| '`
        var cleaned: std.ArrayList(u8) = .empty;
        for (raw_line) |c| {
            if (c != '|' and c != ' ' and c != '\t' and c != '\r') {
                try cleaned.append(ctx.arena, c);
            }
        }
        const db_name = cleaned.items;
        if (db_name.len == 0) continue;
        if (filter_db_prefix) {
            if (!std.mem.eql(u8, db_name, "db") and !std.mem.startsWith(u8, db_name, "db_")) {
                continue;
            }
        }
        try list.append(ctx.arena, try ctx.arena.dupe(u8, db_name));
    }

    return .{
        .running = true,
        .dbs = try list.toOwnedSlice(ctx.arena),
    };
}

pub fn createDatabase(ctx: *const Context, hub_dir: []const u8, db_name: []const u8) !void {
    const query = try std.fmt.allocPrint(ctx.arena, "CREATE DATABASE IF NOT EXISTS `{s}`;", .{db_name});
    _ = io_util.runInheritStderr(ctx, &.{ "ddev", "mysql", "-e", query }, hub_dir) catch {};
}

pub fn dropDatabase(ctx: *const Context, hub_dir: []const u8, db_name: []const u8, if_exists: bool) !void {
    const query = if (if_exists)
        try std.fmt.allocPrint(ctx.arena, "DROP DATABASE IF EXISTS `{s}`;", .{db_name})
    else
        try std.fmt.allocPrint(ctx.arena, "DROP DATABASE `{s}`;", .{db_name});
    _ = io_util.runInheritStderr(ctx, &.{ "ddev", "mysql", "-e", query }, hub_dir) catch {};
}

pub fn importDb(ctx: *const Context, hub_dir: []const u8, db_name: []const u8, file_path: []const u8) !u8 {
    const db_arg = try std.fmt.allocPrint(ctx.arena, "--database={s}", .{db_name});
    const file_arg = try std.fmt.allocPrint(ctx.arena, "--file={s}", .{file_path});
    return io_util.runInheritStderr(ctx, &.{ "ddev", "import-db", db_arg, file_arg }, hub_dir);
}

pub fn exportDb(ctx: *const Context, hub_dir: []const u8, db_name: []const u8, file_path: []const u8) !u8 {
    const db_arg = try std.fmt.allocPrint(ctx.arena, "--database={s}", .{db_name});
    const file_arg = try std.fmt.allocPrint(ctx.arena, "--file={s}", .{file_path});
    return io_util.runInheritStderr(ctx, &.{ "ddev", "export-db", db_arg, file_arg }, hub_dir);
}

pub fn cloneDatabase(ctx: *const Context, hub_dir: []const u8, src_db: []const u8, dst_db: []const u8) !u8 {
    const cmd = try std.fmt.allocPrint(
        ctx.arena,
        "ddev export-db --gzip=false --database=\"{s}\" | ddev import-db --database=\"{s}\"",
        .{ src_db, dst_db },
    );
    return io_util.runShellCommand(ctx, cmd, hub_dir);
}

pub fn isDumpFileName(name: []const u8) bool {
    const valid_exts = [_][]const u8{
        ".sql",
        ".sql.gz",
        ".sql.bz2",
        ".sql.xz",
        ".mysql",
        ".mysql.gz",
        ".tar",
        ".tar.gz",
        ".tgz",
        ".zip",
    };
    for (valid_exts) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

fn findLatestInDir(ctx: *const Context, dir_path: []const u8) ?[]const u8 {
    var dir = Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(ctx.io);

    var latest_path: ?[]const u8 = null;
    var latest_mtime: i96 = std.math.minInt(i96);

    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (!isDumpFileName(entry.name)) continue;
        const full_path = Dir.path.join(ctx.arena, &.{ dir_path, entry.name }) catch continue;
        const st = Dir.cwd().statFile(ctx.io, full_path, .{ .follow_symlinks = true }) catch continue;
        if (st.kind != .file) continue;

        if (latest_path == null or st.mtime.nanoseconds > latest_mtime) {
            latest_mtime = st.mtime.nanoseconds;
            latest_path = full_path;
        }
    }
    return latest_path;
}

pub fn getLatestBackupFile(ctx: *const Context, hub_dir: []const u8, search_path: []const u8) ?[]const u8 {
    if (search_path.len > 0) {
        const backup_source = if (Dir.path.isAbsolute(search_path))
            search_path
        else
            Dir.path.join(ctx.arena, &.{ hub_dir, search_path }) catch "";

        if (backup_source.len > 0) {
            if (io_util.fileExists(ctx.io, backup_source)) {
                return backup_source;
            } else if (io_util.dirExists(ctx.io, backup_source)) {
                if (findLatestInDir(ctx, backup_source)) |latest| {
                    return latest;
                }
            }
        }
    }

    const common_dirs = [_][]const u8{ "backups", "dumps", "dump", "db", ".ddev/db-backups" };
    for (common_dirs) |fallback| {
        if (!std.mem.eql(u8, fallback, search_path)) {
            const candidate_dir = Dir.path.join(ctx.arena, &.{ hub_dir, fallback }) catch continue;
            if (io_util.dirExists(ctx.io, candidate_dir)) {
                if (findLatestInDir(ctx, candidate_dir)) |latest| {
                    return latest;
                }
            }
        }
    }

    return null;
}
