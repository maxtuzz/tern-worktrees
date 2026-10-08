--!strict
-- Carly exports (desktop window only): agents create and list worktrees, and
-- manage the known-repos registry, without the dialogs. Carly calls
-- `await(plugins.worktrees.create())`, `await(plugins.worktrees.create{repo =
-- "studio", base = "dev"})` or the old positional
-- `await(plugins.worktrees.create("feat/x", "origin/main"))`; arguments and
-- results cross as JSON. Answers come later from git callbacks through
-- `call:reply` / `call:fail`.

local carly = {}

-- Loaded on first call, so registering at window load stays cheap.
local function app()
	return require("./app")
end

local function known()
	return require("./known")
end

-- Worktree creation can include a fetch and a large checkout.
local CREATE_WAIT_MS = 120000
local LIST_WAIT_MS = 20000

local CREATE_KEYS: { [string]: boolean } = { branch = true, base = true, dir = true, repo = true }

local function optional_string(value: any, name: string): string?
	if value == nil or value == tern.json.null then
		return nil
	end
	if type(value) ~= "string" then
		error(name .. " must be a string", 0)
	end
	return value
end

-- `dir` when given (`~` expanded, relative to the focused pane), else the
-- focused pane's directory.
local function target_dir(cx: WindowCx, dir: string?): string
	local focused = app().focused_cwd(cx)
	if dir and dir ~= "" then
		return require("./util").resolve(focused or tern.getenv("HOME") or "/", dir, tern.getenv("HOME"))
	end
	if focused == nil then
		error("no directory: focus a shell inside a git repository, or pass repo or dir", 0)
	end
	return focused
end

local function alias_list(): string
	local names: { string } = {}
	for _, entry in known().mru() do
		table.insert(names, entry.alias)
	end
	return if #names == 0 then "none registered" else table.concat(names, ", ")
end

-- A directory inside the repository to work in: the registry entry `repo`
-- names (so this works from anywhere), else `dir`, else the focused pane.
local function where(cx: WindowCx, repo: string?, dir: string?): string
	if repo == nil or repo == "" then
		return target_dir(cx, dir)
	end
	local entry = known().get(repo)
	if entry == nil then
		error(string.format("no known repo %q; known: %s (add one with add_repo)", repo, alias_list()), 0)
	end
	return entry.path
end

-- `create`'s arguments, from either a single options table or the old
-- positional `(branch, base, dir)`.
local function create_opts(branch: any, base: any, dir: any): { [string]: string? }
	if type(branch) == "table" and branch ~= tern.json.null then
		if base ~= nil or dir ~= nil then
			error("pass create either one options table or positional branch, base, dir", 0)
		end
		for k in branch do
			if not CREATE_KEYS[tostring(k)] then
				error(string.format("unknown create option %q (branch, base, dir, repo)", tostring(k)), 0)
			end
		end
		return {
			branch = optional_string(branch.branch, "branch"),
			base = optional_string(branch.base, "base"),
			dir = optional_string(branch.dir, "dir"),
			repo = optional_string(branch.repo, "repo"),
		}
	end
	return {
		branch = optional_string(branch, "branch"),
		base = optional_string(base, "base"),
		dir = optional_string(dir, "dir"),
	}
end

