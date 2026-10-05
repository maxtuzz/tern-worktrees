--!strict
-- Block `worktrees.new`: the "New worktree session" dialog. The window half
-- opens it with one JSON argument describing the repository; the dialog
-- collects a branch name and a base, then hands them back as a
-- `tern-worktrees://create?…` link (`cx:open`), which the window's
-- `tern.route.link` handles. The link carries the window's one-shot token,
-- so only the dialog the window opened can trigger a create.

local util = require("../util")
local url = require("../url")
local field = require("../field")

local ui = tern.ui

type Ctx = {
	token: string,
	repo: string,
	main: string,
	root: string, -- path template, relative to main
	prefix: string,
	session_name: string, -- session name template
	bases: { string },
	home: string?,
}

type State = {
	ctx: Ctx,
	branch: field.Field,
	base: number,
	problem: string?,
	submitted: boolean,
}

local INPUT_ID = "main.branch"

local function decode_args(args: { string }): Ctx?
	local ok, ctx = pcall(tern.json.decode, args[1] or "")
	if not ok or type(ctx) ~= "table" or type(ctx.token) ~= "string" then
		return nil
	end
	if type(ctx.bases) ~= "table" or #ctx.bases == 0 then
		ctx.bases = { "HEAD" }
	end
	return ctx
end

local function full_branch(state: State): string
	local name = util.trim(state.branch.text)
	local prefix = state.ctx.prefix or ""
	if name ~= "" and prefix ~= "" and string.sub(name, 1, #prefix) ~= prefix then
		return prefix .. name
	end
	return name
end

local function target_path(state: State, branch: string): string
	local ctx = state.ctx
	local rel = util.render(ctx.root, { repo = ctx.repo, slug = util.slug(branch), branch = branch })
	return util.resolve(ctx.main, rel, ctx.home)
end

local function finish(state: State, cx: BlockCx, link: string)
	state.submitted = true
	cx:open(link)
	-- The window closes this pane when it handles the link; end anyway in
	-- case no window did (another window, or the window plugin failed).
	tern.timer(1500, function()
		for _, p in tern.pane.list() do
			if p.pane == cx.pane then
				cx:exit(0)
				return
			end
		end
	end)
end

local function submit(state: State, cx: BlockCx)
	if state.submitted then
		return
	end
	local branch = full_branch(state)
	local problem = util.branch_problem(branch)
	if problem then
		state.problem = problem
		return
	end
	finish(state, cx, url.build("create", {
		token = state.ctx.token,
		branch = branch,
		base = state.ctx.bases[state.base] or "HEAD",
	}))
end

local function cancel(state: State, cx: BlockCx)
	if not state.submitted then
		finish(state, cx, url.build("cancel", { token = state.ctx.token }))
	end
end

local function focus_input(cx: BlockCx)
	tern.timer(30, function()
		cx:frame({ { "focus", INPUT_ID } })
	end)
end

local function base_list(state: State): Node
	local items: { Item } = {}
	for i, b in state.ctx.bases do
		items[i] = {
			label = b,
			icon = if i == state.base then "check" else nil,
			tone = if i == state.base then "accent" else nil,
		}
	end
	local list = ui.list(items)
	for i, child in list.c or {} do
		local p: { [string]: any } = child.p or {}
		p.key = "b" .. i
		p.actions = { click = "base=" .. i }
		child.p = p
	end
	list.p = list.p or {}
	local lp: { [string]: any } = list.p :: any
	lp.key = "bases"
	lp.selected = "main.bases.b" .. state.base
	return list
end

local dialog: BlockDef<State> = {
	init = function(cx, args, saved)
		local ctx = decode_args(args)
		if ctx == nil then
			error("worktrees.new needs the window's launch argument; use \"New worktree session…\" from the palette", 0)
		end
		local state: State = {
			ctx = ctx :: Ctx,
			branch = field.new(if type(saved) == "table" then saved.branch else nil),
			base = if type(saved) == "table" and type(saved.base) == "number" then saved.base else 1,
			problem = nil,
			submitted = false,
		}
		focus_input(cx)
		return state
	end,

	title = function(state)
		return "New worktree · " .. state.ctx.repo
	end,

	view = function(state, _cx)
		local branch = full_branch(state)
		local preview: { Node } = {}
		if branch ~= "" and util.branch_problem(branch) == nil then
			preview = {
				ui.kv({
					{ { ui.span("branch", "muted") }, { ui.span(branch, "strong") } },
					{ { ui.span("path", "muted") }, { ui.span(util.tilde(target_path(state, branch), state.ctx.home)) } },
					{ { ui.span("session", "muted") }, {
						ui.span(util.render(state.ctx.session_name or "{repo}:{branch}", {
							repo = state.ctx.repo,
							branch = branch,
							slug = util.slug(branch),
						})),
					} },
				}),
			}
		end
		local children: { Node } = {
			ui.text({ ui.span("New worktree session", "strong"), ui.span("  " .. state.ctx.repo, "muted") }),
			ui.node("input", {
				key = "branch",
				text = state.branch.text,
				cursor = state.branch.cursor,
				placeholder = "branch name, e.g. feat/login",
				prompt = { ui.span(if state.ctx.prefix ~= "" then state.ctx.prefix else "⎇ ", "muted") },
			}),
		}
		if state.problem then
			table.insert(children, ui.text({ ui.span(state.problem :: string, "error") }))
		end
		for _, n in preview do
			table.insert(children, n)
		end
		table.insert(children, ui.rule("Base (new branches start here)"))
		table.insert(children, base_list(state))
		local create = ui.badge(if state.submitted then "Creating…" else "Create", "accent")
		create.p = create.p or {}
		local cp: { [string]: any } = create.p :: any
		cp.actions = { click = "create" }
		local close = ui.badge("Cancel", "muted")
		close.p = close.p or {}
		local xp: { [string]: any } = close.p :: any
		xp.actions = { click = "cancel" }
		return {
			main = ui.col(children),
			dock = ui.col({
				ui.row({
					create,
					close,
					ui.text({ ui.span("Enter create · Tab/↑↓ base · Esc cancel", "muted") }),
				}),
			}),
		}
	end,

	key = function(state, key, cx)
		if state.submitted then
			return false
		end
		local name = key.name
		if name == "enter" then
			submit(state, cx)
		elseif name == "escape" then
			cancel(state, cx)
		elseif name == "tab" or name == "down" then
			state.base = if key.shift and name == "tab"
				then (state.base - 2) % #state.ctx.bases + 1
				else state.base % #state.ctx.bases + 1
		elseif name == "up" then
			state.base = (state.base - 2) % #state.ctx.bases + 1
		elseif field.key(state.branch, key) then
			state.problem = nil
		else
			return false
		end
		return true
	end,

	event = function(state, ev, cx)
		if ev.ev == "focus" then
			cx:frame({ { "focus", INPUT_ID } })
		elseif ev.ev == "action" then
			if ev.act == "base" then
				local i = tonumber(ev.value)
				if i and state.ctx.bases[i] then
					state.base = i
				end
				focus_input(cx)
			elseif ev.act == "create" then
				submit(state, cx)
			elseif ev.act == "cancel" then
				cancel(state, cx)
			end
		end
	end,

	save = function(state)
		return { branch = state.branch.text, base = state.base }
	end,
}

return dialog
