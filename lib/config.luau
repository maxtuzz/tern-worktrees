--!strict
-- Project config: `.tern/worktrees.json` in the main worktree, else an
-- import of `.cursor/worktrees.json` or `.superset/config.json`, else the
-- defaults. `normalize` and the importers are pure (tested with plain luau);
-- only `load` touches `tern`.

local config = {}

export type Step = { [string]: any }

export type Config = {
	root: string,
	branch_prefix: string,
	base: { string },
	fetch_before_create: boolean,
	session_name: string,
	post_open_actions: { string },
	phases: {
		post_create: { Step },
		pre_remove: { Step },
		services: { Step },
	},
	-- Where it came from: "default", ".tern/worktrees.json", ….
	source: string,
}

config.FILE = ".tern/worktrees.json"
config.CURSOR_FILE = ".cursor/worktrees.json"
config.SUPERSET_FILE = ".superset/config.json"

local STEP_KINDS = { "run", "copy", "symlink", "sync_dir", "wait_for", "require", "confirm" }
local PHASES = { "post_create", "pre_remove", "services" }
local TOP_KEYS: { [string]: boolean } = {
	["$schema"] = true,
	root = true,
	branch_prefix = true,
	base = true,
	fetch_before_create = true,
	session_name = true,
	post_open_actions = true,
	phases = true,
}

local function fail(where: string, message: string): never
	error(string.format("%s: %s", where, message), 0)
end

local function defaults(): Config
	return {
		root = "../{repo}.worktrees/{slug}",
		branch_prefix = "",
		base = { "origin/main", "origin/master", "main", "master" },
		fetch_before_create = false,
		session_name = "{repo}:{branch}",
		post_open_actions = {},
		phases = { post_create = {}, pre_remove = {}, services = {} },
		source = "default",
	}
end
config.defaults = defaults

local function string_or(value: any, fallback: string, where: string): string
	if value == nil then
		return fallback
	end
	if type(value) ~= "string" then
		fail(where, "must be a string")
	end
	return value
end

local function string_list(value: any, where: string): { string }
	if type(value) == "string" then
		return { value }
	end
	if type(value) ~= "table" then
		fail(where, "must be a string or an array of strings")
	end
	local out: { string } = {}
	for i, item in value do
		if type(item) ~= "string" then
			fail(string.format("%s[%d]", where, i), "must be a string")
		end
		table.insert(out, item)
	end
	return out
end

-- Copy/symlink sources must stay inside the main worktree.
local function relative_globs(value: any, where: string): { string }
	local globs = string_list(value, where)
	for i, g in globs do
		if string.sub(g, 1, 1) == "/" or string.find("/" .. g .. "/", "/../", 1, true) then
			fail(string.format("%s[%d]", where, i), "must be a relative path inside the repository")
		end
	end
	return globs
end

-- One validated step: exactly one kind key plus its options.
local function step(raw: any, where: string): Step
	if type(raw) ~= "table" then
		fail(where, "must be an object")
	end
	local kind: string? = nil
	for _, k in STEP_KINDS do
		if raw[k] ~= nil and not (k == "confirm" and raw.run ~= nil) then
			if kind then
				fail(where, "has both " .. kind .. " and " .. k)
			end
			kind = k
		end
	end
	if kind == nil then
		fail(where, "needs one of run, copy, symlink, sync_dir, wait_for, require, confirm")
	end
	local out: Step = { kind = kind, optional = raw.optional == true }
	if raw.optional ~= nil and type(raw.optional) ~= "boolean" then
		fail(where .. ".optional", "must be a boolean")
	end
	if kind == "run" then
		out.run = string_or(raw.run, "", where .. ".run")
		if out.run == "" then
			fail(where .. ".run", "must not be empty")
		end
		out.cwd = if raw.cwd ~= nil then string_or(raw.cwd, ".", where .. ".cwd") else nil
		out.confirm = if raw.confirm ~= nil then string_or(raw.confirm, "", where .. ".confirm") else nil
		if raw.env ~= nil then
			if type(raw.env) ~= "table" then
				fail(where .. ".env", "must be an object of strings")
			end
			local env: { [string]: string } = {}
			for k, v in raw.env do
				if type(k) ~= "string" or not string.match(k, "^[%a_][%w_]*$") then
					fail(where .. ".env", "has an invalid variable name " .. tostring(k))
				end
				if type(v) ~= "string" and type(v) ~= "number" and type(v) ~= "boolean" then
					fail(where .. ".env." .. k, "must be a string")
				end
				env[k] = tostring(v)
			end
			out.env = env
		end
	elseif kind == "copy" or kind == "symlink" then
		out.paths = relative_globs(raw[kind], where .. "." .. kind)
		local from = string_or(raw.from, "main", where .. ".from")
		if from ~= "main" then
			fail(where .. ".from", "only \"main\" is supported")
		end
		out.if_missing = raw.if_missing == true
	elseif kind == "sync_dir" then
		out.paths = relative_globs(raw.sync_dir, where .. ".sync_dir")
		local from = string_or(raw.from, "main", where .. ".from")
		if from ~= "main" then
			fail(where .. ".from", "only \"main\" is supported")
		end
	elseif kind == "wait_for" then
		local w = raw.wait_for
		if type(w) == "string" then
			w = { url = w }
		end
		if type(w) ~= "table" then
			fail(where .. ".wait_for", "must be an object with url or port")
		end
		out.url = if w.url ~= nil then string_or(w.url, "", where .. ".wait_for.url") else nil
		if w.port ~= nil and type(w.port) ~= "number" then
			fail(where .. ".wait_for.port", "must be a number")
		end
		out.port = w.port
		if out.url == nil and out.port == nil then
			fail(where .. ".wait_for", "needs url or port")
		end
		if w.timeout_s ~= nil and type(w.timeout_s) ~= "number" then
			fail(where .. ".wait_for.timeout_s", "must be a number")
		end
		out.timeout_s = w.timeout_s or 120
	elseif kind == "require" then
		out.tools = string_list(raw["require"], where .. ".require")
		for i, spec in out.tools do
			if not string.match(spec, "^[%w%._%-]+$") and not string.match(spec, "^[%w%._%-]+>=[%d%.]+$") then
				fail(string.format("%s.require[%d]", where, i), "must look like \"pnpm\" or \"node>=24\"")
			end
		end
	elseif kind == "confirm" then
		out.question = string_or(raw.confirm, "", where .. ".confirm")
	end
	return out
