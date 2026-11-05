const std = @import("std");
const Dir = std.Io.Dir;
const io_util = @import("../io_util.zig");
const Context = io_util.Context;
const context = @import("../context.zig");
const git = @import("../git.zig");

pub fn runComplete(ctx: *const Context, args: []const []const u8) !void {
    const target_type = if (args.len > 0 and args[0].len > 0) args[0] else "worktrees";
    const hub_dir = context.findHubDir(ctx) orelse return;
    if (!io_util.dirExists(ctx.io, hub_dir)) return;

    var items: std.ArrayList([]const u8) = .empty;

    if (std.mem.eql(u8, target_type, "worktrees")) {
        const wts = try git.listWorktrees(ctx, hub_dir);
        for (wts) |wt| {
            if (wt.branch) |b| {
                try addUnique(&items, ctx.arena, b);
            }
            if (!std.mem.eql(u8, wt.path, hub_dir)) {
                const base = Dir.path.basename(wt.path);
                if (base.len > 0) {
                    try addUnique(&items, ctx.arena, base);
                }
            }
        }
        const local_branches = try git.listLocalBranches(ctx, hub_dir);
        for (local_branches) |lb| {
            try addUnique(&items, ctx.arena, lb.name);
        }
        const remote_branches = try git.listRemoteOriginBranches(ctx, hub_dir);
        for (remote_branches) |rb| {
            try addUnique(&items, ctx.arena, rb);
        }
    } else if (std.mem.eql(u8, target_type, "branches")) {
        const local_branches = try git.listLocalBranches(ctx, hub_dir);
        for (local_branches) |lb| {
            try addUnique(&items, ctx.arena, lb.name);
        }
    }

    std.mem.sort([]const u8, items.items, {}, lessThanStr);
    for (items.items) |item| {
        ctx.out("{s}", .{item});
    }
}

