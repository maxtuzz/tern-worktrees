--!strict
-- Block `worktrees.line`: one text input, used by "Quick worktree…", "Add
-- repo…" and "Set default base…". The window half opens it with one JSON
-- argument and gets the line back as
-- `tern-worktrees://<action>?token=…&line=…` (`cx:open`), which the window's
-- `tern.route.link` handles.
--
--   { token, action, title, subtitle?, value?, placeholder?, submit?,
--     hints?: [{text, tone?}], grammar?: "quick" | "repo",
--     aliases?: [string], home? }
--
-- With a `grammar` the dialog previews what the line resolves to while you
-- type. The window parses the line again against the live registry, so the
-- preview is a hint, never the decision.

local util = require("../util")
local url = require("../url")
local field = require("../field")
local quick = require("../quick")

local ui = tern.ui

type Hint = { text: string, tone: string? }

type Ctx = {
	token: string,
	action: string,
	title: string,
	subtitle: string?,
	value: string?,
	placeholder: string?,
	submit: string?,
	hints: { Hint }?,
	grammar: string?,
	aliases: { string }?,
	home: string?,
}

type State = {
	ctx: Ctx,
	line: field.Field,
	submitted: boolean,
}

local INPUT_ID = "main.line"

local function decode_args(args: { string }): Ctx?
	local ok, ctx = pcall(tern.json.decode, args[1] or "")
	if not ok or type(ctx) ~= "table" or type(ctx.token) ~= "string" or type(ctx.action) ~= "string" then
		return nil
	end
	return ctx
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
	finish(state, cx, url.build(state.ctx.action, {
		token = state.ctx.token,
		line = util.trim(state.line.text),
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

local function row(label: string, value: string, tone: string?): { { any } }
	return { { ui.span(label, "muted") }, { ui.span(value, tone or "strong") } }
end

-- What the typed line resolves to, as `kv` rows, or an error line.
local function preview(state: State): { Node }
	local grammar = state.ctx.grammar
	if grammar ~= "quick" and grammar ~= "repo" then
		return {}
	end
	local text = util.trim(state.line.text)
	if grammar == "repo" then
		local parsed = quick.parse_repo(text)
		if parsed.problem then
			return { ui.text({ ui.span(parsed.problem :: string, "error") }) }
		end
		if parsed.path == nil then
			return { ui.text({ ui.span("Type a path to a git repository.", "muted") }) }
		end
		local rows = { row("path", util.resolve("/", parsed.path :: string, state.ctx.home)) }
		table.insert(rows, row("alias", parsed.alias or "(the folder name)", if parsed.alias then "strong" else "muted"))
		table.insert(rows, row("base", parsed.base or "(none)", if parsed.base then "strong" else "muted"))
		return { ui.kv(rows) }
	end
	local aliases: { [string]: boolean } = {}
	for _, alias in state.ctx.aliases or {} do
		aliases[string.lower(alias)] = true
	end
	local parsed = quick.parse(text, function(token: string): boolean
		return aliases[string.lower(token)] == true
	end)
	if parsed.problem then
		return { ui.text({ ui.span(parsed.problem :: string, "error") }) }
	end
	local problem = if parsed.branch then util.branch_problem(parsed.branch :: string) else nil
	local rows = {
		row("repo", parsed.repo or "(here, or pick one)", if parsed.repo then "strong" else "muted"),
		row("branch", parsed.branch or "(next autoname)", if parsed.branch then "strong" else "muted"),
		row("base", parsed.base or "(the repo's default)", if parsed.base then "strong" else "muted"),
	}
	local out: { Node } = { ui.kv(rows) }
	if problem then
		table.insert(out, ui.text({ ui.span(problem :: string, "error") }))
	end
	return out
end

local dialog: BlockDef<State> = {
	init = function(cx, args, saved)
		local ctx = decode_args(args)
		if ctx == nil then
			error("worktrees.line needs the window's launch argument; use the Worktree Sessions palette commands", 0)
		end
		local start = if type(saved) == "table" and type(saved.line) == "string" then saved.line else (ctx :: Ctx).value
		focus_input(cx)
		return {
			ctx = ctx :: Ctx,
			line = field.new(start),
			submitted = false,
		}
	end,

	title = function(state)
		return state.ctx.title
	end,

	view = function(state, _cx)
		local children: { Node } = {
			ui.text({
				ui.span(state.ctx.title, "strong"),
				ui.span(if state.ctx.subtitle then "  " .. (state.ctx.subtitle :: string) else "", "muted"),
			}),
			ui.node("input", {
				key = "line",
				text = state.line.text,
				cursor = state.line.cursor,
				placeholder = state.ctx.placeholder or "",
				prompt = { ui.span("› ", "muted") },
			}),
		}
		for _, hint in state.ctx.hints or {} do
			table.insert(children, ui.text({ ui.span(hint.text, hint.tone or "muted") }))
		end
		for _, node in preview(state) do
			table.insert(children, node)
		end
		local go = ui.badge(if state.submitted then "Working…" else (state.ctx.submit or "Go"), "accent")
		go.p = go.p or {}
		local gp: { [string]: any } = go.p :: any
		gp.actions = { click = "submit" }
		local close = ui.badge("Cancel", "muted")
		close.p = close.p or {}
		local cp: { [string]: any } = close.p :: any
		cp.actions = { click = "cancel" }
		return {
			main = ui.col(children),
			dock = ui.col({
				ui.row({ go, close, ui.text({ ui.span("Enter go · Esc cancel", "muted") }) }),
			}),
		}
	end,

	key = function(state, key, cx)
		if state.submitted then
			return false
		end
		if key.name == "enter" then
			submit(state, cx)
		elseif key.name == "escape" then
			cancel(state, cx)
		elseif not field.key(state.line, key) then
			return false
		end
		return true
	end,

	event = function(state, ev, cx)
		if ev.ev == "focus" then
			cx:frame({ { "focus", INPUT_ID } })
		elseif ev.ev == "action" then
			if ev.act == "submit" then
				submit(state, cx)
			elseif ev.act == "cancel" then
				cancel(state, cx)
			end
		end
	end,

	save = function(state)
		return { line = state.line.text }
	end,
}

return dialog