function carly.register(shared: { reload: () -> () })
	tern.carly.export("create", {
		sig = "(branch: string?, base: string?, dir: string?) | ({repo: string?, branch: string?, base: string?, dir: string?}) -> string",
		doc = "Create a git worktree plus a Tern session for it, like the palette's New worktree session. "
			.. "Call it with one table — create{repo=\"studio\", base=\"dev\"} — or positionally "
			.. "(branch, base, dir). repo: an alias from repos(), which works from any session or "
			.. "directory. branch: omit for the next free sea-creature autoname (pearlfish, manatee, "
			.. "murex…). base: ref new branches start from; a bare name resolves to origin/<name> when "
			.. "only that exists; default the repo's registered base, else the first existing configured "
			.. "base (.tern/worktrees.json base), else HEAD; origin/<branch> bases are fetched first "
			.. "(offline falls back to the local ref). dir: any path in the repository; default the "
			.. "focused pane's directory. Worktree goes to ../{repo}.worktrees/{slug}, session "
			.. "{repo}:{branch}, post_create setup is typed into its pane. An existing worktree of the "
			.. "branch is reused. Returns a line with path, branch, session and whether setup started.",
	}, function(branch: any, base: any, dir: any, cx: WindowCx, call: ExportCall)
		local opts = create_opts(branch, base, dir)
		local target = where(cx, opts.repo, opts.dir)
		app().repo_at(target, function(repo, cfg, why, cx2)
			if repo == nil or cfg == nil or cx2 == nil then
				call:fail(why or "no repository")
				return
			end
			require("./flows/create").run(cx2, repo, cfg, shared, opts.branch, opts.base, function(ok, message, _cx)
				if ok then
					call:reply(message)
				else
					call:fail(message)
				end
			end)
		end)
		return call:wait(CREATE_WAIT_MS)
	end)

	tern.carly.export("list", {
		sig = "(dir: string?, repo: string?) -> {{path: string, branch: string?, main: boolean, locked: boolean, session: string?}}",
		doc = "The git worktrees of a repository, with the Tern session bound to each tracked one. "
			.. "repo: an alias from repos(). dir: any path in the repository. "
			.. "Default: the focused pane's directory.",
	}, function(dir: any, repo_alias: any, cx: WindowCx, call: ExportCall)
		local target = where(cx, optional_string(repo_alias, "repo"), optional_string(dir, "dir"))
		app().repo_at(target, function(repo, _cfg, why, _cx)
			if repo == nil then
				call:fail(why or "no repository")
				return
			end
			local rows = {}
			for _, wt in repo.worktrees do
				if not wt.bare then
					local tracked = require("./state").get(wt.path)
					table.insert(rows, {
						path = wt.path,
						branch = wt.branch or tern.json.null,
						main = wt.main,
						locked = wt.locked,
						session = if tracked then tracked.session_name else tern.json.null,
					})
				end
			end
			call:reply(tern.json.array(rows))
		end)
		return call:wait(LIST_WAIT_MS)
	end)

	tern.carly.export("repos", {
		sig = "() -> {{alias: string, path: string, base: string?, used_at: number, declared: boolean}}",
		doc = "The repositories worktrees knows about, most recently used first. alias is what create "
			.. "and list take as repo; path is the main worktree; base is the default ref new worktrees "
			.. "start from (null when unset); used_at is unix seconds; declared is true for entries "
			.. "fixed in the user's repos.json. Repos register themselves the first time a worktree is "
			.. "created in them; add_repo names one up front.",
	}, function(_cx: WindowCx, _call: ExportCall)
		local rows = {}
		for _, entry in known().mru() do
			table.insert(rows, {
				alias = entry.alias,
				path = entry.path,
				base = entry.base or tern.json.null,
				used_at = entry.used_at,
				declared = entry.declared == true,
			})
		end
		return tern.json.array(rows)
	end)

	tern.carly.export("add_repo", {
		sig = "(path: string, alias: string?, base: string?) -> {alias: string, path: string, base: string?}",
		doc = "Register a repository so create and list can name it from anywhere. path: any path in "
			.. "the repository (`~` and relative paths resolve against the focused pane); it is stored "
			.. "as the main worktree root. alias: short name, default the folder name; unique, "
			.. "case-insensitive, and not off/from/as. base: default ref new worktrees here start from. "
			.. "Adding a path that is already known re-aliases it instead of duplicating it.",
	}, function(path: any, alias: any, base: any, cx: WindowCx, call: ExportCall)
		local given = optional_string(path, "path")
		if given == nil or given == "" then
			error("path is required", 0)
		end
		local want_alias = optional_string(alias, "alias")
		local want_base = optional_string(base, "base")
		local dir = target_dir(cx, given)
		require("./git").repo(dir, function(repo, why, _cx)
			if repo == nil then
				call:fail((why or "not a git repository") .. " · " .. dir)
				return
			end
			local ok, entry = pcall(known().add, { path = repo.main, alias = want_alias, base = want_base })
			if not ok then
				call:fail(tostring(entry))
				return
			end
			call:reply({ alias = entry.alias, path = entry.path, base = entry.base or tern.json.null })
		end)
		return call:wait(LIST_WAIT_MS)
	end)
end

return carly
