--!strict
-- New tabs and splits inside a worktree session.
--
-- `cx.sessions:create({name, cwd})` sets only "its first tab directory"
-- (Tern's words), and new tabs otherwise follow Tern's new-tab Home
-- preference, so a second terminal in a worktree session lands in `~`
-- instead of the worktree. `cx.layout:new_tab`/`:split` do take a `cwd`, so
-- the window half overrides the three built-ins that open a shell and
-- anchors them to the worktree.
--
-- Outside a tracked worktree session every override returns nil and Tern's
-- own behavior runs untouched.

local state = require("./state")

local anchor = {}

-- The worktree this window is "in": the one bound to the current session
-- (the 1:1 binding we keep), else the one holding the focused pane. The
-- session comes first because the focused pane may already be the stray
-- home-directory tab we are trying to avoid making more of.
function anchor.cwd(cx: WindowCx, index: { [string]: state.Entry }): string?
	local ok, current = pcall(function()
		return cx.sessions:current()
	end)
	if ok and current ~= nil then
		for _, entry in index do
			if entry.session_name == current.name then
				return entry.path
			end
		end
	end
	local pane = cx.session:focused()
	local info = if pane then cx.session:pane(pane) else nil
	local entry = if info then state.find(info.cwd, index) else nil
	return if entry then entry.path else nil
end

-- Registers the overrides. `index` is read on every press, so it is passed
-- as a getter rather than copied.
function anchor.register(get_index: () -> { [string]: state.Entry })
	tern.override("new_tab", function(cx: WindowCx): boolean?
		local cwd = anchor.cwd(cx, get_index())
		if cwd == nil then
			return nil
		end
		-- A failed launch returns nil: fall through to the built-in rather
		-- than swallow the keypress.
		return cx.layout:new_tab({ cwd = cwd }) ~= nil
	end)

	for id, dir: Dir in { split_right = "right" :: Dir, split_down = "down" :: Dir } do
		tern.override(id, function(cx: WindowCx): boolean?
			local target = cx.session:focused()
			if target == nil then
				return nil
			end
			local cwd = anchor.cwd(cx, get_index())
			if cwd == nil then
				return nil
			end
			return cx.layout:split(target, dir, { cwd = cwd }) ~= nil
		end)
	end
end

return anchor
