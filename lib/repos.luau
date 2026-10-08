--!strict
-- The known-repos registry: the repositories the plugin can start a worktree
-- in from anywhere, keyed by a lowercased alias. Pure (no `tern` calls):
-- every function takes a registry and returns a new one, so `lib/known`
-- (the `tern.kv`-backed store) and the tests share one set of rules.

local util = require("./util")

local repos = {}

export type Repo = {
	-- Short name typed in quick entry (`studio`); unique, case-insensitive.
	alias: string,
	-- The repository's main worktree root.
	path: string,
	-- Default base ref for new worktrees here (`dev`, `origin/main`).
	base: string?,
	-- Last used, in unix seconds; orders the repo picker (most recent first).
	used_at: number,
	-- Came from the user's `repos.json`, so it can't be removed from the UI.
	declared: boolean?,
	-- That file also pinned `base`, so "Set default base…" must refuse.
	fixed_base: boolean?,
}

export type Registry = { [string]: Repo }

-- Quick entry spends these words on grammar, so they can't be aliases.
local RESERVED: { [string]: boolean } = { off = true, from = true, as = true }

local function key(alias: string): string
	return string.lower(alias)
end

local function clean(value: any): string?
	if type(value) ~= "string" then
		return nil
	end
	local trimmed = util.trim(value)
	return if trimmed == "" then nil else trimmed
end

-- The alias a path suggests: `/Users/me/dev/studio-gsm` → `studio-gsm`.
function repos.alias_from_path(path: string): string
	return string.lower(util.slug(util.basename(path)))
end

-- Why `alias` can't be used, or nil.
function repos.alias_problem(alias: string): string?
	if alias == "" then
		return "Type an alias"
	end
	if #alias > 40 then
		return "Alias is longer than 40 characters"
	end
	if not string.match(alias, "^[%a%d][%w%._%-]*$") then
		return "Alias starts with a letter or digit and holds only letters, digits, . _ -"
	end
	if RESERVED[key(alias)] then
		return string.format("%q is a quick-entry keyword; pick another alias", alias)
	end
	return nil
end

-- The entry `token` names, case-insensitively.
function repos.get(reg: Registry, token: string?): Repo?
	if token == nil or token == "" then
		return nil
	end
	return reg[key(util.trim(token))]
end

-- The entry whose main worktree is `path`.
function repos.by_path(reg: Registry, path: string): Repo?
	local want = util.strip_slash(path)
	for _, entry in reg do
		if entry.path == want then
			return entry
		end
	end
	return nil
end

-- Every entry, most recently used first (then alias, so order is stable).
function repos.mru(reg: Registry): { Repo }
	local out: { Repo } = {}
	for _, entry in reg do
		table.insert(out, entry)
	end
	table.sort(out, function(a: Repo, b: Repo): boolean
		if a.used_at ~= b.used_at then
			return a.used_at > b.used_at
		end
		return a.alias < b.alias
	end)
	return out
end

-- A registry built from a decoded `tern.kv` value; anything malformed is
-- skipped rather than raised, so a hand-edited store still loads.
function repos.normalize(raw: any): Registry
	local out: Registry = {}
	if type(raw) ~= "table" then
		return out
	end
	for k, value in raw do
		if type(value) == "table" then
			local path = clean(value.path)
			local alias = clean(value.alias) or (if type(k) == "string" then k else nil)
			if path ~= nil and alias ~= nil and repos.alias_problem(alias) == nil then
				out[key(alias)] = {
					alias = alias,
					path = util.strip_slash(path),
					base = clean(value.base),
					used_at = if type(value.used_at) == "number" then value.used_at else 0,
				}
			end
		end
	end
	return out
end

-- A registry declared in the user's `repos.json`. Accepted shapes:
--   { "repos": { "studio": { "path": "~/dev/studio-gsm", "base": "dev" } } }
--   { "studio": "~/dev/studio-gsm" }
--   [ { "alias": "studio", "path": "~/dev/studio-gsm" } ]
-- `~` resolves against `home`. Malformed entries are skipped.
function repos.declared(raw: any, home: string?): Registry
	local out: Registry = {}
	if type(raw) ~= "table" then
		return out
	end
	local list: any = if type(raw.repos) == "table" then raw.repos else raw
	for k, value in list do
		local alias: string? = if type(k) == "string" then clean(k) else nil
		local path: string? = nil
		local base: string? = nil
		if type(value) == "string" then
			path = clean(value)
		elseif type(value) == "table" then
			alias = clean(value.alias) or alias
			path = clean(value.path)
			base = clean(value.base)
		end
		if alias ~= nil and path ~= nil and repos.alias_problem(alias) == nil then
			out[key(alias)] = {
				alias = alias,
				path = util.strip_slash(util.resolve("/", path, home)),
				base = base,
				used_at = 0,
				declared = true,
				fixed_base = if base ~= nil then true else nil,
			}
		end
	end
	return out
end

