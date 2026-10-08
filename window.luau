--!strict
-- worktrees, window half: palette commands, the `tern-worktrees://` link
-- route the dialog blocks answer through, and the status segment
-- (`⎇ branch ●n`) for panes inside a tracked worktree.
--
-- Load stays tiny (50 ms budget): only `state` is required here; command
-- logic (`lib/app`, git, config, setup) loads on first use.

local state = require("./lib/state")

local IOS = tern.runtime.os == "ios"
local DIRTY_EVERY_MS = 2000

-- Tracked worktrees, read from kv; the status formatter reads only this.
local index: { [string]: state.Entry } = {}
-- Uncommitted change counts by worktree path, filled asynchronously.
local dirty: { [string]: number } = {}
local dirty_at: { [string]: number } = {}

local function reload()
	index = state.all()
	tern.chrome.refresh()
end

local shared = { reload = reload }

-- Read once at load too: a plugin reload doesn't re-run `window_start`.
index = state.all()

local function app()
	return require("./lib/app")
end

local function available(_cx: WindowCx): boolean
	return not IOS
end

local COMMANDS = {
	{ id = "new", title = "New worktree session…", icon = "plus" },
	{ id = "quick", title = "Quick worktree…", icon = "sparkle" },
	{ id = "open", title = "Open worktree…", icon = "folder" },
	{ id = "adopt", title = "Bind this session to its worktree", icon = "link" },
	{ id = "setup", title = "Re-run setup", icon = "play" },
	{ id = "remove", title = "Remove worktree…", icon = "trash" },
	{ id = "prune", title = "Prune worktrees", icon = "broom" },
	{ id = "addrepo", title = "Add repo…", icon = "folder" },
	{ id = "rmrepo", title = "Remove repo…", icon = "trash" },
	{ id = "setbase", title = "Set default base…", icon = "branch" },
}

for _, c in COMMANDS do
	local id = c.id
	tern.command({
		id = id,
		title = c.title,
		icon = c.icon,
		available = available,
		run = function(cx: WindowCx)
			app().run(id, cx, shared)
		end,
	})
end

-- Carly exports `create`, `list`, `repos` and `add_repo` (desktop only:
-- `tern.carly` is absent elsewhere). Their logic loads on first call.
if tern.carly ~= nil and not IOS then
	require("./lib/carly").register(shared)
end

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, 17) ~= "tern-worktrees://" then
		return nil
	end
	return app().link(link, cx)
end)

-- Counts uncommitted changes for the worktree holding `pane`, at most every
-- DIRTY_EVERY_MS per worktree, then redraws the status line.
local function refresh_dirty(cx: WindowCx, pane: number?)
	if IOS or pane == nil then
		return
	end
	local info = cx.session:pane(pane)
	local entry = if info then state.find(info.cwd, index) else nil
	if entry == nil then
		return
	end
	local path = entry.path
	local now = tern.now()
	if dirty_at[path] and now - dirty_at[path] < DIRTY_EVERY_MS then
		return
	end
	dirty_at[path] = now
	require("./lib/git").dirty(path, function(count, _err, _cx)
		if count and count ~= dirty[path] then
			dirty[path] = count
			tern.chrome.refresh()
		end
	end)
end

tern.on("window_start", function(cx: WindowCx)
	reload()
	refresh_dirty(cx, cx.session:focused())
end)

tern.on("focus", function(ev: FocusEvent, cx: WindowCx)
	-- Another window or the host may have changed kv; reading it is a stat.
	local fresh = state.all()
	local changed = false
	for k in fresh do
		if index[k] == nil then
			changed = true
		end
	end
	for k in index do
		if fresh[k] == nil then
			changed = true
		end
	end
	if changed then
		index = fresh
		tern.chrome.refresh()
	end
	refresh_dirty(cx, ev.pane)
end)

tern.on("command_finished", function(ev: CommandFinishedEvent, cx: WindowCx)
	refresh_dirty(cx, ev.pane)
end)

-- Pure: reads only `index` and `dirty`. Every change to them calls
-- `tern.chrome.refresh()`.
tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	local entry = state.find(pane.cwd, index)
	if entry == nil then
		return nil
	end
	local n = dirty[entry.path]
	local text = "⎇ " .. entry.branch .. (if n and n > 0 then " ●" .. n else "")
	return { { text = text, tone = if n and n > 0 then "warn" else nil, command = "plugin.worktrees.open" } }
end)
