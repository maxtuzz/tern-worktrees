--!strict
-- The known-repos palette commands: Add repo…, Remove repo… and Set default
-- base…. The registry itself lives in `lib/repos` (pure) and `lib/known`
-- (the `tern.kv` store); this file is only the dialogs around them.

local util = require("../util")
local git = require("../git")
local app = require("../app")
local known = require("../known")
local quick = require("../quick")

local registry = {}

local HOME = tern.getenv("HOME")

local function describe(entry: { alias: string, path: string, base: string? }): string
	return app.tilde(entry.path) .. (if entry.base then " · off " .. (entry.base :: string) else "")
end

-- Registers the repository `line` names: `<path> [as <alias>] [off <base>]`.
local function add(cx: WindowCx, line: string)
	local parsed = quick.parse_repo(line)
	if parsed.problem then
		cx:toast("error", "Add repo", parsed.problem :: string)
		return
	end
	if parsed.path == nil then
		cx:toast("error", "Add repo", "Type a path to a git repository")
		return
	end
	local dir = util.resolve(app.focused_cwd(cx) or HOME or "/", parsed.path :: string, HOME)
	-- `git.repo`, not `app.repo_at`: a malformed `.tern/worktrees.json`
	-- shouldn't stop the repository from being registered.
	git.repo(dir, function(repo, why, cx2)
		if cx2 == nil then
			return
		end
		if repo == nil then
			cx2:toast("error", "Not a git repository", (why or "") .. " · " .. app.tilde(dir))
			return
		end
		local ok, entry = pcall(known.add, { path = repo.main, alias = parsed.alias, base = parsed.base })
		if not ok then
			cx2:toast("error", "Add repo", tostring(entry))
			return
		end
		cx2:toast("success", "Added " .. entry.alias, describe(entry))
	end)
end

-- "Add repo…": one line, prefilled with the focused pane's repository when
-- there is one, so Enter is usually enough.
function registry.addrepo(cx: WindowCx, _shared: app.Shared)
	local function ask(cx2: WindowCx, prefill: string)
		app.line(cx2, {
			action = "addrepo",
			title = "Add repo",
			subtitle = "<path> [as <alias>] [off <base>]",
			value = prefill,
			placeholder = "~/dev/studio-gsm as studio off dev",
			submit = "Add",
			grammar = "repo",
			hints = {
				{ text = "The alias is what you type in Quick worktree; it defaults to the folder name." },
				{ text = "The base is the ref new worktrees here start from." },
			},
		}, function(cx3, line)
			add(cx3, line)
		end)
	end
	local cwd = app.focused_cwd(cx)
	if cwd == nil then
		ask(cx, "")
		return
	end
	git.repo(cwd, function(repo, _why, cx2)
		if cx2 == nil then
			return
		end
		ask(cx2, if repo then app.tilde(repo.main) else "")
	end)
end

-- "Remove repo…": drops a registry entry. Worktrees and folders stay.
function registry.rmrepo(cx: WindowCx, _shared: app.Shared)
	local list = known.mru()
	if #list == 0 then
		cx:toast("info", "No known repositories", "Run \"Add repo…\" to register one")
		return
	end
	local items = {}
	for i, entry in list do
		table.insert(items, {
			label = entry.alias,
			detail = describe(entry) .. (if entry.declared then " · repos.json" else ""),
			choice = tostring(i),
		})
	end
	app.pick(cx, {
		title = "Remove repo",
		subtitle = "only the registry entry; worktrees stay",
		items = items,
	}, function(cx2, choice)
		local entry = list[tonumber(choice) or 0]
		if entry == nil then
			return
		end
		local ok, err = pcall(known.remove, entry.alias)
		if not ok then
			cx2:toast("error", "Remove repo", tostring(err))
			return
		end
		cx2:toast("success", "Removed " .. entry.alias, app.tilde(entry.path))
	end)
end

-- "Set default base…": picks a repository, then its default base ref.
function registry.setbase(cx: WindowCx, _shared: app.Shared)
	local list = known.mru()
	if #list == 0 then
		cx:toast("info", "No known repositories", "Run \"Add repo…\" to register one")
		return
	end
	local function ask(cx2: WindowCx, entry: { alias: string, path: string, base: string? })
		app.line(cx2, {
			action = "setbase",
			title = "Default base · " .. entry.alias,
			subtitle = app.tilde(entry.path),
			value = entry.base or "",
			placeholder = "dev, origin/main… (blank clears it)",
			submit = "Set",
			hints = {
				{ text = "New worktrees in " .. entry.alias .. " start here unless the line says otherwise." },
				{ text = "A bare name resolves to origin/<name> when only the remote ref exists." },
			},
		}, function(cx3, line)
			local base = util.trim(line)
			local ok, err = pcall(known.set_base, entry.alias, if base == "" then nil else base)
			if not ok then
				cx3:toast("error", "Set default base", tostring(err))
				return
			end
			cx3:toast(
				"success",
				entry.alias .. (if base == "" then ": no default base" else ": off " .. base),
				app.tilde(entry.path)
			)
		end)
	end
	if #list == 1 then
		ask(cx, list[1])
		return
	end
	local items = {}
	for i, entry in list do
		table.insert(items, { label = entry.alias, detail = describe(entry), choice = tostring(i) })
	end
	app.pick(cx, { title = "Set default base", subtitle = "which repository?", items = items }, function(cx2, choice)
		local entry = list[tonumber(choice) or 0]
		if entry then
			ask(cx2, entry)
		end
	end)
end

return registry
