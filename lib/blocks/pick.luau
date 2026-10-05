--!strict
-- Block `worktrees.pick`: a small list chooser (Open worktree…, Remove
-- worktree… and its confirmation). The window half passes one JSON argument:
--
--   { token, title, subtitle?, notes?: [{text, tone?}],
--     items: [{label, detail?, tone?, icon?, choice}] }
--
-- Choosing an item hands `tern-worktrees://pick?token=…&choice=…` back to
-- the window (`cx:open`); Escape sends `cancel`.

local url = require("../url")

local ui = tern.ui

type Choice = { label: string, detail: string?, tone: string?, icon: string?, choice: string }

type Spec = {
	token: string,
	title: string,
	subtitle: string?,
	notes: { { text: string, tone: string? } }?,
	items: { Choice },
}

type State = { spec: Spec, sel: number, submitted: boolean }

local function decode_args(args: { string }): Spec?
	local ok, spec = pcall(tern.json.decode, args[1] or "")
	if not ok or type(spec) ~= "table" or type(spec.token) ~= "string" or type(spec.items) ~= "table" then
		return nil
	end
	return spec
end

local function finish(state: State, cx: BlockCx, link: string)
	state.submitted = true
	cx:open(link)
	tern.timer(1500, function()
		for _, p in tern.pane.list() do
			if p.pane == cx.pane then
				cx:exit(0)
				return
			end
		end
	end)
end

local function choose(state: State, cx: BlockCx, i: number)
	local item = state.spec.items[i]
	if item == nil or state.submitted then
		return
	end
	finish(state, cx, url.build("pick", { token = state.spec.token, choice = item.choice }))
end

local function cancel(state: State, cx: BlockCx)
	if not state.submitted then
		finish(state, cx, url.build("cancel", { token = state.spec.token }))
	end
end

local picker: BlockDef<State> = {
	init = function(_cx, args, _saved)
		local spec = decode_args(args)
		if spec == nil then
			error("worktrees.pick needs the window's launch argument; use the Worktree Sessions palette commands", 0)
		end
		return { spec = spec :: Spec, sel = 1, submitted = false }
	end,

	title = function(state)
		return state.spec.title
	end,

	view = function(state, _cx)
		local spec = state.spec
		local children: { Node } = {
			ui.text({ ui.span(spec.title, "strong"), ui.span(if spec.subtitle then "  " .. spec.subtitle else "", "muted") }),
		}
		for _, note in spec.notes or {} do
			table.insert(children, ui.text({ ui.span(note.text, note.tone or "muted") }))
		end
		local items: { Item } = {}
		for i, c in spec.items do
			items[i] = { label = c.label, detail = c.detail, tone = c.tone, icon = c.icon }
		end
		local list = ui.list(items)
		for i, child in list.c or {} do
			local p: { [string]: any } = child.p or {}
			p.key = "i" .. i
			p.actions = { click = "pick=" .. i }
			child.p = p
		end
		local lp: { [string]: any } = (list.p or {}) :: any
		lp.key = "items"
		lp.selected = "main.items.i" .. state.sel
		lp.max = { lines = 16 }
		list.p = lp
		table.insert(children, list)
		return {
			main = ui.col(children),
			dock = ui.col({
				ui.text({ ui.span(if state.submitted then "Working…" else "Enter choose · ↑↓ move · Esc cancel", "muted") }),
			}),
		}
	end,

	key = function(state, key, cx)
		if state.submitted then
			return false
		end
		local n = #state.spec.items
		local name = key.name
		if name == "down" or name == "j" or (name == "tab" and not key.shift) then
			state.sel = math.min(state.sel + 1, math.max(n, 1))
		elseif name == "up" or name == "k" or (name == "tab" and key.shift) then
			state.sel = math.max(state.sel - 1, 1)
		elseif name == "enter" then
			choose(state, cx, state.sel)
		elseif name == "escape" or name == "q" then
			cancel(state, cx)
		else
			return false
		end
		return true
	end,

	event = function(state, ev, cx)
		if ev.ev == "action" and ev.act == "pick" then
			local i = tonumber(ev.value)
			if i then
				state.sel = i
				choose(state, cx, i)
			end
		end
	end,
}

return picker
