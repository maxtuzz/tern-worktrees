# Design: tern-worktrees

## Pitch

One branch, one worktree, one Tern session: created, set up, and cleaned up from the palette.

## Decisions (locked for MVP)

- Repo: `maxtuzz/tern-worktrees` (public, MIT)
- Worktree path: sibling `../{repo}.worktrees/{slug}` (not in-repo `.worktrees/`)
- Config: JSON (`.tern/worktrees.json`); Tern plugins have `tern.json` only
- Session ↔ worktree: 1:1 primary mapping in `tern.kv` (Tern has no session metadata API)
- Session name: `{repo}:{branch}`
- On remove: remove worktree; leave the git branch unless user opts in later
- Remote hosts: local only for MVP
- Setup: declarative phases; Studio is a profile, not hard-coded
- Autonames: a branch left blank (dialog or Carly) becomes the next free sea-creature name (`pearlfish`, `manatee`, `murex`, …), rotating via a cursor in `tern.kv`
- Agents: Carly creates and lists worktrees through `tern.carly.export` (`create`, `list`)

## Manifest

```toml
schema = 1
id = "worktrees"
name = "Worktree Sessions"
version = "0.1.0"
description = "One git worktree ↔ one Tern session, with declarative setup"
host = "host.luau"
window = "window.luau"
```

## Commands (palette)

| Action | Label |
|---|---|
| `plugin.worktrees.new` | New worktree session… |
| `plugin.worktrees.open` | Open worktree… |
| `plugin.worktrees.adopt` | Bind this session to its worktree |
| `plugin.worktrees.setup` | Re-run setup |
| `plugin.worktrees.remove` | Remove worktree… |
| `plugin.worktrees.prune` | Prune worktrees |

## Architecture

### Window half (`window.luau`)

- Keep load tiny; lazy-require modules (50 ms budget)
- All git via async `tern.process.run` (never block UI thread)
- `cx.sessions:create({name, cwd})` / `:switch` / `:close` / `:list`
- After create: `cx.session:settle(pane)` then type setup script into the pane
- Status segment: `⎇ branch ●n`
- `available` false on iOS

### Carly exports (window half, desktop)

- `create(branch?, base?, dir?) -> string`: the dialog's create path without the dialog. A blank branch means an autoname, a blank base means the first existing configured base or `HEAD`, and a blank `dir` means the focused pane's directory. It answers through `call:wait` and `call:reply`/`call:fail` once git and the session are done (120 s cap). The reply is one line with the path, branch, session and whether setup started.
- `list(dir?) -> {{path, branch, main, locked, session}}`.
- Carly calls `await(plugins.worktrees.create())`. Arguments and results cross as JSON.

### Autonames

- A fixed pool of 40 short lowercase sea-creature words, each a valid branch and its own slug.
- A name is skipped if it is already a local branch, a worktree folder name, or a session name (Tern's list, plus the plugin's tracked sessions) for the repo.
- The cursor is persisted in `tern.kv` `autoname_cursor`. When the pool is exhausted, the names repeat with numbers (`pearlfish-2`, …).

### Host half (`host.luau`)

- Dialog block for new-worktree inputs (branch name + base picker)
- `spawn` filter: inject `TERN_WT_ROOT`, `TERN_WT_MAIN`, `TERN_WT_BRANCH` from in-memory map (no git in filter; 50 ms)

### Dialog → window

Preferred: block `cx:open("tern-worktrees://create?…")` + window `tern.route.link`.
Fallback: pass answer through block title (proven by tern-jj).

### State (`tern.kv`)

```json
{
  "worktrees": {
    "/abs/path": {
      "session_name": "studio:feat/foo",
      "session_id": "optional",
      "branch": "feat/foo",
      "repo_common_dir": "/abs/main/.git",
      "created_at": 0,
      "setup": "ok"
    }
  }
}
```

Re-find sessions by name after daemon restart.

## Config schema (`.tern/worktrees.json`)

```json
{
  "root": "../{repo}.worktrees/{slug}",
  "branch_prefix": "",
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

Importers when missing: `.cursor/worktrees.json`, then `.superset/config.json`.

## Setup engine

Compile steps to a bash script in plugin data dir; type into session pane (visible, Ctrl-C-able, no plugin budget).

Step types: `run`, `copy`, `symlink`, `sync_dir`, `wait_for`, `require`, `confirm`.

Vars: `$WT_PATH`, `$WT_MAIN`, `$WT_BRANCH`, `$WT_BASE`, `$ROOT_WORKTREE_PATH`.

## Safety

- Refuse remove if dirty unless force
- Warn on unpushed commits
- Never remove main worktree
- Respect `git worktree lock`
- Close session only after confirm; check panes not busy
- Closing Tern session alone does not delete worktree

## MVP done-when

1. `plugin.toml` + host/window halves load (`tern plugin link` + `reload` clean)
2. New worktree from palette → sibling path → session named `{repo}:{branch}` opens in that cwd
3. `post_create` runs `pnpm install`-style command visibly in the pane
4. Open lists worktrees and switches/creates sessions
5. Remove closes session + `git worktree remove` with dirty/main guards
6. Prune drops dead kv entries
7. Status segment shows current branch when inside a tracked worktree
8. README documents install/link and Studio profile example

## Out of scope (v2)

- Remote Tern hosts
- Automatic Supabase ownership tracking
- `tern-wt` CLI bridge
- GitHub PR → worktree
