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
	bases: { string }, -- the ranked choices; bases[1] is the default
	refs: { string }, -- those plus every other ref, as suggestions
	ref_total: number?, -- how many the repository has, when `refs` is capped
	home: string?,
}

type State = {
	ctx: Ctx,
	branch: field.Field,
	-- The base is free text: the list below is navigation, not the answer, so
	-- a ref the suggestions left out is still reachable by typing it.
	base: field.Field,
	focus: string, -- "branch" or "base"
	problem: string?,
	submitted: boolean,
}

local BRANCH_ID = "main.branch"
local BASE_ID = "main.base"
-- Rendered rows; the list node scrolls within its own height.
local LIST_MAX = 60

local function decode_args(args: { string }): Ctx?
	local ok, ctx = pcall(tern.json.decode, args[1] or "")
	if not ok or type(ctx) ~= "table" or type(ctx.token) ~= "string" then
		return nil
	end
	if type(ctx.bases) ~= "table" or #ctx.bases == 0 then
		ctx.bases = { "HEAD" }
	end
	if type(ctx.refs) ~= "table" or #ctx.refs == 0 then
		ctx.refs = ctx.bases
	end
	return ctx
end

-- The refs the list shows, filtered by what the base field holds.
local function listed(state: State): { string }
	local text = util.trim(state.base.text)
	local lower = string.lower(text)
	-- An exact ref means "that one is chosen" (you arrowed to it or typed it
	-- out), so the whole list stays up with it highlighted. Anything else is
	-- a filter.
	local exact = false
	for _, ref in state.ctx.refs do
		if ref == text then
			exact = true
			break
		end
	end
	local out: { string } = {}
	for _, ref in state.ctx.refs do
		if text == "" or exact or string.find(string.lower(ref), lower, 1, true) then
			table.insert(out, ref)
			if #out >= LIST_MAX then
				break
			end
		end
	end
	return out
end

-- The base that will be used: what was typed, else the best candidate.
local function effective_base(state: State): string
	local text = util.trim(state.base.text)
	return if text ~= "" then text else (state.ctx.bases[1] or "HEAD")
end

-- The 1-based row the base field names, or 0.
local function selected(state: State, list: { string }): number
	local want = effective_base(state)
	for i, ref in list do
		if ref == want then
			return i
		end
	end
	return 0
end

