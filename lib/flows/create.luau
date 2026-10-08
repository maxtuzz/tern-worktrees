--!strict
-- "New worktree session…" and Carly's `create`: (autoname) → git worktree
-- add (sibling path) → tracked in kv → session `{repo}:{branch}` in the
-- worktree → post_create typed into its first pane. Every git call is async;
-- each step continues in the callback's fresh `cx`, and `done` reports the
-- outcome (Carly's reply; the palette only toasts).

local util = require("../util")
local git = require("../git")
local config = require("../config")
local state = require("../state")
local setup = require("../setup")
local session = require("../session")
local app = require("../app")
local autoname = require("../autoname")
local quick = require("../quick")

local create = {}

local FETCH_MS = 60000
-- Freshening one base before branching is best-effort: short, and never fatal.
local BASE_FETCH_MS = 8000
local ADD_MS = 300000
local CURSOR_KEY = "autoname_cursor"

-- `done(ok, message, cx)`: the outcome in one readable line.
export type Done = (boolean, string, WindowCx?) -> ()

local function noop(_ok: boolean, _message: string, _cx: WindowCx?) end

-- Base choices: the repository's default base, then configured refs that
-- exist, then the current branch, then HEAD.
function create.bases(cfg: config.Config, refs: { [string]: boolean }, current: string?, prefer: string?): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(ref: string?)
		if ref and ref ~= "" and not seen[ref] then
			seen[ref] = true
			table.insert(out, ref)
		end
	end
	if prefer and prefer ~= "" then
		local resolved = create.resolve_base(prefer, refs)
		-- A registered default that no longer exists isn't offered.
		if refs[resolved] then
			add(resolved)
		end
	end
	for _, ref in cfg.base do
		if refs[ref] then
			add(ref)
		end
	end
	add(current)
	add("HEAD")
	return out
end

-- The ref a typed base means: itself when it exists, else `origin/<base>`
-- when that does (so `off dev` works in a repo that only tracks the remote),
-- else itself again and git says why.
function create.resolve_base(base: string, refs: { [string]: boolean }): string
	if base == "" or refs[base] then
		return base
	end
	local remote = "origin/" .. base
	if refs[remote] then
		return remote
	end
	return base
end

-- The base to branch from: the typed one, else the repository's default,
-- else the first configured base that exists, else HEAD.
function create.pick_base(from: string, refs: { [string]: boolean }, cfg: config.Config, prefer: string?): string
	if from ~= "" then
		return create.resolve_base(from, refs)
	end
	local bases = create.bases(cfg, refs, nil, prefer)
	return bases[1] or "HEAD"
end

-- The origin branch worth fetching before branching from `base`, or nil.
-- Only `origin/<branch>` qualifies: one remote, one ref, no guessing.
function create.fetch_spec(base: string): string?
	local branch = string.match(base, "^origin/(.+)$")
	if branch == nil or branch == "HEAD" then
		return nil
	end
	return branch
end

-- The repository's default base from the known-repos registry, or nil.
local function default_base(main: string): string?
	local ok, entry = pcall(function()
		return require("../known").by_path(main)
	end)
	return if ok and entry then entry.base else nil
end

function create.path_for(repo: git.Repo, cfg: config.Config, branch: string): string
	local rel = util.render(cfg.root, { repo = repo.name, slug = util.slug(branch), branch = branch })
	return util.resolve(repo.main, rel, tern.getenv("HOME"))
end

function create.session_name(repo: git.Repo, cfg: config.Config, branch: string): string
	return util.render(cfg.session_name, { repo = repo.name, branch = branch, slug = util.slug(branch) })
end

-- Tracks the new worktree, opens its session and starts post_create. `note`
-- is appended to the reported line (a base that couldn't be freshened).
local function finish(cx: WindowCx, repo: git.Repo, cfg: config.Config, shared: app.Shared, branch: string, base: string, path: string, note: string?, done: Done)
	local entry: state.Entry = {
		path = path,
		main = repo.main,
		repo = repo.name,
		branch = branch,
		base = base,
		session_name = create.session_name(repo, cfg, branch),
		repo_common_dir = repo.common_dir,
		created_at = os.time(),
		setup = if #cfg.phases.post_create > 0 then "typed" else "none",
	}
	state.put(entry)
	-- A worktree made here means this repository is worth offering from
	-- anywhere next time.
	pcall(function()
		require("../known").register(repo.main)
	end)
	shared.reload()
	local ok, script = pcall(setup.write, "post_create", cfg.phases.post_create, {
		path = path,
		main = repo.main,
		branch = branch,
		base = base,
	})
	if not ok then
		cx:toast("error", "Setup script not written", tostring(script))
		script = nil
	end
	local started, why = session.start(cx, entry, { script = script, actions = cfg.post_open_actions })
	if not started then
		cx:toast("error", "Worktree created, session not opened", tostring(why))
		done(false, string.format("Created worktree %s at %s, but session %s didn't open: %s", branch, path, entry.session_name, tostring(why)), cx)
		return
	end
	cx:toast("success", "Worktree " .. branch, app.tilde(path) .. (if script then " · setup running" else ""))
	done(true, string.format(
		"Created worktree %s at %s (base %s); session %s; %s%s",
		branch,
		path,
		base,
		entry.session_name,
		if script then "post_create setup started in its first pane" else "no post_create setup steps",
		if note then " · " .. (note :: string) else ""
	), cx)
end

-- `git worktree add`, once the branch and base are settled.
local function add_now(cx: WindowCx, repo: git.Repo, cfg: config.Config, shared: app.Shared, branch: string, base: string, path: string, exists: boolean, note: string?, done: Done)
	pcall(tern.fs.mkdir, util.dirname(path))
	local args = if exists
		then { "worktree", "add", path, branch }
		else { "worktree", "add", "--no-track", "-b", branch, path, base }
	cx:toast("info", "Creating worktree " .. branch, if exists then "existing branch" else "from " .. base)
	git.run(repo.main, args, function(ok, _out, err, cx2)
		if cx2 == nil then
			return
		end
		if not ok then
			cx2:toast("error", "git worktree add failed", err)
			done(false, "git worktree add failed: " .. err, cx2)
			return
		end
		finish(cx2, repo, cfg, shared, branch, if exists then branch else base, path, note, done)
	end, ADD_MS)
end

local function add_worktree(cx: WindowCx, repo: git.Repo, cfg: config.Config, shared: app.Shared, branch: string, base: string, fetched: boolean, done: Done)
	local path = create.path_for(repo, cfg, branch)
	if tern.fs.exists(path) then
		cx:toast("error", "Path already exists", app.tilde(path))
		done(false, "Path already exists: " .. path, cx)
		return
	end
	git.run(repo.main, { "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch }, function(exists, _out, _err, cx2)
		if cx2 == nil then
			return
		end
		-- A new branch starts at `base`, so freshen that one remote branch
		-- first. Offline is fine: the local ref still works, and the line we
		-- report says the base may be behind.
		local spec = if exists or fetched then nil else create.fetch_spec(base)
		if spec == nil then
			add_now(cx2, repo, cfg, shared, branch, base, path, exists, nil, done)
			return
		end
		cx2:toast("info", "Fetching " .. base, repo.name)
		git.run(repo.main, { "fetch", "--quiet", "origin", spec }, function(ok, _out2, err, cx3)
			if cx3 == nil then
				return
			end
			local note: string? = nil
			if not ok then
				note = "couldn't fetch " .. base .. ", used the local ref"
				cx3:toast("info", "Couldn't fetch " .. base, util.trim(err) .. " · using the local ref")
			end
			add_now(cx3, repo, cfg, shared, branch, base, path, exists, note, done)
		end, BASE_FETCH_MS)
	end)
end

-- Validates `branch`, reuses an existing worktree of it, fetches when
-- configured, then adds the worktree.
local function run_named(cx: WindowCx, repo: git.Repo, cfg: config.Config, shared: app.Shared, branch: string, base: string, done: Done)
	for _, wt in repo.worktrees do
		if wt.branch == branch then
			cx:toast("info", branch .. " already has a worktree", app.tilde(wt.path))
			require("./manage").open_worktree(cx, repo, cfg, shared, wt)
			done(true, string.format("Branch %s already has a worktree at %s; switched to session %s", branch, wt.path,
				(state.get(wt.path) or { session_name = create.session_name(repo, cfg, branch) }).session_name), cx)
			return
		end
	end
	git.run(repo.main, { "check-ref-format", "--branch", branch }, function(valid, _out, _err, cx2)
		if cx2 == nil then
			return
		end
		if not valid then
			cx2:toast("error", "Not a valid branch name", branch)
			done(false, "Not a valid branch name: " .. branch, cx2)
			return
		end
		if not cfg.fetch_before_create then
			add_worktree(cx2, repo, cfg, shared, branch, base, false, done)
			return
		end
		cx2:toast("info", "Fetching before create…", repo.name)
		git.run(repo.main, { "fetch", "--quiet", "--prune" }, function(fetched, _o, err, cx3)
			if cx3 == nil then
				return
			end
			if not fetched then
				cx3:toast("error", "git fetch failed; creating from local refs", err)
			end
			add_worktree(cx3, repo, cfg, shared, branch, base, fetched, done)
		end, FETCH_MS)
	end)
end

-- Branches, worktree folder names and session names an autoname must avoid.
local function taken_names(cx: WindowCx, repo: git.Repo, refs: { [string]: boolean }): { [string]: boolean }
	local taken: { [string]: boolean } = {}
	for ref in refs do
		taken[ref] = true
	end
	for _, wt in repo.worktrees do
		taken[util.basename(wt.path)] = true
		if wt.branch then
			taken[wt.branch] = true
		end
	end
	local ok, sessions = pcall(function()
		return cx.sessions:list()
	end)
	if ok then
		for _, s in sessions do
			taken[s.name] = true
		end
	end
	for _, entry in state.all() do
		taken[entry.session_name] = true
	end
	return taken
end

-- The next free autoname for `repo`, advancing the rotation in kv.
function create.autoname(cx: WindowCx, repo: git.Repo, cfg: config.Config, refs: { [string]: boolean }): string
	local taken = taken_names(cx, repo, refs)
	local read, stored = pcall(tern.kv.get, CURSOR_KEY)
	local cursor = if read then tonumber(stored) else nil
	local branch, next_cursor = autoname.pick(taken, cursor, cfg.branch_prefix, function(b: string): string
		return create.session_name(repo, cfg, b)
	end)
	pcall(tern.kv.set, CURSOR_KEY, next_cursor)
	return branch
end

-- Creates a worktree for `branch` from `base`. A missing or blank branch
-- becomes the next autoname; a missing base becomes the repository's default
-- base, else the first configured base that exists, else HEAD. A base that
-- only exists on origin (`dev` where there is just `origin/dev`) resolves to
-- the remote ref. `done` (optional) gets the outcome.
function create.run(cx: WindowCx, repo: git.Repo, cfg: config.Config, shared: app.Shared, branch: string?, base: string?, done: Done?)
	local report = done or noop
	local name = util.trim(branch or "")
	local from = util.trim(base or "")
	local prefer = default_base(repo.main)
	git.run(repo.main, { "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes" }, function(ok, out, err, cx2)
		if cx2 == nil then
			return
		end
		if not ok then
			report(false, "git for-each-ref failed: " .. err, cx2)
			return
		end
		local refs: { [string]: boolean } = {}
		for _, ref in util.lines(out) do
			refs[ref] = true
		end
		if name == "" then
			local picked, why = pcall(create.autoname, cx2, repo, cfg, refs)
			if not picked then
				report(false, "No autoname available: " .. tostring(why), cx2)
				return
			end
			name = why
		end
		run_named(cx2, repo, cfg, shared, name, create.pick_base(from, refs, cfg, prefer), report)
	end)
end

-- "New worktree session…": works from any session. The focused pane's
-- repository when it is in one, else a pick from the known repos; then the
-- branch-and-base dialog.
function create.new(cx: WindowCx, shared: app.Shared)
	app.target(cx, nil, function(cx2, repo, cfg)
		local prefer = default_base(repo.main)
		git.run(repo.main, { "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes" }, function(ok, out, _err, cx3)
			if cx3 == nil then
				return
			end
			local refs: { [string]: boolean } = {}
			if ok then
				for _, ref in util.lines(out) do
					refs[ref] = true
				end
			end
			app.dialog(cx3, {
				repo = repo.name,
				main = repo.main,
				root = cfg.root,
				prefix = cfg.branch_prefix,
				session_name = cfg.session_name,
				bases = create.bases(cfg, refs, repo.branch, prefer),
			}, function(cx4, branch, base)
				create.run(cx4, repo, cfg, shared, branch, base)
			end)
		end)
	end)
end

-- "Quick worktree…": one line, `[repo] [branch] [off <base>]`.
function create.quick(cx: WindowCx, shared: app.Shared)
	local list = require("../known").mru()
	local aliases: { string } = {}
	for _, entry in list do
		table.insert(aliases, entry.alias)
	end
	local hints = { { text = "[repo] [branch] [off <base>] — blank branch picks an autoname" } }
	if #aliases > 0 then
		table.insert(hints, { text = "known repos: " .. table.concat(aliases, ", ") })
	else
		table.insert(hints, { text = "No repos registered yet; run \"Add repo…\" to name one." })
	end
	app.line(cx, {
		action = "quick",
		title = "Quick worktree",
		subtitle = "off dev · studio feat/foo off dev",
		placeholder = "off dev",
		submit = "Create",
		grammar = "quick",
		aliases = aliases,
		hints = hints,
	}, function(cx2, line)
		create.from_line(cx2, shared, line)
	end)
end

-- Runs one quick-entry `line`. Parsed against the live registry, so the
-- block's preview never decides anything.
function create.from_line(cx: WindowCx, shared: app.Shared, line: string)
	local repos = require("../repos")
	local reg = require("../known").all()
	local parsed = quick.parse(line, function(token: string): boolean
		return repos.get(reg, token) ~= nil
	end)
	if parsed.problem then
		cx:toast("error", "Quick worktree", parsed.problem :: string)
		return
	end
	app.target(cx, parsed.repo, function(cx2, repo, cfg)
		create.run(cx2, repo, cfg, shared, parsed.branch, parsed.base)
	end)
end

return create
