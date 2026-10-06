--!strict
-- Carly exports (desktop window only): agents create and list worktrees
-- without the dialog. Carly calls `await(plugins.worktrees.create())` or
-- `await(plugins.worktrees.create("feat/x", "origin/main"))`; arguments and
-- results cross as JSON. Answers come later from git callbacks through
-- `call:reply` / `call:fail`.

local carly = {}

-- Loaded on first call, so registering at window load stays cheap.
local function app()
	return require("./app")
end

-- Worktree creation can include a fetch and a large checkout.
local CREATE_WAIT_MS = 120000
local LIST_WAIT_MS = 20000

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
		error("no directory: focus a shell inside a git repository or pass dir", 0)
	end
	return focused
end

function carly.register(shared: { reload: () -> () })
	tern.carly.export("create", {
		sig = "(branch: string?, base: string?, dir: string?) -> string",
		doc = "Create a git worktree plus a Tern session for it, like the palette's New worktree session. "
			.. "branch: omit or nil/\"\" for the next free sea-creature autoname (pearlfish, manatee, murex…). "
			.. "base: ref new branches start from; default the first existing configured base "
			.. "(.tern/worktrees.json base, e.g. origin/main), else HEAD. dir: any path in the repository; "
			.. "default the focused pane's directory. Worktree goes to ../{repo}.worktrees/{slug}, session "
			.. "{repo}:{branch}, post_create setup is typed into its pane. An existing worktree of the "
			.. "branch is reused. Returns a line with path, branch, session and whether setup started.",
	}, function(branch: any, base: any, dir: any, cx: WindowCx, call: ExportCall)
		local name = optional_string(branch, "branch")
		local from = optional_string(base, "base")
		local where = target_dir(cx, optional_string(dir, "dir"))
		app().repo_at(where, function(repo, cfg, why, cx2)
			if repo == nil or cfg == nil or cx2 == nil then
				call:fail(why or "no repository")
				return
			end
			require("./flows/create").run(cx2, repo, cfg, shared, name, from, function(ok, message, _cx)
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
		sig = "(dir: string?) -> {{path: string, branch: string?, main: boolean, locked: boolean, session: string?}}",
		doc = "The git worktrees of the repository holding dir (default: the focused pane's directory), "
			.. "with the Tern session bound to each tracked one.",
	}, function(dir: any, cx: WindowCx, call: ExportCall)
		local where = target_dir(cx, optional_string(dir, "dir"))
		app().repo_at(where, function(repo, _cfg, why, _cx)
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
end

return carly
