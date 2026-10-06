--!strict
-- Tern sessions bound to worktrees: find one by name (ids don't survive a
-- daemon restart), create and show one, then type a setup script into its
-- first pane once the shell is ready, and run optional post-open actions.

local util = require("./util")
local state = require("./state")

local session = {}

-- How long to wait for a new session's shell before typing into it anyway.
local SETTLE_MS = 6000
local PROMPT_POLL_MS = 150
local PROMPT_TRIES = 20
local PANE_TRIES = 15

export type Opts = {
	script: string?, -- a setup script to `bash` in the first pane
	actions: { string }?, -- action ids to run once open (missing ones are skipped)
}

-- The session bound to `entry`: by remembered id when its name still
-- matches, else by exact name.
function session.find(cx: WindowCx, entry: state.Entry): ManagedSession?
	local ok, list = pcall(function()
		return cx.sessions:list()
	end)
	if not ok then
		return nil
	end
	for _, s in list do
		if entry.session_id and s.id == entry.session_id and s.name == entry.session_name then
			return s
		end
	end
	for _, s in list do
		if s.name == entry.session_name then
			return s
		end
	end
	return nil
end

-- The focused pane of session `id`'s first tab, once the window has it.
local function first_pane(cx: WindowCx, id: number): number?
	for _, info in cx.session:sessions() do
		if info.id == id and info.tabs[1] then
			local layout = cx.session:layout(info.tabs[1])
			if layout then
				return layout.focus
			end
		end
	end
	return nil
end

-- Runs action ids that exist; a plugin that isn't installed is skipped.
local function run_actions(cx: WindowCx, actions: { string }?)
	for _, id in actions or {} do
		local known = pcall(function()
			return cx.actions:describe(id)
		end)
		if known then
			local ok, err = pcall(function()
				cx:action(id)
			end)
			if not ok then
				tern.log.warn("post_open_action failed", id, err)
			end
		else
			tern.log.debug("post_open_action skipped (not installed)", id)
		end
	end
end

-- Types `bash <script>` into `pane` once its shell sits at a prompt (or
-- after the wait runs out: typed input waits in the pty either way).
local function type_script(pane: number, script: string, tries: number)
	tern.timer(PROMPT_POLL_MS, function(cx: WindowCx?)
		if cx == nil then
			return
		end
		local info = cx.session:pane(pane)
		if info == nil then
			return -- the pane closed
		end
		if info.at_prompt == false and not info.busy and tries < PROMPT_TRIES then
			type_script(pane, script, tries + 1)
			return
		end
		local ok, err = pcall(function()
			cx:run(pane, "bash " .. util.shell_quote(script) .. "\r")
		end)
		if not ok then
			cx:toast("error", "Couldn't start setup", tostring(err))
		end
	end)
end

local function after_open(id: number, opts: Opts, tries: number)
	tern.timer(200, function(cx: WindowCx?)
		if cx == nil then
			return
		end
		local pane = first_pane(cx, id)
		if pane == nil then
			if tries < PANE_TRIES then
				after_open(id, opts, tries + 1)
			elseif opts.script then
				cx:toast("error", "Setup not started", "The new session's pane didn't appear; run Re-run setup")
			end
			return
		end
		local script = opts.script
		if script then
			local ok = pcall(function()
				cx.session:settle(pane, SETTLE_MS):next(function(_text, _err, _cx)
					type_script(pane, script, 0)
				end)
			end)
			if not ok then
				type_script(pane, script, 0)
			end
		end
		run_actions(cx, opts.actions)
	end)
end

-- Shows the session bound to `entry`, creating it (first tab in the
-- worktree) when there is none. Returns false with a reason on failure.
function session.start(cx: WindowCx, entry: state.Entry, opts: Opts): (boolean, string?)
	local existing = session.find(cx, entry)
	if existing then
		local ok, err = pcall(function()
			cx.sessions:switch(existing.id)
		end)
		if not ok then
			return false, tostring(err)
		end
		if existing.id ~= entry.session_id then
			state.patch(entry.path, { session_id = existing.id })
		end
		if opts.script or opts.actions then
			after_open(existing.id, opts, 0)
		end
		return true
	end
	local ok, created = pcall(function()
		return cx.sessions:create({ name = entry.session_name, cwd = entry.path })
	end)
	if not ok or created == nil then
		return false, tostring(created)
	end
	state.patch(entry.path, { session_id = created.id })
	after_open(created.id, opts, 0)
	return true
end

-- Closes the session bound to `entry`, if any; returns whether one closed.
function session.close(cx: WindowCx, entry: state.Entry): boolean
	local s = session.find(cx, entry)
	if s == nil then
		return false
	end
	return (pcall(function()
		cx.sessions:close(s.id)
	end))
end

-- Whether a command is running in the session bound to `entry`. Only the
-- shown session's panes are visible to a window, so others report false.
function session.busy(cx: WindowCx, entry: state.Entry): boolean
	local s = session.find(cx, entry)
	if s == nil or not s.current then
		return false
	end
	for _, pane in cx.session:panes() do
		if pane.busy and (pane.kind == nil or pane.kind == "terminal" or pane.kind == "agent") then
			return true
		end
	end
	return false
end

return session
