--!strict
-- The window half's command logic, loaded on first use so `window.luau`
-- stays tiny. Owns the one-shot tokens that let the host half's dialog
-- blocks answer through `tern-worktrees://…` links.

local util = require("./util")
local url = require("./url")
local git = require("./git")
local config = require("./config")

local app = {}

local HOME = tern.getenv("HOME")
local TOKEN_TTL_MS = 30 * 60 * 1000

export type Shared = {
	-- Re-reads tracked worktrees into the window's index and redraws chrome.
	reload: () -> (),
}

type Handler = (cx: WindowCx, action: string, params: { [string]: string }) -> ()
local pending: { [string]: { at: number, on: Handler } } = {}
local seq = 0
math.randomseed(math.floor((os.time() * 1000 + tern.now() * 1000) % 2147483647))

-- A one-shot token whose link runs `on`.
function app.token(on: Handler): string
	seq += 1
	local now = tern.now()
	for t, p in pending do
		if now - p.at > TOKEN_TTL_MS then
			pending[t] = nil
		end
	end
	local t = string.format("%x%x%x", seq, math.random(0, 0x7fffffff), math.floor(now))
	pending[t] = { at = now, on = on }
	return t
end

function app.tilde(path: string): string
	return util.tilde(path, HOME)
end

-- The focused pane's directory, or nil.
function app.focused_cwd(cx: WindowCx): string?
	local id = cx.session:focused()
	local info = if id then cx.session:pane(id) else nil
	if info and info.cwd and info.cwd ~= "" then
		return info.cwd
	end
	return nil
end

-- Calls `fn(cx, repo, cfg)` for the repository of the focused pane, toasting
-- why when there is none or its config is malformed.
function app.with_repo(cx: WindowCx, fn: (WindowCx, git.Repo, config.Config) -> ())
	local cwd = app.focused_cwd(cx)
	if cwd == nil then
		cx:toast("error", "No directory here", "Focus a shell inside a git repository")
		return
	end
	git.repo(cwd, function(repo, err, cx2)
		if cx2 == nil then
			return
		end
		if repo == nil then
			cx2:toast("error", "Worktrees: no repository", (err or "") .. " · " .. app.tilde(cwd))
			return
		end
		local ok, cfg = pcall(config.load, repo.main)
		if not ok then
			cx2:toast("error", "Worktrees config is invalid", tostring(cfg))
			return
		end
		fn(cx2, repo, cfg)
	end)
end

-- Opens the `pick` block listing `items`; `on_choice(cx, choice)` runs for
-- the chosen item.
function app.pick(
	cx: WindowCx,
	spec: { title: string, subtitle: string?, notes: { any }?, items: { any } },
	on_choice: (WindowCx, string) -> ()
)
	local token = app.token(function(cx2, action, params)
		if action == "pick" and params.choice then
			on_choice(cx2, params.choice)
		end
	end)
	local arg = tern.json.encode({
		token = token,
		title = spec.title,
		subtitle = spec.subtitle,
		notes = tern.json.array(spec.notes or {}),
		items = tern.json.array(spec.items),
	})
	if cx:new_block("worktrees.pick", { arg }, "below") == nil then
		pending[token] = nil
		cx:toast("error", "Worktrees host half isn't ready", "Run tern plugin list to see why")
	end
end

-- Opens the `new` dialog; `on_create(cx, branch, base)` runs on submit.
function app.dialog(cx: WindowCx, ctx: { [string]: any }, on_create: (WindowCx, string, string) -> ())
	local token = app.token(function(cx2, action, params)
		if action == "create" and params.branch then
			on_create(cx2, params.branch, params.base or "HEAD")
		end
	end)
	local arg = table.clone(ctx)
	arg.token = token
	arg.home = HOME
	arg.bases = tern.json.array(ctx.bases)
	if cx:new_block("worktrees.new", { tern.json.encode(arg) }, "below") == nil then
		pending[token] = nil
		cx:toast("error", "Worktrees host half isn't ready", "Run tern plugin list to see why")
	end
end

-- Closes the dialog block a link came from (only our own blocks).
local function close_block(cx: WindowCx, pane: number?)
	if pane == nil then
		return
	end
	local info = cx.session:pane(pane)
	if info and info.kind == "plugin" and type(info.block) == "string" and string.find(info.block, "worktrees.", 1, true) then
		pcall(function()
			cx.layout:close(pane)
		end)
	end
end

-- `tern.route.link` for `tern-worktrees://…`: runs the token's handler.
function app.link(link: LinkRequest, cx: WindowCx): RouteDecision?
	local action, params = url.parse(link.url)
	if action == nil then
		return nil
	end
	close_block(cx, link.pane)
	local token = params.token
	local p = if token then pending[token] else nil
	if p == nil or token == nil then
		-- Another window's dialog, an expired one, or a link from elsewhere.
		return { handled = true }
	end
	pending[token] = nil
	if action ~= "cancel" then
		p.on(cx, action, params)
	end
	return { handled = true }
end

-- Runs palette command `id`.
function app.run(id: string, cx: WindowCx, shared: Shared)
	if id == "new" then
		require("./flows/create").new(cx, shared)
	else
		local manage = require("./flows/manage")
		local fn = (manage :: any)[id]
		if fn then
			fn(cx, shared)
		end
	end
end

return app
