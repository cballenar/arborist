# 🌳 Git Arborist (`gar`)

**Arborist** is a high-performance workspace manager for local web development (DDEV, Lando, Docker). 

By leveraging native **Git Worktrees** and **Sparse-Checkouts**, Arborist moves development away from disruptive, in-place branch checking out and re-indexing. Instead, it provides a clean **Hub-and-Spoke** architecture where multiple feature branches run concurrently under a single, shared environment hub.


## Who Is This For?

* Developers switching between branches and PR reviews tied to a database.
* Projects with relational databases (Drupal, Craft CMS, Laravel, WordPress, etc.) where changes to data from one branch may conflict with another.
* Workflows pairing with AI coding agents running concurrent tasks.


## Why Arborist?

In a traditional single-directory workflow, checking out branches in-place is disruptive and can invalidate application/caches, trigger sync latency, and force re-running dependency steps, e.g., `composer/npm install`.

Arborist replaces branch hopping with a persistent **Hub-and-Spoke** model:

| Traditional Branch Switching | With Arborist (`gar`) |
| :--- | :--- |
| Single directory checkout in-place | Dedicated directory per branch / worktree |
| Sync latency, volume re-scans & cache churn on checkout | Instant switching; worktrees persist side-by-side |
| Stashing uncommitted work & rebuilding dependencies | Fully isolated working directories, dependencies, and build assets |
| Manual database backups to test destructive migrations | On-demand branch DB cloning with automatic fallback to shared DB |
| Single-threaded: only one branch accessible at a time | Multi-threaded: run, review, and develop branches concurrently |


## Architecture

* **Hub-and-Spoke:** The root project directory is a bare Git repository (Hub) containing all active branches as parallel sibling worktrees.
* **Detached Environment:** Environment configurations (e.g. `.ddev`, `.lando.yml`) reside exclusively at the Hub root, physically separated from the code branches.
* **Sparse-Checkouts:** Each worktree automatically excludes tracked environment directories (`!/.ddev/`, `!/.lando.yml`, etc.), preventing configuration collisions.
* **Context Traversal:** Running CLI tools (like `ddev drush` or `composer`) inside any worktree directory automatically traverses upward to the Hub environment.
* **Shell Integration:** A lightweight wrapper catches directory changes and automatically `cd`s your active shell into the destination worktree.


## Installation

Arborist supports both interactive developer terminals (with automatic `cd` into worktrees) and non-interactive environments (AI agents, automation scripts, CI/CD).

```bash
./install.sh
source ~/.zshrc   # or ~/.bashrc
```

`./install.sh` automatically configures both:
1. **Standalone executable symlinks** in your standard `$PATH` (`/opt/homebrew/bin`, `/usr/local/bin`, or `~/.local/bin`), so AI agents, background subshells, and scripts can call `gar` directly without needing `.zshrc`.
2. **Interactive shell hook** in your shell profile (`~/.zshrc` or `~/.bashrc`) so that human developer commands automatically `cd` into newly switched or moved worktrees with full tab autocompletion.

* To re-install or update without confirmation prompt: `./install.sh -f`
* To remove the shell integration and standalone symlinks: `./install.sh --uninstall`

### Manual Installation
If you would rather install this manually:

1. Clone this repository to your preferred tools directory (e.g. `~/.local/share/arborist`).
2. Add the dynamic shell hook to your `~/.zshrc` or `~/.bashrc`:
   ```bash
   eval "$(/path/to/arborist/bin/arborist hook)"
   ```
3. Reload your shell:
   ```bash
   source ~/.zshrc   # or ~/.bashrc
   ```

You can run `/path/to/arborist/bin/arborist hook` in your terminal anytime to inspect the exact ~15 lines of shell function code being loaded.


### Tab Autocompletion

Arborist includes built-in tab autocompletion for both **Zsh** and **Bash**. When shell integration is enabled via `./install.sh` or `eval "$(gar hook)"`, hitting `<Tab>` automatically completes:
* Subcommands (`switch`, `move`, `mv`, `-m`, `list`, `prune`, `remove`, `db`, `dbi`, `dbe`, `dbp`, etc.)
* Active worktrees and Git branches for `switch`, `move`, `mv`, `-m`, and `remove`
* Database subcommands (`import`, `export`, `provision`, `info`) and `--target` branch completion
* Flags for commands such as `prune` (`-f`, `--force`, `--dry-run`) and `remove` (`-f`, `--force`)


## Usage

The primary command is `gar`, with `arborist` available as the full command. Run `gar -h` to see the help output.
```bash
gar -h
```


### Initialize a Workspace Hub (`gar init`)

Run the interactive wizard on any remote repository:
```bash
gar init <git_repo_url> [hub_directory_name]
```