end

local function steps(raw: any, where: string): { Step }
	if raw == nil then
		return {}
	end
	if type(raw) ~= "table" then
		fail(where, "must be an array of steps")
	end
	local out: { Step } = {}
	for i, s in raw do
		table.insert(out, step(s, string.format("%s[%d]", where, i)))
	end
	return out
end

-- A validated config from decoded JSON `raw`; raises `field: message`.
function config.normalize(raw: any, source: string?): Config
	local cfg = defaults()
	cfg.source = source or config.FILE
	if raw == nil then
		return cfg
	end
	if type(raw) ~= "table" then
		fail(cfg.source, "must hold a JSON object")
	end
	for k in raw do
		if not TOP_KEYS[k] then
			fail(tostring(k), "unknown key")
		end
	end
	cfg.root = string_or(raw.root, cfg.root, "root")
	if not string.find(cfg.root, "{slug}", 1, true) and not string.find(cfg.root, "{branch}", 1, true) then
		fail("root", "must contain {slug} or {branch}")
	end
	cfg.branch_prefix = string_or(raw.branch_prefix, cfg.branch_prefix, "branch_prefix")
	if raw.base ~= nil then
		cfg.base = string_list(raw.base, "base")
	end
	if raw.fetch_before_create ~= nil then
		if type(raw.fetch_before_create) ~= "boolean" then
			fail("fetch_before_create", "must be a boolean")
		end
		cfg.fetch_before_create = raw.fetch_before_create
	end
	cfg.session_name = string_or(raw.session_name, cfg.session_name, "session_name")
	if raw.post_open_actions ~= nil then
		cfg.post_open_actions = string_list(raw.post_open_actions, "post_open_actions")
	end
	if raw.phases ~= nil then
		if type(raw.phases) ~= "table" then
			fail("phases", "must be an object")
		end
		for k in raw.phases do
			if not table.find(PHASES, k) then
				fail("phases." .. tostring(k), "unknown phase (post_create, pre_remove, services)")
			end
		end
		cfg.phases = {
			post_create = steps(raw.phases.post_create, "phases.post_create"),
			pre_remove = steps(raw.phases.pre_remove, "phases.pre_remove"),
			services = steps(raw.phases.services, "phases.services"),
		}
	end
	return cfg
end

-- Commands as `run` steps (blank entries skipped).
local function runs(commands: any): { any }
	local out = {}
	if type(commands) == "string" then
		commands = { commands }
	end
	if type(commands) ~= "table" then
		return out
	end
	for _, c in commands do
		if type(c) == "string" and string.match(c, "%S") then
			table.insert(out, { run = c })
		end
	end
	return out
end

-- Cursor's `.cursor/worktrees.json`: `setup-worktree-unix` (or
-- `setup-worktree`) commands, run with `$ROOT_WORKTREE_PATH` set.
function config.from_cursor(raw: any): Config
	if type(raw) ~= "table" then
		fail(config.CURSOR_FILE, "must hold a JSON object")
	end
	local commands = raw["setup-worktree-unix"] or raw["setup-worktree"]
	return config.normalize({ phases = { post_create = runs(commands) } }, config.CURSOR_FILE)
end

-- Superset's `.superset/config.json`: `setup` and `teardown` command lists.
function config.from_superset(raw: any): Config
	if type(raw) ~= "table" then
		fail(config.SUPERSET_FILE, "must hold a JSON object")
	end
	return config.normalize({
		phases = { post_create = runs(raw.setup), pre_remove = runs(raw.teardown) },
	}, config.SUPERSET_FILE)
end

local function read_json(path: string): any
	local ok, text = pcall(tern.fs.read, path, 1024 * 1024)
	if not ok then
		fail(path, "can't be read")
	end
	local decoded, data = pcall(tern.json.decode, text)
	if not decoded then
		fail(path, "isn't valid JSON (" .. tostring(data) .. ")")
	end
	return data
end

-- The config of the repository whose main worktree is `main`. Raises a
-- readable message when a file is malformed.
function config.load(main: string): Config
	local own = main .. "/" .. config.FILE
	if tern.fs.exists(own) then
		return config.normalize(read_json(own), config.FILE)
	end
	local cursor = main .. "/" .. config.CURSOR_FILE
	if tern.fs.exists(cursor) then
		return config.from_cursor(read_json(cursor))
	end
	local superset = main .. "/" .. config.SUPERSET_FILE
	if tern.fs.exists(superset) then
		return config.from_superset(read_json(superset))
	end
	return defaults()
end

return config
