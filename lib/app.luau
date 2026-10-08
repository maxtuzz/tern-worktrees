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

-- The actions our own dialog blocks answer with, so a link that finds no
-- live token can be told apart from any other `tern-worktrees://` URL.
local DIALOG_ACTIONS: { [string]: boolean } = {
	create = true,
	pick = true,
	quick = true,
	addrepo = true,
	setbase = true,
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

-- Reads the repository holding `dir` and its config: `cb(repo, cfg, nil,
-- cx)`, or `cb(nil, nil, why, cx)` when there is none or the config is bad.
function app.repo_at(dir: string, cb: (git.Repo?, config.Config?, string?, WindowCx?) -> ())
	git.repo(dir, function(repo, err, cx)
		if repo == nil then
			cb(nil, nil, (err or "no repository") .. " · " .. app.tilde(dir), cx)
			return
		end
		local ok, cfg = pcall(config.load, repo.main)
		if not ok then
			cb(nil, nil, "Worktrees config is invalid: " .. tostring(cfg), cx)
			return
		end
		cb(repo, cfg, nil, cx)
	end)
end

-- Calls `fn(cx, repo, cfg)` for the repository of the focused pane, toasting
-- why when there is none or its config is malformed.
function app.with_repo(cx: WindowCx, fn: (WindowCx, git.Repo, config.Config) -> ())
	local cwd = app.focused_cwd(cx)
	if cwd == nil then
		cx:toast("error", "No directory here", "Focus a shell inside a git repository")
		return
	end
	app.repo_at(cwd, function(repo, cfg, why, cx2)
		if cx2 == nil then
			return
		end
		if repo == nil or cfg == nil then
			cx2:toast("error", "Worktrees: no repository", why or "")
			return
		end
		fn(cx2, repo, cfg)
	end)
end

-- Calls `fn(cx, repo, cfg)` for the repository whose main worktree is
-- `path`, registering it as known on the way.
function app.open_repo(cx: WindowCx, path: string, fn: (WindowCx, git.Repo, config.Config) -> ())
	app.repo_at(path, function(repo, cfg, why, cx2)
		if cx2 == nil then
			return
		end
		if repo == nil or cfg == nil then
			cx2:toast("error", "Worktrees: no repository", why or "")
			return
		end
		pcall(require("./known").register, repo.main)
		fn(cx2, repo, cfg)
	end)
end

-- Asks which known repository to use (most recently used first), then calls
-- `fn(cx, repo, cfg)`. `why` explains why there was nothing closer to hand.
function app.pick_repo(cx: WindowCx, why: string?, fn: (WindowCx, git.Repo, config.Config) -> ())
	local list = require("./known").mru()
	if #list == 0 then
		cx:toast("error", "No known repositories", why or "Run \"Add repo…\" to register one")
		return
	end
	if #list == 1 then
		app.open_repo(cx, list[1].path, fn)
		return
	end
	local items = {}
	for i, entry in list do
		local bits = { app.tilde(entry.path) }
		if entry.base then
			table.insert(bits, "off " .. (entry.base :: string))
		end
		table.insert(items, { label = entry.alias, detail = table.concat(bits, " · "), choice = tostring(i) })
	end
	app.pick(cx, {
		title = "Which repository?",
		subtitle = "most recently used first",
		notes = if why then { { text = why } } else nil,
		items = items,
	}, function(cx2, choice)
		local entry = list[tonumber(choice) or 0]
		if entry then
			app.open_repo(cx2, entry.path, fn)
		end
	end)
end

-- The repository a command should act on, from any session or directory:
-- `alias` when one was typed, else the focused pane's repository, else a pick
-- from the known repos. Calls `fn(cx, repo, cfg)`.
function app.target(cx: WindowCx, alias: string?, fn: (WindowCx, git.Repo, config.Config) -> ())
	local wanted = util.trim(alias or "")
	if wanted ~= "" then
		local entry = require("./known").get(wanted)
		if entry == nil then
			cx:toast("error", "No known repository " .. wanted, "Run \"Add repo…\" first")
			return
		end
		app.open_repo(cx, entry.path, fn)
		return
	end
	local cwd = app.focused_cwd(cx)
	if cwd == nil then
		app.pick_repo(cx, nil, fn)
		return
	end
	app.repo_at(cwd, function(repo, cfg, why, cx2)
		if cx2 == nil then
			return
		end
		if repo ~= nil and cfg ~= nil then
			pcall(require("./known").register, repo.main)
			fn(cx2, repo, cfg)
			return
		end
		app.pick_repo(cx2, why, fn)
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

-- Opens the one-line `line` dialog; `on_line(cx, line)` runs on submit.
function app.line(
	cx: WindowCx,
	spec: {
		action: string,
		title: string,
		subtitle: string?,
		value: string?,
		placeholder: string?,
		submit: string?,
		hints: { any }?,
		grammar: string?,
		aliases: { string }?,
	},
	on_line: (WindowCx, string) -> ()
)
	local token = app.token(function(cx2, _action, params)
		if params.line ~= nil then
			on_line(cx2, params.line)
		end
	end)
	local arg = table.clone(spec) :: { [string]: any }
	arg.token = token
	arg.home = HOME
	arg.hints = tern.json.array(spec.hints or {})
	arg.aliases = tern.json.array(spec.aliases or {})
	if cx:new_block("worktrees.line", { tern.json.encode(arg) }, "below") == nil then
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
	arg.refs = tern.json.array(ctx.refs or ctx.bases)
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
		-- An expired dialog, one whose window VM a plugin reload replaced, or
		-- a link from elsewhere. Saying nothing looks like the command simply
		-- failed, so name it — but only for our own dialogs' actions, and
		-- never for a cancel, which wanted nothing to happen anyway.
		if DIALOG_ACTIONS[action] then
			cx:toast("error", "That dialog has expired", "Run the command again (a plugin reload closes open dialogs)")
		end
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
	elseif id == "quick" then
		require("./flows/create").quick(cx, shared)
	elseif id == "addrepo" or id == "rmrepo" or id == "setbase" then
		(require("./flows/registry") :: any)[id](cx, shared)
	else
		local manage = require("./flows/manage")
		local fn = (manage :: any)[id]
		if fn then
			fn(cx, shared)
		end
	end
end

return app