-- `declared` entries laid over `stored` ones: the file owns the path and (when
-- it names one) the base, while the store keeps the last-used time that orders
-- the picker. A stored entry naming the same path under another alias goes.
function repos.merge(stored: Registry, declared: Registry): Registry
	if next(declared) == nil then
		return stored
	end
	local declared_paths: { [string]: boolean } = {}
	for _, entry in declared do
		declared_paths[entry.path] = true
	end
	local out: Registry = {}
	for k, entry in stored do
		if declared[k] == nil and not declared_paths[entry.path] then
			out[k] = entry
		end
	end
	for k, entry in declared do
		local same = stored[k]
		if same ~= nil and same.path ~= entry.path then
			same = nil
		end
		out[k] = {
			alias = entry.alias,
			path = entry.path,
			base = entry.base or (if same then same.base else nil),
			used_at = if same then same.used_at else 0,
			declared = true,
			fixed_base = entry.fixed_base,
		}
	end
	return out
end

export type AddSpec = {
	path: string,
	alias: string?,
	base: string?,
	now: number?,
}

-- `spec` added (or its alias/base updated); returns the new registry and the
-- stored entry. Raises a readable message for a bad path, a bad alias, or an
-- alias another repository already holds.
function repos.add(reg: Registry, spec: AddSpec): (Registry, Repo)
	local path = util.strip_slash(util.trim(spec.path))
	if path == "" or string.sub(path, 1, 1) ~= "/" then
		error("Repository path must be absolute: " .. spec.path, 0)
	end
	local existing = repos.by_path(reg, path)
	local alias = clean(spec.alias) or (if existing then existing.alias else repos.alias_from_path(path))
	local problem = repos.alias_problem(alias)
	if problem then
		error(problem, 0)
	end
	local clash = reg[key(alias)]
	if clash ~= nil and clash.path ~= path then
		error(string.format("Alias %s already points at %s", alias, clash.path), 0)
	end
	local entry: Repo = {
		alias = alias,
		path = path,
		base = clean(spec.base) or (if existing then existing.base else nil),
		used_at = spec.now or (if existing then existing.used_at else 0),
		declared = if existing then existing.declared else nil,
		fixed_base = if existing then existing.fixed_base else nil,
	}
	local out: Registry = {}
	for k, other in reg do
		-- Re-aliasing the same repository replaces its old entry.
		if other.path ~= path then
			out[k] = other
		end
	end
	out[key(alias)] = entry
	return out, entry
end

-- The entry `token` names, dropped. Raises when it isn't known, or when
-- `repos.json` declares it.
function repos.remove(reg: Registry, token: string): Registry
	local entry = repos.get(reg, token)
	if entry == nil then
		error(string.format("No known repository %q", util.trim(token)), 0)
	end
	if entry.declared then
		error(string.format("%s is declared in repos.json; remove it there", entry.alias), 0)
	end
	local out: Registry = {}
	for k, other in reg do
		if other ~= entry then
			out[k] = other
		end
	end
	return out
end

-- `token`'s default base set to `base` (nil clears it). Raises when the repo
-- isn't known, or when `repos.json` pins its base.
function repos.set_base(reg: Registry, token: string, base: string?): Registry
	local entry = repos.get(reg, token)
	if entry == nil then
		error(string.format("No known repository %q", util.trim(token)), 0)
	end
	if entry.fixed_base then
		error(string.format("%s's default base is set in repos.json; change it there", entry.alias), 0)
	end
	local out: Registry = {}
	for k, other in reg do
		out[k] = other
	end
	local updated: Repo = {
		alias = entry.alias,
		path = entry.path,
		base = clean(base),
		used_at = entry.used_at,
		declared = entry.declared,
		fixed_base = entry.fixed_base,
	}
	out[key(entry.alias)] = updated
	return out
end

-- The entry for `path` marked used at `now`; unknown paths change nothing.
function repos.touch(reg: Registry, path: string, now: number): Registry
	local entry = repos.by_path(reg, path)
	if entry == nil then
		return reg
	end
	local out: Registry = {}
	for k, other in reg do
		out[k] = other
	end
	out[key(entry.alias)] = {
		alias = entry.alias,
		path = entry.path,
		base = entry.base,
		used_at = now,
		declared = entry.declared,
		fixed_base = entry.fixed_base,
	}
	return out
end

-- `path` registered if it is new, touched if it is known: what a worktree
-- created inside a repository calls, so the repo "just works" afterwards. The
-- alias comes from the folder name, with `-2`, `-3`… when that is taken.
function repos.register(reg: Registry, path: string, now: number): Registry
	local want = util.strip_slash(path)
	if repos.by_path(reg, want) ~= nil then
		return repos.touch(reg, want, now)
	end
	local stem = repos.alias_from_path(want)
	if repos.alias_problem(stem) ~= nil then
		stem = "repo"
	end
	local alias = stem
	local n = 1
	while reg[key(alias)] ~= nil do
		n += 1
		alias = stem .. "-" .. n
	end
	local out = repos.add(reg, { path = want, alias = alias, now = now })
	return out
end

return repos
