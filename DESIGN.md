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
- Agents: Carly creates and lists worktrees through `tern.carly.export` (`create`, `list`, `repos`, `add_repo`)
- Start from anywhere: a user-level known-repos registry in `tern.kv` (`repos`), auto-registered on first use, overlaid with an optional hand-edited `repos.json`
- Quick entry: one line, `[repo] [branch] [off <base>]`, parsed by a pure module

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

| Action | Label | Needs a repo under the cursor? |
|---|---|---|
| `plugin.worktrees.new` | New worktree session… | no (picks from the registry) |
| `plugin.worktrees.quick` | Quick worktree… | no |
| `plugin.worktrees.open` | Open worktree… | yes |
| `plugin.worktrees.adopt` | Bind this session to its worktree | yes |
| `plugin.worktrees.setup` | Re-run setup | yes |
| `plugin.worktrees.remove` | Remove worktree… | yes |
| `plugin.worktrees.prune` | Prune worktrees | no |
| `plugin.worktrees.addrepo` | Add repo… | no |
| `plugin.worktrees.rmrepo` | Remove repo… | no |
| `plugin.worktrees.setbase` | Set default base… | no |

## Starting from anywhere

The MVP only worked when the focused pane sat inside a git repository. `app.target(cx, alias, fn)` is the generalization every "from anywhere" command goes through:

1. An alias typed on the quick line, or passed as Carly's `repo`, resolves through the registry.
2. Otherwise the focused pane's repository, if it is in one — and that registers it.
3. Otherwise a pick from the known repos, most recently used first (skipped when there is exactly one).
4. Otherwise one toast saying to run **Add repo…**.

### Known-repos registry

| Field | Meaning |
|---|---|
| `alias` | Typed in quick entry and passed as Carly's `repo`; unique, case-insensitive, not `off`/`from`/`as` |
| `path` | The repository's main worktree root |
| `base` | Default base ref for new worktrees here |
| `used_at` | Unix seconds; orders the picker and the hint line |

`lib/repos.luau` holds the rules and calls no `tern` API: every function takes a registry and returns a new one, so it is unit-tested under plain `luau`. `lib/known.luau` is the thin `tern.kv` layer over it.

Why `tern.kv` and not a JSON file of our own: kv *is* one JSON file in the plugin's data directory, shared by both halves and every window, re-read only when its mtime or length changed, and already the home of the tracked worktrees. A second hand-rolled file would repeat that machinery.

Why `repos.json` exists anyway: Tern has no plugin-settings API. `cx.settings` (`get`/`set`/`set_many`/`list`/`describe`) reads and writes Tern's own `settings.json` keys and rejects unknown ones, so a plugin cannot define settings a user edits there. `repos.json` in the plugin data directory is the declarative stand-in; it is authoritative for the paths it names (and for a base when it names one), while kv keeps every entry's `used_at`.

### Quick entry

`[repo] [branch] [off <base>]`, parsed by pure `lib/quick.luau` so the block (live preview) and the window (the decision) agree. `tern.command` has no argument or inline-entry field, so this is a one-line dialog block (`worktrees.line`), not something typed into the palette row.

- The first bare word is the repository only when a known alias matches it, case-insensitively; everything else bare is the branch.
- `off` introduces the base, with `from`, `@base`, `--base base` and `--base=base` as sugar.
- Nothing fits → one message naming the token, never a guess.

The same block, with grammar `repo`, collects **Add repo…**'s `<path> [as <alias>] [off <base>]`.

### Bases

Order: the typed base, the repository's registered default, the first existing configured `base`, the current branch, `HEAD`. A bare name resolves to `origin/<name>` when only the remote ref exists, so `off dev` works in a repo that never checked `dev` out.

When the chosen base is `origin/<branch>` and the branch is new, `git fetch --quiet origin <branch>` runs first with an 8 s limit. Failure is never fatal: creation continues from the local ref and the reported line says so. Only `origin`, and never `origin/HEAD`.

## Architecture

### Window half (`window.luau`)

- Keep load tiny; lazy-require modules (50 ms budget)
- All git via async `tern.process.run` (never block UI thread)
- `cx.sessions:create({name, cwd})` / `:switch` / `:close` / `:list`
- After create: `cx.session:settle(pane)` then type setup script into the pane
- Status segment: `⎇ branch ●n`
- `available` false on iOS

### Carly exports (window half, desktop)

Four of the 16 allowed names; both `sig` and `doc` stay under 1024 bytes (asserted in the tests).

- `create` — the dialog's create path without the dialog. Takes one options table (`repo`, `branch`, `base`, `dir`) or, for back-compat, positional `(branch?, base?, dir?)`; mixing them raises, and an unknown key is named back. `repo` is a registry alias, which is what makes it work from any session. A blank branch means an autoname; a blank base follows the base order; a blank `dir` means the focused pane's directory. It answers through `call:wait` and `call:reply`/`call:fail` once git and the session are done (120 s cap). The reply is one line with the path, branch, session, whether setup started and any fetch note.
- `list(dir?, repo?) -> {{path, branch, main, locked, session}}`.
- `repos() -> {{alias, path, base, used_at, declared}}`, most recently used first.
- `add_repo(path, alias?, base?) -> {alias, path, base}`: `path` is any path inside the repository and is stored as its main worktree root.
- Carly calls `await(plugins.worktrees.create{repo = "studio", base = "dev"})`. Arguments and results cross as JSON.

### Autonames

- A fixed pool of 40 short lowercase sea-creature words, each a valid branch and its own slug.
- A name is skipped if it is already a local branch, a worktree folder name, or a session name (Tern's list, plus the plugin's tracked sessions) for the repo.
- The cursor is persisted in `tern.kv` `autoname_cursor`. When the pool is exhausted, the names repeat with numbers (`pearlfish-2`, …).

### Host half (`host.luau`)

- `worktrees.new`: branch name + base picker
- `worktrees.pick`: list chooser (open, remove, confirm, which repository)
- `worktrees.line`: one text input with an optional live grammar preview (quick entry, add repo, set default base)
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
  },
  "repos": {
    "studio": { "alias": "studio", "path": "/Users/me/dev/studio-gsm", "base": "dev", "used_at": 0 }
  },
  "autoname_cursor": 7
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
9. New worktree session… and Quick worktree… work from a session that isn't in a repository
10. Add repo… / Remove repo… / Set default base… manage the registry, and creating a worktree auto-registers its repository

## Out of scope (v2)

- Remote Tern hosts
- Automatic Supabase ownership tracking
- `tern-wt` CLI bridge
- GitHub PR → worktree
