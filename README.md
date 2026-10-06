# tern-worktrees

One git branch, one worktree, one [Tern](https://stencil.so/tern) session.

Create, open, set up, and remove worktrees from Tern's command palette. Declarative `post_create` steps handle project setup (install, env copy, optional services), typed visibly into the new session's shell. Studio-friendly by default, generic enough for any repository.

## Status

MVP (0.1.0). Built against Tern's Luau plugin API as shipped in Tern 0.4.5 (`tern.d.luau` in this repo). Tern is in closed beta and its plugin API is unversioned. Local hosts only.

## Install

```bash
git clone https://github.com/maxtuzz/tern-worktrees ~/src/tern-worktrees
tern plugin link ~/src/tern-worktrees
tern plugin reload        # exits 1 and prints the error if a plugin failed
tern plugin list          # worktrees 0.1.0 Worktree Sessions — 2 blocks, 0 lenses, window  ready
```

`link` uses the folder where it is, so saving a file reloads the plugin. Window-half load errors don't show in `tern plugin list`; they appear as a toast ("Plugin Worktree Sessions failed to load"). To see the plugin's own log lines, start Tern with `STENCIL_LOG=warn,stencil=info,tern::plugin=debug`.

## Commands

Open the palette in a shell inside a git repository:

| Command | What it does |
| --- | --- |
| **New worktree session…** | Opens a dialog for the branch name and base. Leave the branch blank to get the next free autoname (see below). Runs `git worktree add` at `../{repo}.worktrees/{slug}`, opens a Tern session named `{repo}:{branch}` in it, and types the `post_create` setup into its first pane. If the branch already exists, the existing branch is checked out. If the branch already has a worktree, that worktree's session opens. |
| **Open worktree…** | Lists the repository's worktrees. Picking one switches to its session, or creates the session if there isn't one. |
| **Bind this session to its worktree** | Binds the current session to the focused pane's worktree. Use it for worktrees you made by hand. |
| **Re-run setup** | Types `post_create` into the focused shell again. |
| **Remove worktree…** | Picks a linked worktree, shows what removal will cost (uncommitted changes, unpushed commits, the session it closes), then runs `pre_remove`, `git worktree remove` and closes the session. The branch is kept. |
| **Prune worktrees** | Drops tracked entries whose folder is gone and runs `git worktree prune`. |

### Autonames

A worktree created without a branch name, from a blank dialog or from Carly, is named after a sea creature from a fixed pool of 40: `pearlfish`, `manatee`, `murex`, `halfbeak`, `narwhal`, and so on. The plain word is the branch, so the session is short (`studio:manatee`). `branch_prefix` still applies.

A name is skipped if it is already one of the following for this repository:
- a local branch;
- a worktree folder name;
- a Tern session name (in Tern or tracked by the plugin).

The rotation cursor is kept in `tern.kv` (`autoname_cursor`), so successive worktrees don't all start at the first animal. When every name is taken, numbered names follow (`pearlfish-2`, …).

### Carly

On desktop, the window half exports two functions to Carly. Carly can find them with `help("plugins.worktrees")`.

```lua
-- Next autoname, from the configured base (or HEAD), in the focused pane's repository:
await(plugins.worktrees.create())
-- Explicit branch and base, in another repository:
await(plugins.worktrees.create("feat/login", "origin/main", "~/src/studio"))
--> "Created worktree feat/login at /…/studio.worktrees/feat-login (base origin/main);
--    session studio:feat/login; post_create setup started in its first pane"

await(plugins.worktrees.list())  -- {{path, branch, main, locked, session}, …}
```

`create(branch?, base?, dir?)` follows the same path as the dialog:
- It runs `git worktree add` at the sibling path and opens the `{repo}:{branch}` session.
- It types `post_create` into that session's pane and runs `post_open_actions`.
- If the branch already has a worktree, that worktree is reused.

A missing `base` means the first configured `base` ref that exists, else `HEAD`. A missing `dir` means the focused pane's directory. The call answers within 120 s with one line naming the path, branch, session and whether setup started. Failures (an invalid branch, an existing path, a git error) fail the call with the reason.

The status line shows `⎇ branch` for panes inside a tracked worktree, followed by `●n` when there are uncommitted changes. Click it to open the worktree list. Shells started inside a tracked worktree get `TERN_WT_ROOT`, `TERN_WT_MAIN` and `TERN_WT_BRANCH`.

### Safety

- The main worktree is never removed.
- A dirty worktree is removed only through the explicit **Force remove** choice. Git refuses anything else.
- Unpushed commits are flagged before you confirm.
- Locked worktrees (`git worktree lock`) are refused.
- Removal is refused while a command runs in the worktree's (shown) session.
- Closing a Tern session alone never deletes a worktree.

## Configuration: `.tern/worktrees.json`

Put this file in the main worktree. Every key is optional:

```json
{
  "root": "../{repo}.worktrees/{slug}",
  "branch_prefix": "",
  "base": ["origin/main", "origin/master", "main", "master"],
  "fetch_before_create": false,
  "session_name": "{repo}:{branch}",
  "post_open_actions": [],
  "phases": { "post_create": [], "pre_remove": [], "services": [] }
}
```

- `root` is resolved against the main worktree and must contain `{slug}` or `{branch}`. `{slug}` is the branch name with `/` and other unsafe characters turned into `-`.
- `base` lists the bases the dialog offers. Refs that don't exist are hidden, and the current branch and `HEAD` are always offered.
- New branches are created with `--no-track`, so they never push to their base by accident.
- `post_open_actions` are action ids run once the session opens. Ids that no installed plugin provides are skipped, so `plugin.branch-changes.open` is safe to list without that plugin.

If the file is missing, the plugin imports `.cursor/worktrees.json` (`setup-worktree-unix` / `setup-worktree` commands → `post_create`). If that is missing too, it imports `.superset/config.json` (`setup` → `post_create`, `teardown` → `pre_remove`).

### Steps

Each step is an object with one kind key. `"optional": true` turns a failure into a warning.

| Step | Example | Does |
| --- | --- | --- |
| `run` | `{ "run": "pnpm install", "env": { "CI": "true" }, "cwd": "apps/web", "confirm": "Install?" }` | Runs a shell command in the worktree. |
| `copy` | `{ "copy": [".env", "apps/*/.env"], "from": "main", "if_missing": true }` | Copies files or folders from the main worktree (globs, no `**`). |
| `symlink` | `{ "symlink": "node_modules/.cache" }` | Links to the main worktree's copy instead. |
| `sync_dir` | `{ "sync_dir": ".hamster/", "optional": true }` | Mirrors a folder from main (`rsync -a`, else `cp -R`). |
| `wait_for` | `{ "wait_for": { "url": "http://127.0.0.1:54321/health", "timeout_s": 180 } }` | Polls a URL (or `"port"`) until it answers. |
| `require` | `{ "require": ["node>=24", "pnpm"] }` | Checks tools (and minimum versions) are on `PATH`. |
| `confirm` | `{ "confirm": "Continue with services?" }` | Asks y/N. "No" stops the script. |

Steps compile to one bash script in the plugin's data folder. It runs in the session's first pane as `bash <script>`, where you can watch it and stop it with Ctrl-C. It works with macOS's bash 3.2. These variables are exported: `$WT_PATH`, `$WT_MAIN`, `$WT_BRANCH`, `$WT_BASE` and `$ROOT_WORKTREE_PATH` (= `$WT_MAIN`, for Cursor/Superset scripts). `pre_remove` runs without a terminal before removal, with a 2-minute limit.

### Studio profile example

`.tern/worktrees.json` in the Studio monorepo:

```json
{
  "root": "../{repo}.worktrees/{slug}",
  "base": ["origin/dev", "origin/main"],
  "fetch_before_create": true,
  "session_name": "{repo}:{branch}",
  "post_open_actions": ["plugin.branch-changes.open"],
  "phases": {
    "post_create": [
      { "require": ["node>=24", "pnpm"] },
      { "copy": [".env", "apps/*/.env"], "from": "main", "if_missing": true },
      { "sync_dir": ".hamster/", "from": "main", "optional": true },
      { "run": "pnpm install --frozen-lockfile --prefer-offline", "env": { "CI": "true" } }
    ],
    "pre_remove": [],
    "services": [
      { "run": "pnpm dev:ensure-supabase", "confirm": "Rebind shared Supabase to this worktree?" },
      { "wait_for": { "url": "http://127.0.0.1:54321/auth/v1/health", "timeout_s": 180 } }
    ]
  }
}
```

## How it works

- **Window half** (`window.luau`): registers the palette commands, the Carly exports, the `tern-worktrees://` link route and the status segment. Its load requires only `lib/state`, and the rest loads on first use, which keeps it inside the 50 ms budget. All git runs through async `tern.process.run`.
- **Host half** (`host.luau`): provides the dialog blocks `worktrees.new` and `worktrees.pick`, and the `spawn` filter. The filter only reads an in-memory index refreshed from `tern.kv`, and never runs git.
- **Dialog → window**: a block answers with `cx:open("tern-worktrees://create?token=…")`, and the window's `tern.route.link` handles it. Each dialog carries a one-shot token issued by the window. A link without a live token does nothing, so a clicked link in terminal output can't create or remove anything.
- **State**: `tern.kv` key `worktrees` maps each worktree path to `{session_name, session_id, branch, main, …}`. Sessions are found again by name after a daemon restart.

## Development

```bash
./tests/run.sh   # Luau unit + load tests (plain `luau`), and the setup script run under /bin/bash
tern plugin types .   # regenerate tern.d.luau after upgrading Tern
```

## Known gaps (v2)

- The `services` phase is validated but not run yet. There is no "Start services" command.
- Remote Tern hosts, GitHub PR → worktree and a `tern-wt` CLI bridge are out of scope.
- The busy check before removal only sees panes of the session currently shown.
- Removal keeps the branch. Deleting it is not offered yet.

## Docs

- [DESIGN.md](./DESIGN.md): product and API design
- [docs/](./docs/): offline copy of the Tern plugin docs used while building
- [tern.d.luau](./tern.d.luau): API types (`tern plugin types .`)

## License

MIT