fn addUnique(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, val: []const u8) !void {
    if (val.len == 0) return;
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, val)) return;
    }
    try list.append(allocator, val);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn runHook(ctx: *const Context, args: []const []const u8) !void {
    if (args.len > 0) {
        const arg0 = args[0];
        if (std.mem.eql(u8, arg0, "-h") or std.mem.eql(u8, arg0, "--help") or std.mem.eql(u8, arg0, "help")) {
            ctx.outRaw(
                \\Usage: gar hook
                \\
                \\Output shell integration script for automatic directory switching and completions.
                \\
                \\Add to your shell configuration (~/.zshrc or ~/.bashrc):
                \\  eval "$(gar hook)"
                \\
            );
            return;
        }
    }

    const bin_path = ctx.exe_path;
    const hook_script = try std.fmt.allocPrint(
        ctx.arena,
        \\# Git Arborist (gar) shell integration
        \\gar() {{
        \\    if [ "$1" = "switch" ] || [ "$1" = "-m" ] || [ "$1" = "move" ] || [ "$1" = "mv" ]; then
        \\        local _cmd="$1"
        \\        shift
        \\        local _target_path
        \\        _target_path="$("{s}" "$_cmd" "$@")"
        \\        local _exit_code=$?
        \\        if [ $_exit_code -eq 0 ] && [ -n "$_target_path" ] && [ -d "$_target_path" ]; then
        \\            cd "$_target_path" || return 1
        \\        fi
        \\        return $_exit_code
        \\    else
        \\        "{s}" "$@"
        \\    fi
        \\}}
        \\alias arborist="gar"
        \\alias dbi="gar dbi"
        \\alias dbe="gar dbe"
        \\alias dbp="gar dbp"
        \\
        \\ddev() {{
        \\    if [ "$1" = "composer" ] || [ "$1" = "co" ]; then
        \\        local _subcmd="$1"
        \\        local _pass_through=false
        \\        local _arg
        \\        for _arg in "${{@:2}}"; do
        \\            case "$_arg" in
        \\                create-project|-h|--help|-d|--working-dir|-d*|--working-dir=*)
        \\                    _pass_through=true
        \\                    break
        \\                    ;;
        \\            esac
        \\        done
        \\        if [ "$_pass_through" = false ]; then
        \\            local _hub_dir=""
        \\            local _cur="$PWD"
        \\            while [ "$_cur" != "/" ]; do
        \\                if {{ [ -d "$_cur/.git" ] && [ -d "$_cur/.ddev" ]; }} || [ -f "$_cur/.arborist" ]; then
        \\                    _hub_dir="$_cur"
        \\                    break
        \\                fi
        \\                _cur=$(dirname "$_cur")
        \\            done
        \\            if [ -n "$_hub_dir" ] && {{ [ -f "$_hub_dir/.arborist" ] || [ ! -f "$_hub_dir/composer.json" ]; }}; then
        \\                local _wt_dir=""
        \\                local _top_wt=""
        \\                _cur="$PWD"
        \\                while [ "$_cur" != "$_hub_dir" ] && [ "$_cur" != "/" ]; do
        \\                    if [ -z "$_wt_dir" ] && [ -f "$_cur/composer.json" ]; then
        \\                        _wt_dir="$_cur"
        \\                    fi
        \\                    local _parent
        \\                    _parent=$(dirname "$_cur")
        \\                    if [ "$_parent" = "$_hub_dir" ]; then
        \\                        _top_wt="$_cur"
        \\                    fi
        \\                    _cur="$_parent"
        \\                done
        \\                if [ -z "$_wt_dir" ] && [ -n "$_top_wt" ]; then
        \\                    _wt_dir="$_top_wt"
        \\                fi
        \\                if [ -z "$_wt_dir" ] && [ "$PWD" = "$_hub_dir" ]; then
        \\                    local _def_branch="develop"
        \\                    if [ -f "$_hub_dir/.arborist" ]; then
        \\                        local _cfg_branch
        \\                        _cfg_branch=$(grep '^DEFAULT_BRANCH=' "$_hub_dir/.arborist" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" || true)
        \\                        [ -n "$_cfg_branch" ] && _def_branch="$_cfg_branch"
        \\                    fi
        \\                    local _def_wt
        \\                    _def_wt=$(echo "$_def_branch" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/^-*//' -e 's/-*$//')
        \\                    if [ -d "$_hub_dir/$_def_wt" ]; then
        \\                        _wt_dir="$_hub_dir/$_def_wt"
        \\                    fi
        \\                fi
        \\                if [ -n "$_wt_dir" ] && [[ "$_wt_dir" == "$_hub_dir/"* ]]; then
        \\                    local _rel_wt="${{_wt_dir#$_hub_dir/}}"
        \\                    shift
        \\                    command ddev "$_subcmd" --working-dir="/var/www/html/$_rel_wt" "$@"
        \\                    return $?
        \\                fi
        \\            fi
        \\        fi
        \\    fi
        \\    command ddev "$@"
        \\}}
        \\
        \\# Shell completion for Zsh and Bash
        \\if [ -n "$ZSH_VERSION" ]; then
        \\    _gar_zsh_complete() {{
        \\        local -a commands
        \\        commands=(
        \\            'init:Initialize a new Hub and baseline worktree'
        \\            'switch:Switch to a worktree or create a new one'
        \\            'move:Move or rename a worktree and database'
        \\            'mv:Move or rename a worktree and database'
        \\            '-m:Move or rename a worktree and database'
        \\            'list:List all worktrees, branches, and database mappings'
        \\            'info:Show engine, current branch, DB name, and site URL'
        \\            'prune:Prune orphaned worktrees, branches, and databases'
        \\            'remove:Remove a worktree, branch, and database'
        \\            'db:Database operations (import/export/provision)'
        \\            'dbi:Import database dump'
        \\            'dbe:Export database dump'
        \\            'dbp:Provision isolated database and run post-provision commands'
        \\            'sync:Synchronize Hub configs, wrappers, and scaffolds'
        \\            'sync-ddev:Synchronize Hub configs, wrappers, and scaffolds'
        \\            'install-hooks:Install Git hooks in the Hub'
        \\        )
        \\
        \\        if (( CURRENT == 2 )); then
        \\            _describe -t commands 'gar command' commands
        \\            return 0
        \\        fi
        \\
        \\        if [ "$words[CURRENT-1]" = "--target" ]; then
        \\            local -a branches
        \\            branches=($( "{s}" __complete branches 2>/dev/null ))
        \\            if (( ${{#branches}} > 0 )); then
        \\                _describe -t branches 'branch' branches
        \\            fi
        \\            return 0
        \\        fi
        \\
        \\        case "$words[2]" in
        \\            switch|remove|-m|move|mv)
        \\                local -a wts
        \\                wts=($( "{s}" __complete worktrees 2>/dev/null ))
        \\                if (( ${{#wts}} > 0 )); then
        \\                    _describe -t wts 'worktree / branch' wts
        \\                fi
        \\                ;;
        \\            db)
        \\                if (( CURRENT == 3 )); then
        \\                    local -a dbcmds
        \\                    dbcmds=('import:Import SQL dump' 'export:Export database' 'provision:Provision database and run post-provision commands')
        \\                    _describe -t dbcmds 'db command' dbcmds
        \\                fi
        \\                ;;
        \\            list)
        \\                local -a lopts
        \\                lopts=('-a:Also list Git branches without worktrees' '--all:Also list Git branches without worktrees' '-v:Show detailed multi-line workspace information' '--verbose:Show detailed multi-line workspace information')
        \\                _describe -t lopts 'list option' lopts
        \\                ;;
        \\            prune)
        \\                local -a popts
        \\                popts=('-f:Force prune without prompt' '--force:Force prune without prompt' '--dry-run:Preview pruned resources')
        \\                _describe -t popts 'prune option' popts
        \\                ;;
        \\        esac
        \\    }}
        \\    compdef _gar_zsh_complete gar arborist 2>/dev/null || true
        \\elif [ -n "$BASH_VERSION" ]; then
        \\    _gar_bash_complete() {{
        \\        local cur prev words cword
        \\        COMPREPLY=()
        \\        cur="${{COMP_WORDS[COMP_CWORD]}}"
        \\        prev="${{COMP_WORDS[COMP_CWORD-1]}}"
        \\
        \\        local commands="init switch move mv -m list info prune remove db dbi dbe dbp sync sync-ddev install-hooks -h help"
        \\
        \\        if [ "$COMP_CWORD" -eq 1 ]; then
        \\            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        \\            return 0
        \\        fi
        \\
        \\        case "$prev" in
        \\            switch|remove|-m|move|mv)
        \\                local wts
        \\                wts=$("{s}" __complete worktrees 2>/dev/null)
        \\                COMPREPLY=( $(compgen -W "$wts" -- "$cur") )
        \\                return 0
        \\                ;;
        \\            db)
        \\                COMPREPLY=( $(compgen -W "import export provision info" -- "$cur") )
        \\                return 0
        \\                ;;
        \\            list)
        \\                COMPREPLY=( $(compgen -W "-a --all -v --verbose" -- "$cur") )
        \\                return 0
        \\                ;;
        \\            prune)
        \\                COMPREPLY=( $(compgen -W "-f --force --dry-run" -- "$cur") )
        \\                return 0
        \\                ;;
        \\            --target)
        \\                local branches
        \\                branches=$("{s}" __complete branches 2>/dev/null)
        \\                COMPREPLY=( $(compgen -W "$branches" -- "$cur") )
        \\                return 0
        \\                ;;
        \\        esac
        \\    }}
        \\    complete -F _gar_bash_complete gar arborist 2>/dev/null || true
        \\fi
        \\
    ,
        .{ bin_path, bin_path, bin_path, bin_path, bin_path, bin_path },
    );

    ctx.outRaw(hook_script);
}
