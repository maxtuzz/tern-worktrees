--!strict
-- Git, always through async `tern.process.run`: nothing here blocks the
-- window's UI thread. `parse_worktrees` is pure (tested with plain luau).

local util = require("./util")

local git = {}

export type Worktree = {
	path: string,
	head: string?,
	branch: string?, -- short name; nil when detached
	bare: boolean,
	detached: boolean,
	locked: boolean,
	lock_reason: string?,
	prunable: boolean,
	main: boolean, -- the first entry: the main worktree
}

export type Repo = {
	top: string, -- this worktree's root
	common_dir: string, -- the shared .git directory
	main: string, -- the main worktree's root
	name: string, -- the main worktree's folder name
	branch: string?, -- this worktree's branch
	worktrees: { Worktree },
}

local TIMEOUT_MS = 20000

-- Runs git with `args` in `cwd`; `cb(ok, stdout, stderr)` runs later with a
-- fresh window `cx` (nil in the host half).
function git.run(cwd: string, args: { string }, cb: (boolean, string, string, any) -> (), timeout_ms: number?)
	local argv = { "git", "-C", cwd }
	for _, a in args do
		table.insert(argv, a)
	end
	local ok, err = pcall(tern.process.run, argv, {
		cwd = cwd,
		timeout_ms = timeout_ms or TIMEOUT_MS,
		env = { GIT_TERMINAL_PROMPT = "0", GIT_OPTIONAL_LOCKS = "0" },
	}, function(r: ProcessResult, cx: any)
		local why = if r.timed_out then "git " .. (args[1] or "") .. " timed out" else util.trim(r.stderr)
		cb(r.status == 0, r.stdout, why, cx)
	end)
	if not ok then
		tern.timer(0, function(cx: any)
			cb(false, "", tostring(err), cx)
		end)
	end
end

-- `git worktree list --porcelain` output as records; the first is main.
function git.parse_worktrees(text: string): { Worktree }
	local out: { Worktree } = {}
	local current: Worktree? = nil
	for _, line in util.lines(text .. "\n") do
		local key, value = string.match(line, "^(%S+) ?(.*)$")
		if key == "worktree" then
			current = {
				path = value :: string,
				bare = false,
				detached = false,
				locked = false,
				prunable = false,
				main = #out == 0,
			}
			table.insert(out, current :: Worktree)
		elseif current then
			local wt = current :: Worktree
			if key == "HEAD" then
				wt.head = value
			elseif key == "branch" then
				wt.branch = string.gsub(value :: string, "^refs/heads/", "")
			elseif key == "bare" then
				wt.bare = true
			elseif key == "detached" then
				wt.detached = true
			elseif key == "locked" then
				wt.locked = true
				wt.lock_reason = if value ~= "" then value else nil
			elseif key == "prunable" then
				wt.prunable = true
			end
		end
	end
	return out
end

-- The repository holding `dir`: `cb(repo, nil, cx)` or `cb(nil, error, cx)`.
function git.repo(dir: string, cb: (Repo?, string?, any) -> ())
	git.run(dir, { "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir" }, function(ok, out, err, cx)
		if not ok then
			cb(nil, if string.find(err, "not a git repository", 1, true) then "Not inside a git repository" else err, cx)
			return
		end
		local lines = util.lines(out)
		local top, common = lines[1], lines[2]
		if top == nil or common == nil then
			cb(nil, "git rev-parse gave no repository root", cx)
			return
		end
		git.run(top, { "worktree", "list", "--porcelain" }, function(ok2, out2, err2, cx)
			if not ok2 then
				cb(nil, err2, cx)
				return
			end
			local worktrees = git.parse_worktrees(out2)
			local main = if worktrees[1] and not worktrees[1].bare then worktrees[1].path else util.dirname(common)
			local branch: string? = nil
			for _, wt in worktrees do
				if wt.path == top then
					branch = wt.branch
				end
			end
			cb({
				top = top,
				common_dir = common,
				main = main,
				name = util.basename(main),
				branch = branch,
				worktrees = worktrees,
			}, nil, cx)
		end)
	end)
end

-- Uncommitted changes in `dir` (count of porcelain lines): `cb(count?, err, cx)`.
function git.dirty(dir: string, cb: (number?, string?, any) -> ())
	git.run(dir, { "status", "--porcelain", "--untracked-files=normal" }, function(ok, out, err, cx)
		if not ok then
			cb(nil, err, cx)
			return
		end
		cb(#util.lines(out), nil, cx)
	end)
end

-- Commits on HEAD that no remote has: against the upstream when there is
-- one, else against every remote-tracking branch. `cb(count?, err, cx)`.
function git.unpushed(dir: string, cb: (number?, string?, any) -> ())
	git.run(dir, { "rev-list", "--count", "@{upstream}..HEAD" }, function(ok, out, _err, cx)
		if ok then
			cb(tonumber(util.trim(out)), nil, cx)
			return
		end
		git.run(dir, { "rev-list", "--count", "HEAD", "--not", "--remotes" }, function(ok2, out2, err2, cx2)
			cb(if ok2 then tonumber(util.trim(out2)) else nil, if ok2 then nil else err2, cx2)
		end)
	end)
end

return git
