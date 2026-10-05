--!strict
-- Open, adopt, re-run setup, remove and prune. Removal refuses the main
-- worktree, locked worktrees, busy sessions and (unless forced) dirty
-- worktrees, and warns about unpushed commits before asking to confirm.

local util = require("../util")
local git = require("../git")
local config = require("../config")
local state = require("../state")
local setup = require("../setup")
local session = require("../session")
local app = require("../app")

local manage = {}

local PRE_REMOVE_MS = 120000

local function label_of(wt: git.Worktree): string
	if wt.branch then
		return wt.branch
	end
	return "(detached " .. string.sub(wt.head or "", 1, 7) .. ")"
end

local function branch_of(wt: git.Worktree): string
	return wt.branch or ("detached-" .. string.sub(wt.head or "head", 1, 7))
end

-- The tracked entry for `wt`, or a new one (not yet stored).
local function entry_for(repo: git.Repo, cfg: config.Config, wt: git.Worktree): state.Entry
	local existing = state.get(wt.path)
	if existing then
		return existing
	end
	local branch = branch_of(wt)
	return {
		path = wt.path,
		main = repo.main,
		repo = repo.name,
		branch = branch,
		session_name = util.render(cfg.session_name, { repo = repo.name, branch = branch, slug = util.slug(branch) }),
		repo_common_dir = repo.common_dir,
		created_at = os.time(),
		setup = "adopted",
	}
end

-- Tracks `wt` (if new) and shows its session, creating it when needed.
function manage.open_worktree(cx: WindowCx, repo: git.Repo, cfg: config.Config, shared: app.Shared, wt: git.Worktree)
	local entry = entry_for(repo, cfg, wt)
	if state.get(wt.path) == nil then
		state.put(entry)
		shared.reload()
	end
	local ok, why = session.start(cx, entry, { actions = cfg.post_open_actions })
	if not ok then
		cx:toast("error", "Couldn't open session " .. entry.session_name, tostring(why))
	end
end

