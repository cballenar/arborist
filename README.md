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

Provision and switch to a brand-new feature branch:
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
```
*Prompts to safely drop `db_feature-branch` if an isolated database exists.*


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
Project-specific settings reside in `.arborist` at the root of the Hub (`$HUB_DIR/.arborist`). During `gar init`, you can configure the backup path:
```bash
ENV_ENGINE=ddev
WEBROOT=docroot
FRAMEWORK=drupal
SPARSE_EXCLUDES="!/.ddev/ !/.lando.yml !/.lando/ !/docker-compose.yml"
DB_BACKUP_PATH="backups"
```
* If `DB_BACKUP_PATH` is a directory, `gar db import` automatically selects the most recent dump file (`.sql`, `.sql.gz`, etc.).
* Paths provided via `--file` are always evaluated relative to where you invoke the command.


## Development & Testing

Arborist includes an end-to-end (E2E) Bash test suite verifying bare clone initialization, sparse-checkouts, directory switching, moves, and database mock calls:
```bash
./tests/test-gar.sh
```


## Lineage

Arborist is the architectural successor to [`dbrancher`](https://github.com/crunchyweb/ddev-dbrancher-addon). 

While `dbrancher` introduced dynamic branch and database switching within a single-directory workflow, Arborist evolves that foundation into a fully integrated Hub-and-Spoke multi-worktree system. Decoupling the environment configuration into the Hub eliminates in-place re-indexing and enables truly concurrent branch development.