The wizard guides you through:
* **Engine Selection:** Detects and extracts DDEV, Lando, or Docker Compose configurations.
* **Sparse Exclusions:** Excludes environment files and lets you specify extra heavy paths (e.g., `tests`, `docs`).
* **Webroot & Framework Integration:** Auto-detects `docroot`, `web`, or `public`, and automatically configures wildcard Nginx routing and database fallback.
* **Permanent Branches:** Automatically provisions your tracking branch (e.g., `develop` or `main`) and any additional baseline branches.


### Switch or Create Worktrees (`gar switch`)

Switch to an existing worktree (and automatically `cd` into it):
```bash
gar switch feature-branch
```

Arborist includes built-in switch ergonomics:
* **No-argument switch:** Running `gar switch` with no arguments automatically returns to your baseline tracking branch (`develop` / `main`), or displays an interactive worktree selector.
* **Remote branch auto-checkout:** Running `gar switch <branch>` for a branch that exists on the remote (`origin/<branch>`) automatically provisions a local tracking worktree (fetching from `origin` if not yet cached locally) without requiring `-c`.
* **Smart branch creation prompt:** If you enter a new branch name without `-c`, Arborist asks if you'd like to create it now instead of failing.

Provision and switch to an explicit brand-new feature branch:
```bash
gar switch -c new-feature
# Force isolated DB creation from backup without prompting:
gar switch -c -y new-feature
# Or force a live DB clone instead of importing the latest backup:
gar switch -c --clone new-feature
```
*Prompts with a 10-second timeout defaulting to **No** (`[y/N]`) before creating an isolated database (`db_new_feature`), or provisions immediately without prompting when `-y`/`--yes`, `--backup`, or `--clone` is passed. If skipped, you can run `gar db provision` (`gar dbp`) at any time.*


### Move/Rename Worktree (`gar move`, `gar mv`, `gar -m`)

Seamlessly rename a branch, move its directory, update Git metadata, and migrate its database in one step:
```bash
# When inside the worktree:
gar move new-branch-name
gar mv new-branch-name

# Or explicitly from anywhere in the hub:
gar move old-branch-name new-branch-name
gar -m old-branch-name new-branch-name
```
*Repairs Git worktree tracking, renames the Git branch (`git branch -m`), moves the folder, and migrates the database (`db_old` → `db_new`).*


### Remove a Worktree (`gar remove`)

Safely drop a worktree, remove its Git tracking branch, and clean up its database:
```bash
gar remove feature-branch

# Skip confirmation prompts and force drop isolated database
gar remove -f feature-branch
gar remove --force feature-branch
```
*Prompts to safely drop `db_feature-branch` if an isolated database exists (or bypasses prompt with `-f` / `--force`).*


### List Worktrees & Databases (`gar list`)

Inspect all active worktrees, branches, and isolated databases side-by-side in a unified table with status indicators:
```bash
gar list
```

```text
STATUS       BRANCH               WORKTREE                 DATABASE               DETAILS
------       ------               --------                 --------               -------
🟢 Active    feature-hero         ./feature-hero           db_feature_hero        Current directory
🟡 Protect   develop              ./develop                db                     Tracking branch
⚪ Valid     feature-nav          ./feature-nav            db_feature_nav         In sync
🔴 Orphaned  feature-footer       ./feature-footer         db_feature_footer      Remote PR merged ([gone])
🔴 Orphaned  bug-123              <none>                   db_bug_123             DB exists (no branch/worktree)
```

* **🟢 Active**: The worktree you are currently in.
* **🟡 Protect**: Protected baseline branches (`main`, `develop`, etc.).
* **⚪ Valid**: Local branch and worktree in sync with active remote upstream.
* **🔴 Orphaned**: Remote branch was deleted (e.g., merged PR) or database was left behind without a branch.


### Workspace Information (`gar info`)

Inspect the hosting engine, active branch, isolated database, and live site URL:
```bash
gar info
```

```text
Engine:         ddev
Current Branch: feature-hero
DB Name:        db_feature_hero
URL:            https://feature-hero.myproject.ddev.site
```


### Prune Orphaned Resources (`gar prune`)

Sweep and clean up stale worktrees, deleted branches, and orphaned databases in MariaDB/MySQL:
```bash
# Interactive cleanup (prompts before deleting)
gar prune

# Force cleanup without confirmation prompts
gar prune -f
gar prune --force

# Preview what would be removed without deleting anything
gar prune --dry-run
```

* **Dirty Worktree Protection:** If an orphaned worktree directory contains uncommitted changes, `gar prune` **will never delete it**. It safely skips dirty worktrees and alerts you in the terminal.
* **Active Worktree Protection:** If you are currently inside an orphaned worktree, it is skipped so your shell session is never disrupted.
* **Automatic Git Hooks Integration:** During `gar init`, Arborist automatically installs Git hooks (`post-merge` and `reference-transaction`) and configures `fetch.prune = true`. When you run `git pull`, remote branches merged into the baseline are pruned and clean orphaned resources are automatically swept in the background!


### Synchronize Hub Environment (`gar sync-ddev`)