-- "Open worktree…": every worktree of the focused repository.
function manage.open(cx: WindowCx, shared: app.Shared)
	app.with_repo(cx, function(cx2, repo, cfg)
		local items = {}
		local choices: { git.Worktree } = {}
		for _, wt in repo.worktrees do
			if not wt.bare and not wt.prunable then
				local tracked = state.get(wt.path)
				local bits = { app.tilde(wt.path) }
				if wt.main then
					table.insert(bits, "main")
				end
				if tracked then
					table.insert(bits, tracked.session_name)
				end
				if wt.locked then
					table.insert(bits, "locked")
				end
				table.insert(choices, wt)
				table.insert(items, {
					label = label_of(wt),
					detail = table.concat(bits, " · "),
					icon = if wt.path == repo.top then "check" else nil,
					choice = tostring(#choices),
				})
			end
		end
		app.pick(cx2, { title = "Open worktree", subtitle = repo.name, items = items }, function(cx3, choice)
			local wt = choices[tonumber(choice) or 0]
			if wt then
				manage.open_worktree(cx3, repo, cfg, shared, wt)
			end
		end)
	end)
end

-- "Bind this session to its worktree": tracks the focused pane's worktree
-- under the current session's name.
function manage.adopt(cx: WindowCx, shared: app.Shared)
	app.with_repo(cx, function(cx2, repo, cfg)
		local wt: git.Worktree? = nil
		for _, w in repo.worktrees do
			if w.path == repo.top then
				wt = w
			end
		end
		if wt == nil then
			cx2:toast("error", "Worktree not found", app.tilde(repo.top))
			return
		end
		local current = cx2.sessions:current()
		local entry = entry_for(repo, cfg, wt)
		local bound = table.clone(entry)
		bound.session_name = current.name
		bound.session_id = current.id
		-- One worktree per session: drop other worktrees bound to this session.
		for path, other in state.all() do
			if path ~= bound.path and other.session_name == current.name then
				state.drop(path)
			end
		end
		state.put(bound)
		shared.reload()
		cx2:toast("success", "Session " .. current.name .. " ↔ " .. bound.branch, app.tilde(bound.path))
	end)
end

-- "Re-run setup": post_create again, typed into the focused pane.
function manage.setup(cx: WindowCx, _shared: app.Shared)
	local cwd = app.focused_cwd(cx)
	local entry = state.find(cwd)
	if entry == nil then
		cx:toast("error", "Not a tracked worktree", "Run \"Bind this session to its worktree\" first")
		return
	end
	local ok, cfg = pcall(config.load, entry.main)
	if not ok then
		cx:toast("error", "Worktrees config is invalid", tostring(cfg))
		return
	end
	local wrote, script = pcall(setup.write, "post_create", cfg.phases.post_create, {
		path = entry.path,
		main = entry.main,
		branch = entry.branch,
		base = entry.base or "",
	})
	if not wrote then
		cx:toast("error", "Setup script not written", tostring(script))
		return
	end
	if script == nil then
		cx:toast("info", "Nothing to set up", "No phases.post_create steps in " .. cfg.source)
		return
	end
	local pane = cx.session:focused()
	local info = if pane then cx.session:pane(pane) else nil
	if pane == nil or info == nil or info.busy or (info.kind ~= nil and info.kind ~= "terminal") then
		cx:toast("error", "Focus an idle shell", "Setup is typed into the focused shell pane")
		return
	end
	cx:run(pane, "bash " .. util.shell_quote(script) .. "\r")
	state.patch(entry.path, { setup = "typed" })
end

-- Runs pre_remove steps non-interactively in the worktree; `cb(ok, err, cx)`.
local function pre_remove(cfg: config.Config, entry: state.Entry, cb: (boolean, string?, WindowCx?) -> ())
	local ok, script = pcall(setup.write, "pre_remove", cfg.phases.pre_remove, {
		path = entry.path,
		main = entry.main,
		branch = entry.branch,
		base = entry.base or "",
	})
	if not ok or script == nil then
		tern.timer(0, function(cx: WindowCx?)
			cb(script == nil, if ok then nil else tostring(script), cx)
		end)
		return
	end
	tern.process.run({ "bash", script :: string }, { cwd = entry.path, timeout_ms = PRE_REMOVE_MS }, function(r: ProcessResult, cx: WindowCx?)
		local tail = util.trim(string.sub(r.stdout .. r.stderr, -400))
		cb(r.status == 0, if r.timed_out then "pre_remove timed out" else tail, cx)
	end)
end

local function remove_now(cx: WindowCx, repo: git.Repo, cfg: config.Config, shared: app.Shared, wt: git.Worktree, force: boolean)
	local entry = entry_for(repo, cfg, wt)
	if session.busy(cx, entry) then
		cx:toast("error", "A command is running in " .. entry.session_name, "Stop it, then remove again")
		return
	end
	pre_remove(cfg, entry, function(ran, why, cx2)
		if cx2 == nil then
			return
		end
		if not ran and not force then
			cx2:toast("error", "pre_remove failed; nothing removed", why or "")
			return
		end
		local args = { "worktree", "remove" }
		if force then
			table.insert(args, "--force")
		end
		table.insert(args, wt.path)
		git.run(repo.main, args, function(ok, _out, err, cx3)
			if cx3 == nil then
				return
			end
			if not ok then
				cx3:toast("error", "git worktree remove refused", err)
				return
			end
			state.drop(wt.path)
			shared.reload()
			local closed = session.close(cx3, entry)
			cx3:toast(
				"success",
				"Removed worktree " .. label_of(wt),
				(if closed then "session closed · " else "") .. "branch " .. branch_of(wt) .. " kept"
			)
		end)
	end)
end

-- Checks `wt` and asks for confirmation, offering a forced remove when dirty.
local function confirm_remove(cx: WindowCx, repo: git.Repo, cfg: config.Config, shared: app.Shared, wt: git.Worktree)
	if wt.main or wt.path == repo.main then
		cx:toast("error", "Refusing to remove the main worktree", app.tilde(wt.path))
		return
	end
	if wt.locked then
		cx:toast("error", "Worktree is locked", (wt.lock_reason or "") .. " · git worktree unlock " .. app.tilde(wt.path))
		return
	end
	git.dirty(wt.path, function(dirty, derr, cx2)
		if cx2 == nil then
			return
		end
		if dirty == nil then
			cx2:toast("error", "Couldn't read worktree status", derr or "")
			return
		end
		git.unpushed(wt.path, function(unpushed, _uerr, cx3)
			if cx3 == nil then
				return
			end
			local entry = entry_for(repo, cfg, wt)
			local notes = {}
			if dirty > 0 then
				table.insert(notes, { text = string.format("%d uncommitted change(s) will be lost", dirty), tone = "error" })
			end
			if unpushed and unpushed > 0 then
				table.insert(notes, { text = string.format("%d commit(s) on %s aren't on any remote", unpushed, branch_of(wt)), tone = "warn" })
			elseif unpushed == nil then
				table.insert(notes, { text = "Couldn't check for unpushed commits", tone = "warn" })
			end
			if session.find(cx3, entry) then
				table.insert(notes, { text = "Closes session " .. entry.session_name })
			end
			if #cfg.phases.pre_remove > 0 then
				table.insert(notes, { text = string.format("Runs %d pre_remove step(s) first", #cfg.phases.pre_remove) })
			end
			table.insert(notes, { text = "The branch " .. branch_of(wt) .. " is kept" })
			local items = {}
			if dirty > 0 then
				table.insert(items, { label = string.format("Force remove (discard %d change(s))", dirty), tone = "error", choice = "force" })
			else
				table.insert(items, { label = "Remove worktree", tone = "warn", choice = "remove" })
			end
			table.insert(items, { label = "Cancel", choice = "cancel" })
			app.pick(cx3, {
				title = "Remove " .. label_of(wt) .. "?",
				subtitle = app.tilde(wt.path),
				notes = notes,
				items = items,
			}, function(cx4, choice)
				if choice == "remove" or choice == "force" then
					remove_now(cx4, repo, cfg, shared, wt, choice == "force")
				end
			end)
		end)
	end)
end

-- "Remove worktree…": linked worktrees of the focused repository.
function manage.remove(cx: WindowCx, shared: app.Shared)
	app.with_repo(cx, function(cx2, repo, cfg)
		local items = {}
		local choices: { git.Worktree } = {}
		for _, wt in repo.worktrees do
			if not wt.main and not wt.bare then
				table.insert(choices, wt)
				local bits = { app.tilde(wt.path) }
				if wt.locked then
					table.insert(bits, "locked")
				end
				if wt.prunable then
					table.insert(bits, "missing (use Prune)")
				end
				table.insert(items, { label = label_of(wt), detail = table.concat(bits, " · "), choice = tostring(#choices) })
			end
		end
		if #items == 0 then
			cx2:toast("info", "No linked worktrees", repo.name .. " has only its main worktree")
			return
		end
		app.pick(cx2, { title = "Remove worktree", subtitle = repo.name, items = items }, function(cx3, choice)
			local wt = choices[tonumber(choice) or 0]
			if wt then
				confirm_remove(cx3, repo, cfg, shared, wt)
			end
		end)
	end)
end

-- "Prune worktrees": drops tracked entries whose directory is gone and runs
-- `git worktree prune` in each repository still present.
function manage.prune(cx: WindowCx, shared: app.Shared)
	local dropped = 0
	local mains: { [string]: boolean } = {}
	for path, entry in state.all() do
		if not tern.fs.exists(path) then
			state.drop(path)
			dropped += 1
		end
		if entry.main and tern.fs.exists(entry.main) then
			mains[entry.main] = true
		end
	end
	shared.reload()
	for main in mains do
		git.run(main, { "worktree", "prune" }, function(ok, _out, err, cx2)
			if not ok and cx2 then
				cx2:toast("error", "git worktree prune failed", err)
			end
		end)
	end
	cx:toast("success", "Pruned worktrees", string.format("%d stale entr%s dropped", dropped, if dropped == 1 then "y" else "ies"))
end

return manage
