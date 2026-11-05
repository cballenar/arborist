const std = @import("std");
const Allocator = std.mem.Allocator;

/// Equivalent to:
/// echo "$branch" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/^-*//' -e 's/-*$//'
pub fn getWtDirName(allocator: Allocator, branch: []const u8) ![]u8 {
    return sanitizeBranch(allocator, branch, '-');
}

/// Equivalent to:
/// echo "db_$(echo "$branch" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/_/g' -e 's/^_*//' -e 's/_*$//')"
pub fn getDbName(allocator: Allocator, branch: []const u8) ![]u8 {
    const sanitized = try sanitizeBranch(allocator, branch, '_');
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "db_{s}", .{sanitized});
}

/// Legacy database name used for cleanup fallback in `remove`:
/// db_$(echo "$branch_to_remove" | sed 's/[^a-zA-Z0-9_]/_/g')
pub fn getLegacyDbName(allocator: Allocator, branch: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, branch.len + 3);
    @memcpy(buf[0..3], "db_");
    for (branch, 0..) |c, i| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            buf[3 + i] = c;
        } else {
            buf[3 + i] = '_';
        }
    }
    return buf;
}

fn sanitizeBranch(allocator: Allocator, branch: []const u8, sep: u8) ![]u8 {
    var temp = try allocator.alloc(u8, branch.len);
    defer allocator.free(temp);

    for (branch, 0..) |c, i| {
        const lower = std.ascii.toLower(c);
        if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) {
            temp[i] = lower;
        } else {
            temp[i] = sep;
        }
    }

    const trimmed = std.mem.trim(u8, temp, &[_]u8{sep});
    return allocator.dupe(u8, trimmed);
}

pub fn toLowerAlloc(allocator: Allocator, input: []const u8) ![]u8 {
    return std.ascii.allocLowerString(allocator, input);
}

pub fn isInCommaList(item: []const u8, list: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (std.mem.eql(u8, trimmed, item)) return true;
    }
    return false;
}

pub fn isInSpaceList(item: []const u8, list: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n");
    while (it.next()) |el| {
        if (std.mem.eql(u8, el, item)) return true;
    }
    return false;
}

pub fn isInSpaceListCi(item: []const u8, list: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n");
    while (it.next()) |el| {
        if (std.ascii.eqlIgnoreCase(el, item)) return true;
    }
    return false;
}

pub fn isInSlice(item: []const u8, slice: []const []const u8) bool {
    for (slice) |el| {
        if (std.mem.eql(u8, el, item)) return true;
    }
    return false;
}

pub fn isInSliceCi(item: []const u8, slice: []const []const u8) bool {
    for (slice) |el| {
        if (std.ascii.eqlIgnoreCase(el, item)) return true;
    }
    return false;
}

test "getWtDirName and getDbName sanitization" {
    const gpa = std.testing.allocator;

    {
        const wt = try getWtDirName(gpa, "bsph/dwc-27-test-feature");
        defer gpa.free(wt);
        try std.testing.expectEqualStrings("bsph-dwc-27-test-feature", wt);

        const db = try getDbName(gpa, "bsph/dwc-27-test-feature");
        defer gpa.free(db);
        try std.testing.expectEqualStrings("db_bsph_dwc_27_test_feature", db);
    }

    {
        const wt = try getWtDirName(gpa, "Feature/CAPS-99-Test");
        defer gpa.free(wt);
        try std.testing.expectEqualStrings("feature-caps-99-test", wt);

        const db = try getDbName(gpa, "Feature/CAPS-99-Test");
        defer gpa.free(db);
        try std.testing.expectEqualStrings("db_feature_caps_99_test", db);
    }

    {
        const wt = try getWtDirName(gpa, "bsph/release-2026-10.1");
        defer gpa.free(wt);
        try std.testing.expectEqualStrings("bsph-release-2026-10-1", wt);

        const db = try getDbName(gpa, "bsph/release-2026-10.1");
        defer gpa.free(db);
        try std.testing.expectEqualStrings("db_bsph_release_2026_10_1", db);
    }

    {
        const wt = try getWtDirName(gpa, "feature/v1.2.3_rc+1@test");
        defer gpa.free(wt);
        try std.testing.expectEqualStrings("feature-v1-2-3-rc-1-test", wt);

        const db = try getDbName(gpa, "feature/v1.2.3_rc+1@test");
        defer gpa.free(db);
        try std.testing.expectEqualStrings("db_feature_v1_2_3_rc_1_test", db);
    }

    {
        const wt = try getWtDirName(gpa, "--leading-and-trailing--");
        defer gpa.free(wt);
        try std.testing.expectEqualStrings("leading-and-trailing", wt);
    }
}

test "list membership helpers" {
    try std.testing.expect(isInCommaList("develop", "develop,main,master"));
    try std.testing.expect(isInCommaList("main", "develop,main,master"));
    try std.testing.expect(!isInCommaList("feature", "develop,main,master"));

    try std.testing.expect(isInSpaceList("db_one", "db db_one db_two\n"));
    try std.testing.expect(isInSpaceListCi("db_feature_caps", "db DB_Feature_Caps"));
}
