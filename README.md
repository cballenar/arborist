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

Because operating systems prevent child CLI processes from changing the working directory of the parent terminal, Arborist requires a lightweight shell hook to natively `cd` you into newly provisioned or moved worktrees.

```bash
./install.sh
source ~/.zshrc   # or ~/.bashrc
```

* To re-install or update without confirmation prompt: `./install.sh -f`
* To remove the shell integration: `./install.sh --uninstall`

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
* Subcommands (`switch`, `list`, `prune`, `remove`, `db`, `dbi`, `dbe`, `-m`, etc.)
* Active worktrees and Git branches for `switch`, `remove`, and `-m`
* Database subcommands (`import`, `export`, `info`) and `--target` branch completion
* Flags for commands such as `prune` (`-f`, `--force`, `--dry-run`) and `remove` (`-f`, `--force`)


## Usage

The primary command is `gar`, with `arborist` available as the full command. Run `gar -h` to see the help output.
```bash
gar -h
```


### Initialize a Workspace Hub (`gar init`)

Run the interactive wizard on any remote repository:
```bash
gar init <git_repo_url> <hub_directory_name>
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
* **Remote branch auto-checkout:** Running `gar switch <branch>` for a branch that exists on the remote (`origin/<branch>`) automatically provisions a local tracking worktree without requiring `-c`.
* **Smart branch creation prompt:** If you enter a new branch name without `-c`, Arborist asks if you'd like to create it now instead of failing.

Provision and switch to an explicit brand-new feature branch:
```bash
gar switch -c new-feature
```
*Prompts if you would like an isolated database (`db_new-feature`) cloned from the baseline, or if you prefer falling back to the shared default DB.*


### Move/Rename Worktree (`gar -m`)

Seamlessly rename a branch, move its directory, update Git metadata, and migrate its database in one step:
```bash
# When inside the worktree:
gar -m new-branch-name

# Or explicitly from anywhere in the hub:
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


### Database Management (`gar db`, `gar dbi`, `gar dbe`)

Arborist provides dedicated commands to manually import, export, and inspect databases across worktrees:

```bash
# Import the latest dump from DB_BACKUP_PATH into current branch (or default db)
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
DEFAULT_BRANCH="develop"
PROTECTED_BRANCHES="develop,main,master"
PRUNE_TARGETS="both"   # Options: "both" (default), "db", "worktree"
POST_PROVISION_CMD="ddev drush updb -y && ddev drush cim -y && ddev drush cr && ddev drush uli"
```
* If `DB_BACKUP_PATH` is a directory, `gar db import` automatically selects the most recent dump file (`.sql`, `.sql.gz`, etc.).
* Paths provided via `--file` are always evaluated relative to where you invoke the command.
* `PROTECTED_BRANCHES` protects baseline branches from being deleted by `gar prune`.
* `PRUNE_TARGETS` controls whether `gar prune` sweeps both worktrees and databases, or only one of them.
* `POST_PROVISION_CMD` specifies commands executed inside the worktree directory when a new branch is created or checked out from remote (e.g. `updb` → `cim` → `cr` → `uli`). If any command fails, remaining commands abort immediately so the developer can inspect and resolve the issue.


## Development & Testing

Arborist includes an end-to-end (E2E) Bash test suite verifying bare clone initialization, sparse-checkouts, directory switching, moves, and database mock calls:
```bash
./tests/test-gar.sh
```


## Lineage

Arborist is the architectural successor to [`dbrancher`](https://github.com/crunchyweb/ddev-dbrancher-addon). 

While `dbrancher` introduced dynamic branch and database switching within a single-directory workflow, Arborist evolves that foundation into a fully integrated Hub-and-Spoke multi-worktree system. Decoupling the environment configuration into the Hub eliminates in-place re-indexing and enables truly concurrent branch development.

