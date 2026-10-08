--!strict
-- worktrees, host half: the dialog blocks the window half opens (new
-- worktree, pick a worktree, one line of quick entry) and the spawn filter
-- that gives shells started inside a tracked worktree TERN_WT_ROOT,
-- TERN_WT_MAIN and TERN_WT_BRANCH.

local util = require("./lib/util")

tern.block.define("new", require("./lib/blocks/new"))
tern.block.define("pick", require("./lib/blocks/pick"))
tern.block.define("line", require("./lib/blocks/line"))

-- Tracked worktrees as {path, main, branch}, deepest path first. Rebuilt
-- from `tern.kv` only when the store changes: `tern.kv.get` re-reads
-- kv.json only when its mtime or length changed, so a spawn costs a stat
-- and a short scan. No git here; the daemon waits on this filter (50 ms).
type Root = { path: string, main: string, branch: string }
local roots: { Root } = {}
local seen: any = nil
local HOME = tern.getenv("HOME")

local function refresh()
	local ok, map = pcall(tern.kv.get, "worktrees")
	if not ok or map == seen then
		return
	end
	seen = map
	local next_roots: { Root } = {}
	if type(map) == "table" then
		for path, entry in map do
			if type(path) == "string" and type(entry) == "table" and type(entry.branch) == "string" then
				table.insert(next_roots, { path = path, main = entry.main or path, branch = entry.branch })
			end
		end
	end
	table.sort(next_roots, function(a: Root, b: Root): boolean
		return #a.path > #b.path
	end)
	roots = next_roots
end

tern.on("spawn", function(spec: SpawnSpec): SpawnSpec?
	refresh()
	if #roots == 0 or spec.cwd == nil then
		return nil
	end
	local cwd = util.resolve("/", spec.cwd, HOME)
	for _, root in roots do
		if util.inside(cwd, root.path) then
			spec.env.TERN_WT_ROOT = root.path
			spec.env.TERN_WT_MAIN = root.main
			spec.env.TERN_WT_BRANCH = root.branch
			return spec
		end
	end
	return nil
end)
