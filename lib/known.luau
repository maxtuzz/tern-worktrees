--!strict
-- The known-repos store: `lib/repos`' rules over `tern.kv` key "repos",
-- overlaid with the optional user file `<plugin data>/repos.json`.
--
-- `tern.kv` is the right home for it: it is one JSON file in the plugin's
-- data directory, shared by both halves and every window, re-read only when
-- it changed on disk, and already holds the tracked worktrees. A second
-- hand-rolled JSON file would repeat that machinery; `repos.json` exists
-- only because kv has no schema a user can be asked to hand-edit.
--
-- Tern has no plugin-settings API (`tern.d.luau` exposes `cx.settings`, which
-- reads and writes *Tern's* `settings.json` keys and rejects unknown ones),
-- so repos can't be declared in the user's Tern config. `repos.json` is this
-- plugin's stand-in.

local repos = require("./repos")

local known = {}

local KEY = "repos"
local MAX_BYTES = 256 * 1024

known.FILE = "repos.json"

-- The absolute path of the optional user-declared repo file.
function known.file(): string
	return tern.plugin.data .. "/" .. known.FILE
end

-- Repos declared in `repos.json`; an unreadable or malformed file warns in
-- the log and counts as none, so a typo never breaks the palette.
local function declared(): repos.Registry
	local path = known.file()
	local present, exists = pcall(tern.fs.exists, path)
	if not present or not exists then
		return {}
	end
	local read, text = pcall(tern.fs.read, path, MAX_BYTES)
	if not read then
		tern.log.warn("worktrees: can't read " .. path, tostring(text))
		return {}
	end
	local decoded, data = pcall(tern.json.decode, text)
	if not decoded then
		tern.log.warn("worktrees: " .. known.FILE .. " isn't valid JSON", tostring(data))
		return {}
	end
	local built, reg = pcall(repos.declared, data, tern.getenv("HOME"))
	if not built then
		tern.log.warn("worktrees: " .. known.FILE .. " can't be read", tostring(reg))
		return {}
	end
	return reg
end

-- Every known repository. A store that can't be read counts as empty.
function known.all(): repos.Registry
	local ok, value = pcall(tern.kv.get, KEY)
	return repos.merge(repos.normalize(if ok then value else nil), declared())
end

-- Writes `reg` back. Declared entries are stored too (minus the flags the
-- file owns) so their last-used time survives and still orders the picker.
local function save(reg: repos.Registry)
	local out: { [string]: any } = {}
	for k, entry in reg do
		out[k] = { alias = entry.alias, path = entry.path, base = entry.base, used_at = entry.used_at }
	end
	tern.kv.set(KEY, if next(out) == nil then nil else out)
end

function known.get(token: string?): repos.Repo?
	return repos.get(known.all(), token)
end

function known.by_path(path: string): repos.Repo?
	return repos.by_path(known.all(), path)
end

-- Known repositories, most recently used first.
function known.mru(): { repos.Repo }
	return repos.mru(known.all())
end

-- Adds (or re-aliases) a repository; raises the reason it can't. Returns the
-- stored entry.
function known.add(spec: repos.AddSpec): repos.Repo
	local reg, entry = repos.add(known.all(), {
		path = spec.path,
		alias = spec.alias,
		base = spec.base,
		now = spec.now or os.time(),
	})
	save(reg)
	return entry
end

function known.remove(token: string)
	save(repos.remove(known.all(), token))
end

function known.set_base(token: string, base: string?)
	save(repos.set_base(known.all(), token, base))
end

-- Registers `path` if it is new and marks it used: called whenever a command
-- or a create touches a repository, so it is offered from anywhere next time.
function known.register(path: string)
	save(repos.register(known.all(), path, os.time()))
end

return known
