--!strict
-- "New worktree session…": dialog → git worktree add (sibling path) →
-- tracked in kv → session `{repo}:{branch}` in the worktree → post_create
-- typed into its first pane. Every git call is async; each step continues in
-- the callback's fresh `cx`.

local util = require("../util")
local git = require("../git")
local config = require("../config")
local state = require("../state")
local setup = require("../setup")
local session = require("../session")
local app = require("../app")

local create = {}

local FETCH_MS = 60000
local ADD_MS = 300000

-- Base choices: configured refs that exist, then the current branch, then HEAD.
local function bases(cfg: config.Config, refs: { [string]: boolean }, current: string?): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(ref: string?)
		if ref and ref ~= "" and not seen[ref] then
			seen[ref] = true
			table.insert(out, ref)
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

function create.path_for(repo: git.Repo, cfg: config.Config, branch: string): string
	local rel = util.render(cfg.root, { repo = repo.name, slug = util.slug(branch), branch = branch })
	return util.resolve(repo.main, rel, tern.getenv("HOME"))
end

function create.session_name(repo: git.Repo, cfg: config.Config, branch: string): string
	return util.render(cfg.session_name, { repo = repo.name, branch = branch, slug = util.slug(branch) })
end

-- Tracks the new worktree, opens its session and starts post_create.
local function finish(cx: WindowCx, repo: git.Repo, cfg: config.Config, shared: app.Shared, branch: string, base: string, path: string)
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
		return
	end
	cx:toast("success", "Worktree " .. branch, app.tilde(path) .. (if script then " · setup running" else ""))
end

local function add_worktree(cx: WindowCx, repo: git.Repo, cfg: config.Config, shared: app.Shared, branch: string, base: string)
	local path = create.path_for(repo, cfg, branch)
	if tern.fs.exists(path) then
		cx:toast("error", "Path already exists", app.tilde(path))
		return
	end
	git.run(repo.main, { "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch }, function(exists, _out, _err, cx2)
		if cx2 == nil then
			return
		end
		pcall(tern.fs.mkdir, util.dirname(path))
		local args = if exists
			then { "worktree", "add", path, branch }
			else { "worktree", "add", "--no-track", "-b", branch, path, base }
		cx2:toast("info", "Creating worktree " .. branch, if exists then "existing branch" else "from " .. base)
		git.run(repo.main, args, function(ok, _out2, err, cx3)
			if cx3 == nil then
				return
			end
			if not ok then
				cx3:toast("error", "git worktree add failed", err)
				return
			end
			finish(cx3, repo, cfg, shared, branch, if exists then branch else base, path)
		end, ADD_MS)
	end)
end

-- Validates `branch`, reuses an existing worktree of it, fetches when
-- configured, then adds the worktree.
function create.run(cx: WindowCx, repo: git.Repo, cfg: config.Config, shared: app.Shared, branch: string, base: string)
	for _, wt in repo.worktrees do
		if wt.branch == branch then
			cx:toast("info", branch .. " already has a worktree", app.tilde(wt.path))
			require("./manage").open_worktree(cx, repo, cfg, shared, wt)
			return
		end
	end
	git.run(repo.main, { "check-ref-format", "--branch", branch }, function(valid, _out, _err, cx2)
		if cx2 == nil then
			return
		end
		if not valid then
			cx2:toast("error", "Not a valid branch name", branch)
			return
		end
		if not cfg.fetch_before_create then
			add_worktree(cx2, repo, cfg, shared, branch, base)
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
			add_worktree(cx3, repo, cfg, shared, branch, base)
		end, FETCH_MS)
	end)
end

-- The palette command: reads the repo and its refs, then opens the dialog.
function create.new(cx: WindowCx, shared: app.Shared)
	app.with_repo(cx, function(cx2, repo, cfg)
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
				bases = bases(cfg, refs, repo.branch),
			}, function(cx4, branch, base)
				create.run(cx4, repo, cfg, shared, branch, base)
			end)
		end)
	end)
end

return create
