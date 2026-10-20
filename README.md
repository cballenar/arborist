# 🌳 Git Arborist (`gar`)

**Arborist** is a high-performance workspace manager for local web development (DDEV, Lando, Docker). 

By leveraging native **Git Worktrees** and **Sparse-Checkouts**, Arborist replaces disruptive in-place branch checking out and re-indexing with a persistent **Hub-and-Spoke** architecture where multiple feature branches run concurrently under a single shared environment.


## Who Is This For?

* Developers switching between branches and PR reviews tied to a database.
* Projects with relational databases (Drupal, WordPress, Laravel, Craft CMS) where schema and data changes conflict across branches.
* Workflows pairing with AI coding agents running concurrent tasks.


## Why Arborist?

Traditional single-directory branch hopping churns caches, invalidates build assets, and risks database collisions. Arborist replaces this with a persistent hub-and-spoke model:

* **Dedicated worktrees:** Each branch lives in its own directory side-by-side.
* **Instant switching:** Zero sync latency, volume re-scans, or cache churn.
* **Isolated environments:** Independent working directories, dependencies, and isolated databases.
* **Concurrent workflows:** Run, test, and review multiple branches simultaneously.
* **Shell integration:** Automatic directory navigation and built-in tab autocompletion (Bash & Zsh).


## Installation

```bash
./install.sh
source ~/.zshrc   # or ~/.bashrc
```

* Update/reinstall: `./install.sh -f`
* Uninstall: `./install.sh --uninstall`

### Manual Installation

Add the shell integration to your `~/.zshrc` or `~/.bashrc`:
```bash
eval "$(/path/to/arborist/bin/arborist hook)"
```


## Usage

The primary command is `gar` (`arborist` is also available). Run `gar -h` to see the help output.

```bash
gar -h
```

### Initialize Hub (`gar init`)

Initialize a new Hub bare repository and provision the baseline worktree.

```bash
gar init <git_repo_url> [hub_dir]
```

### Workspace Info (`gar info`)

Show hosting engine, active branch, isolated database, and site URL.

```bash
gar info
```

### List Worktrees & Databases (`gar list`)

List all active worktrees, branches, and database statuses.

```bash
gar list
gar list -a   # include Git branches without worktrees
```

### Switch or Create Worktree (`gar switch`)

Switch to an existing worktree, checkout a remote branch, or provision a new one.

```bash
gar switch feature-branch
gar switch -c new-feature           # create new branch & worktree
gar switch -c -y new-feature        # create without database prompt
gar switch -c --clone new-feature   # clone default DB instead of importing backup
```

### Move/Rename Worktree (`gar move`, `gar mv`)

Rename a worktree, its Git branch, and isolated database.

```bash
gar move new-branch-name
gar move old-branch-name new-branch-name
```

### Remove Worktree (`gar remove`)

Remove a worktree, delete its Git branch, and drop its isolated database.

```bash
gar remove feature-branch
gar remove -f feature-branch        # skip prompt and force drop database
```

### Database Management (`gar db`, `gar dbi`, `gar dbe`, `gar dbp`)

Import, export, or provision branch databases.

```bash
gar db provision                    # provision DB and run post-provision commands (gar dbp)
gar dbp --clone                     # provision by cloning default database
gar db import                       # import latest backup dump (gar dbi)
gar dbi --file dump.sql.gz          # import specific dump
gar db export                       # export database to backup dump (gar dbe)
```

### Synchronize Hub (`gar sync`)

Re-apply Arborist templates, Git hooks, and command wrappers to the Hub (e.g. after pulling updates).

```bash
gar sync
```

### Prune Orphaned Resources (`gar prune`)

Sweep and clean up stale worktrees, deleted branches, and orphaned databases.

```bash
gar prune
gar prune -f                        # force cleanup without prompt
gar prune --dry-run                 # preview without deleting
```

### Project Configuration (`.arborist`)

Project-specific settings reside in `.arborist` at the root of the Hub:

```bash
ENV_ENGINE=ddev
WEBROOT=docroot
FRAMEWORK=drupal
SPARSE_EXCLUDES="!/.ddev/ !/.lando.yml !/.lando/ !/docker-compose.yml"
DB_BACKUP_PATH="backups"
DB_PROVISION_STRATEGY="backup"   # Options: "backup", "clone"
DEFAULT_BRANCH="develop"
PROTECTED_BRANCHES="develop,main,master"
PRUNE_TARGETS="both"             # Options: "both", "db", "worktree"
POST_PROVISION_CMD="ddev drush updb -y && ddev drush cim -y && ddev drush cr && ddev drush uli"
```


## Development & Testing

Arborist includes an end-to-end (E2E) Bash test suite:

```bash
./tests/test-gar.sh
```


## Lineage

Arborist is the architectural successor to [`dbrancher`](https://github.com/cballenar/ddev-dbrancher-addon). 

While `dbrancher` introduced dynamic branch and database switching within a single-directory workflow, Arborist evolves that foundation into a fully integrated Hub-and-Spoke multi-worktree system. Decoupling the environment configuration into the Hub eliminates in-place re-indexing and enables truly concurrent branch development.


## License

This project is open-source software licensed under the [MIT License](LICENSE).