When changes are merged into your baseline tracking branch that affect the environment configuration, synchronize the Hub's root configuration cleanly:
```bash
gar sync-ddev
```


### Database Management (`gar db`, `gar dbi`, `gar dbe`, `gar dbp`)

Arborist provides dedicated commands to manually import, export, and provision databases across worktrees:

```bash
# Provision current branch database (import backup or clone) AND run POST_PROVISION_CMD (updb, cim, cr, uli)
gar db provision
gar dbp

# Provision using live clone from default db instead of backup
gar dbp --clone

# Run only post-provision commands (updb, cim, cr, uli) without re-importing database
gar dbp --skip-db

# Provision a specific branch from anywhere in the Hub
gar dbp --target feature-branch

# Import the latest dump from DB_BACKUP_PATH into current branch (without running POST_PROVISION_CMD)
gar db import
gar dbi

# Import a specific dump file (paths are relative to current directory)
gar dbi --file custom_dump.sql.gz
gar dbi ../backups/staging.sql

# Import into a specific branch's database from anywhere
gar dbi --target feature-branch
gar dbi --target main

# Export current branch database (timestamped into DB_BACKUP_PATH)
gar db export
gar dbe

# Export with custom destination file
gar dbe --file ../backups/my_backup.sql.gz
```

#### Project Configuration (`.arborist`)
Project-specific settings reside in `.arborist` at the root of the Hub (`$HUB_DIR/.arborist`):
```bash
ENV_ENGINE=ddev
WEBROOT=docroot
FRAMEWORK=drupal
SPARSE_EXCLUDES="!/.ddev/ !/.lando.yml !/.lando/ !/docker-compose.yml"
DB_BACKUP_PATH="backups"
DB_PROVISION_STRATEGY="backup"   # Options: "backup" (default), "clone"
DEFAULT_BRANCH="develop"
PROTECTED_BRANCHES="develop,main,master"
PRUNE_TARGETS="both"   # Options: "both" (default), "db", "worktree"
POST_PROVISION_CMD="ddev drush updb -y && ddev drush cim -y && ddev drush cr && ddev drush uli"
```
* `DB_PROVISION_STRATEGY` controls how isolated databases are populated when switching to/creating new branches. Options:
  * `"backup"` (default): Automatically restores the newest database dump from `DB_BACKUP_PATH` (or fallback directories like `dumps`, `dump`, `db`). If no backup files exist, automatically falls back to cloning.
  * `"clone"`: Performs a live clone of the running default database (`db`). Can also be triggered on demand via `gar switch --clone <branch>`.
* If `DB_BACKUP_PATH` is a directory, `gar db import` and `gar switch` automatically select the most recent dump file (`.sql`, `.sql.gz`, etc.).
* Paths provided via `--file` are always evaluated relative to where you invoke the command.
* `PROTECTED_BRANCHES` protects baseline branches from being deleted by `gar prune`.
* `PRUNE_TARGETS` controls whether `gar prune` sweeps both worktrees and databases, or only one of them.
* `POST_PROVISION_CMD` specifies commands executed inside the worktree directory when a new branch is created or checked out from remote (e.g. `updb` → `cim` → `cr` → `uli`). If any command fails, remaining commands abort immediately so the developer can inspect and resolve the issue.


### Environment Variables (`.env`)

Arborist supports branch-isolated environment configurations per worktree (`<worktree>/.env` and `<worktree>/.env.local`):

* **Runtime Evaluation (No `ddev restart`):** Evaluated dynamically at request/execution time by PHP (`settings.workspace.php`) for both web requests (via Nginx/PHP-FPM) and CLI commands (`ddev drush`). Edits to `.env` take effect immediately without slow container restarts.
* **CLI Wrapper Auto-sourcing:** Arborist's custom DDEV wrappers (`ddev drush`, `ddev npm`) automatically `source` the active worktree's `.env` and `.env.local` into the subshell before execution.
* **Automated Seeding:** When switching to or creating a new branch (`gar switch -c`), Arborist automatically seeds `.env` from your baseline tracking branch (`develop` / `main`), or falls back to `.env.example`.
* **Git Cleanliness:** Both `.env` and `.env.local` are automatically registered in `.git/info/exclude`, ensuring worktrees stay untracked and clean.


## Development & Testing

Arborist includes an end-to-end (E2E) Bash test suite verifying bare clone initialization, sparse-checkouts, directory switching, moves, and database mock calls:
```bash
./tests/test-gar.sh
```


## Lineage

Arborist is the architectural successor to [`dbrancher`](https://github.com/crunchyweb/ddev-dbrancher-addon). 

While `dbrancher` introduced dynamic branch and database switching within a single-directory workflow, Arborist evolves that foundation into a fully integrated Hub-and-Spoke multi-worktree system. Decoupling the environment configuration into the Hub eliminates in-place re-indexing and enables truly concurrent branch development.


## License

This project is open-source software licensed under the [MIT License](LICENSE).


