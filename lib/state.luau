--!strict
-- Tracked worktrees in `tern.kv` under "worktrees", keyed by absolute path.
-- Tern has no session metadata API, so this map is the 1:1 binding between a
-- worktree and the Tern session named for it. Both halves read it; only the
-- window half writes it.

local util = require("./util")

local state = {}

export type Entry = {
	path: string,
	main: string,
	repo: string,
	branch: string,
	base: string?,
	session_name: string,
	session_id: number?,
	repo_common_dir: string?,
	created_at: number?,
	setup: string?,
}

local KEY = "worktrees"

-- Every tracked worktree by path. A store that can't be read counts as empty.
function state.all(): { [string]: Entry }
	local ok, value = pcall(tern.kv.get, KEY)
	if ok and type(value) == "table" then
		return value
	end
	return {}
end

function state.get(path: string): Entry?
	return state.all()[path]
end

function state.put(entry: Entry)
	local all = state.all()
	all[entry.path] = entry
	tern.kv.set(KEY, all)
end

-- Merges `fields` into the entry at `path`, when it exists.
function state.patch(path: string, fields: { [string]: any })
	local all = state.all()
	local entry = all[path]
	if entry == nil then
		return
	end
	local merged: { [string]: any } = table.clone(entry :: any)
	for k, v in fields do
		merged[k] = v
	end
	all[path] = merged :: any
	tern.kv.set(KEY, all)
end

function state.drop(path: string)
	local all = state.all()
	if all[path] ~= nil then
		all[path] = nil
		tern.kv.set(KEY, all)
	end
end

-- The tracked worktree holding `dir` (the deepest one when they nest), in
-- `entries` (default: the store).
function state.find(dir: string?, entries: { [string]: Entry }?): Entry?
	if dir == nil or dir == "" then
		return nil
	end
	local best: Entry? = nil
	for path, entry in entries or state.all() do
		if util.inside(dir, path) and (best == nil or #path > #best.path) then
			best = entry
		end
	end
	return best
end

return state