-- Moves the highlight by `delta`, writing the ref into the base field so the
-- field always shows what will be used.
local function move(state: State, delta: number)
	local list = listed(state)
	if #list == 0 then
		return
	end
	local at = selected(state, list)
	local next_at = if at == 0
		then (if delta > 0 then 1 else #list)
		else (at - 1 + delta) % #list + 1
	state.base = field.new(list[next_at])
	state.problem = nil
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
	-- Blank means "pick an autoname"; the window chooses it.
	local problem = if branch == "" then nil else util.branch_problem(branch)
	if problem then
		state.problem = problem
		return
	end
	finish(state, cx, url.build("create", {
		token = state.ctx.token,
		branch = branch,
		-- A bare name is resolved against origin by the window.
		base = effective_base(state),
	}))
end

local function cancel(state: State, cx: BlockCx)
	if not state.submitted then
		finish(state, cx, url.build("cancel", { token = state.ctx.token }))
	end
end

local function input_id(state: State): string
	return if state.focus == "base" then BASE_ID else BRANCH_ID
end

local function focus_input(state: State, cx: BlockCx)
	local id = input_id(state)
	tern.timer(30, function()
		cx:frame({ { "focus", id } })
	end)
end

local function base_list(state: State, list: { string }): Node
	local at = selected(state, list)
	local items: { Item } = {}
	for i, ref in list do
		items[i] = {
			label = ref,
			icon = if i == at then "check" else nil,
			tone = if i == at then "accent" else nil,
		}
	end
	local node = ui.list(items)
	for i, child in node.c or {} do
		local p: { [string]: any } = child.p or {}
		p.key = "b" .. i
		p.actions = { click = "base=" .. i }
		child.p = p
	end
	node.p = node.p or {}
	local lp: { [string]: any } = node.p :: any
	lp.key = "bases"
	lp.selected = "main.bases.b" .. (if at > 0 then at else 1)
	lp.max = { lines = 8 }
	return node
end

local dialog: BlockDef<State> = {
	init = function(cx, args, saved)
		local ctx = decode_args(args)
		if ctx == nil then
			error("worktrees.new needs the window's launch argument; use \"New worktree session…\" from the palette", 0)
		end
		local kept = if type(saved) == "table" then saved else nil
		local state: State = {
			ctx = ctx :: Ctx,
			branch = field.new(if kept then kept.branch else nil),
			-- Empty, not prefilled with the default: a prefilled exact ref
			-- would have to be cleared before typing could filter anything.
			-- Blank means "the default", which the dock and preview name.
			base = field.new(if kept and type(kept.base) == "string" then kept.base else nil),
			focus = "branch",
			problem = nil,
			submitted = false,
		}
		focus_input(state, cx)
		return state
	end,

	title = function(state)
		return "New worktree · " .. state.ctx.repo
	end,

	view = function(state, _cx)
		local branch = full_branch(state)
		local base = effective_base(state)
		local preview: { Node } = {}
		if branch == "" then
			preview = { ui.text({ ui.span("Blank branch: Enter creates the next free autoname (a sea creature).", "muted") }) }
		elseif util.branch_problem(branch) == nil then
			preview = {
				ui.kv({
					{ { ui.span("branch", "muted") }, { ui.span(branch, "strong") } },
					{ { ui.span("base", "muted") }, { ui.span(base) } },
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
				placeholder = "branch name, or leave blank for an autoname (manatee, murex…)",
				prompt = {
					ui.span(
						if state.ctx.prefix ~= "" then state.ctx.prefix else "⎇ ",
						if state.focus == "branch" then "accent" else "muted"
					),
				},
			}),
		}
		if state.problem then
			table.insert(children, ui.text({ ui.span(state.problem :: string, "error") }))
		end
		for _, n in preview do
			table.insert(children, n)
		end
		local list = listed(state)
		table.insert(children, ui.rule(
			if state.focus == "base"
				then "Base — type to filter, ↑↓ to pick"
				else "Base (new branches start here) — Tab to change"
		))
		table.insert(children, ui.node("input", {
			key = "base",
			text = state.base.text,
			cursor = state.base.cursor,
			placeholder = state.ctx.bases[1] or "HEAD",
			prompt = { ui.span("⎇ ", if state.focus == "base" then "accent" else "muted") },
		}))
		if #list == 0 then
			table.insert(children, ui.text({
				ui.span("No ref matches. " .. base .. " is used as typed", "warn"),
				ui.span(" (a bare name resolves to origin/" .. base .. ").", "muted"),
			}))
		else
			table.insert(children, base_list(state, list))
			-- A big monorepo's refs don't all fit in the launch argument, so
			-- say what the list leaves out rather than look complete.
			local total = state.ctx.ref_total or 0
			if total > #state.ctx.refs then
				table.insert(children, ui.text({
					ui.span(
						string.format("Suggesting %d of %d refs — type any other in full.", #state.ctx.refs, total),
						"muted"
					),
				}))
			end
		end
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
					ui.text({ ui.span("Enter create · Tab field · ↑↓ base · Esc cancel", "muted") }),
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
		elseif name == "tab" then
			state.focus = if state.focus == "branch" then "base" else "branch"
			focus_input(state, cx)
		elseif name == "down" then
			move(state, 1)
		elseif name == "up" then
			move(state, -1)
		elseif field.key(if state.focus == "base" then state.base else state.branch, key) then
			state.problem = nil
		else
			return false
		end
		return true
	end,

	event = function(state, ev, cx)
		if ev.ev == "focus" then
			cx:frame({ { "focus", input_id(state) } })
		elseif ev.ev == "action" then
			if ev.act == "base" then
				local list = listed(state)
				local ref = list[tonumber(ev.value) or 0]
				if ref then
					state.base = field.new(ref)
					state.problem = nil
				end
				state.focus = "branch"
				focus_input(state, cx)
			elseif ev.act == "create" then
				submit(state, cx)
			elseif ev.act == "cancel" then
				cancel(state, cx)
			end
		end
	end,

	save = function(state)
		return { branch = state.branch.text, base = state.base.text }
	end,
}

return dialog
