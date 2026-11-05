const std = @import("std");
const io_util = @import("io_util.zig");
const Context = io_util.Context;

pub const naming = @import("naming.zig");
pub const config = @import("config.zig");
pub const context = @import("context.zig");
pub const git = @import("git.zig");
pub const ddev = @import("engine/ddev.zig");
pub const templates = @import("templates.zig");
pub const prompt = @import("prompt.zig");

const cmd_hook = @import("commands/hook.zig");
const cmd_info = @import("commands/info.zig");
const cmd_list = @import("commands/list.zig");
const cmd_sync = @import("commands/sync.zig");
const cmd_remove = @import("commands/remove.zig");
const cmd_move = @import("commands/move.zig");

const help_text =
    \\Git Arborist (gar) - Multi-worktree workspace manager
    \\
    \\Usage: gar <command> [options]
    \\
    \\Workspace Commands:
    \\  info                 Show current branch, database name, and site URL
    \\  list [-a] [-v]       List active worktrees, status, and site URLs
    \\  switch [branch]      Switch to a worktree, checkout remote, or create new (-c, -y, --clone)
    \\  move [old] <new>     Rename a worktree, branch, and database (aliases: mv, -m)
    \\  remove [-f] <branch> Remove a worktree, branch, and isolated database
    \\
    \\Database Commands:
    \\  dbi [options]        Import SQL dump into database          (gar db import)
    \\  dbe [options]        Export database to SQL dump            (gar db export)
    \\  dbp [options]        Import/clone DB & run post-provision   (gar db provision)
    \\
    \\Setup & Maintenance:
    \\  init <url> [dir]     Initialize a new Arborist Hub (dir defaults to repo name)
    \\  sync                 Re-apply templates, hooks, and command wrappers to the Hub
    \\  prune [-f|--dry-run] Clean up orphaned worktrees, branches, and databases
    \\  hook                 Output shell integration hook for eval in ~/.zshrc or ~/.bashrc
    \\
    \\Run 'gar <command> -h' for details on a specific command.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const invocation_dir = try std.process.currentPathAlloc(io, arena);
    const exe_path = std.process.executablePathAlloc(io, arena) catch "arborist";

    const ctx = Context{
        .arena = arena,
        .gpa = init.gpa,
        .io = io,
        .environ_map = init.environ_map,
        .invocation_dir = invocation_dir,
        .exe_path = exe_path,
    };

    const args = try init.minimal.args.toSlice(arena);
    const command = if (args.len > 1) args[1] else "";
    const sub_args = if (args.len > 2) args[2..] else &[_][]const u8{};

    if (command.len == 0 or
        std.mem.eql(u8, command, "-h") or
        std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "help"))
    {
        ctx.outRaw(help_text);
        return;
    }

    if (std.mem.eql(u8, command, "__complete")) {
        try cmd_hook.runComplete(&ctx, sub_args);
        return;
    }

    if (std.mem.eql(u8, command, "hook")) {
        try cmd_hook.runHook(&ctx, sub_args);
        return;
    }

    if (std.mem.eql(u8, command, "info")) {
        try cmd_info.run(&ctx, sub_args);
        return;
    }

    if (std.mem.eql(u8, command, "list")) {
        try cmd_list.run(&ctx, sub_args);
        return;
    }

    if (std.mem.eql(u8, command, "sync") or
        std.mem.eql(u8, command, "update") or
        std.mem.eql(u8, command, "sync-ddev"))
    {
        try cmd_sync.run(&ctx, sub_args);
        return;
    }

    if (std.mem.eql(u8, command, "install-hooks")) {
        try cmd_sync.runInstallHooks(&ctx);
        return;
    }

    if (std.mem.eql(u8, command, "remove")) {
        try cmd_remove.run(&ctx, sub_args);
        return;
    }

    if (std.mem.eql(u8, command, "move") or
        std.mem.eql(u8, command, "mv") or
        std.mem.eql(u8, command, "-m"))
    {
        try cmd_move.run(&ctx, sub_args);
        return;
    }

    ctx.errorExit("Unknown command: {s}\nRun 'gar -h' to see available commands.", .{command});
}

test {
    _ = naming;
    _ = config;
    _ = context;
    _ = git;
    _ = ddev;
    _ = templates;
    _ = prompt;
}
