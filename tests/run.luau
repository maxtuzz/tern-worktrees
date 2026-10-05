-- Unit and load tests, runnable without Tern:  luau tests/run.luau
-- (from the repository root). Exits non-zero on the first failure.

local stub = require("./stub")
local tern = stub.tern

local util = require("../lib/util")
local url = require("../lib/url")
local config = require("../lib/config")
local setup = require("../lib/setup")
local git = require("../lib/git")
local field = require("../lib/field")
local state = require("../lib/state")
local autoname = require("../lib/autoname")

local passed, failed = 0, 0

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		print("FAIL " .. name .. ": " .. tostring(err))
	end
end

local function eq(a: any, b: any, what: string?)
	if a ~= b then
		error(string.format("%s: expected %s, got %s", what or "value", tostring(b), tostring(a)), 2)
	end
end

local function has(haystack: string, needle: string)
	if not string.find(haystack, needle, 1, true) then
		error("missing " .. needle, 2)
	end
end

local function raises(fn: () -> (), needle: string)
	local ok, err = pcall(fn)
	if ok then
		error("expected an error containing " .. needle, 2)
	end
	if not string.find(tostring(err), needle, 1, true) then
		error("error " .. tostring(err) .. " lacks " .. needle, 2)
	end
end

-- util ---------------------------------------------------------------------

test("slug turns branch names into folder names", function()
	eq(util.slug("feat/login-page"), "feat-login-page")
	eq(util.slug("Max/WIP: thing!"), "Max-WIP-thing")
	eq(util.slug("///"), "worktree")
end)

test("render fills known placeholders only", function()
	eq(util.render("../{repo}.worktrees/{slug}", { repo = "studio", slug = "feat-x" }), "../studio.worktrees/feat-x")
	eq(util.render("{nope}", {}), "{nope}")
end)

test("resolve makes sibling paths", function()
	eq(util.resolve("/src/studio", "../studio.worktrees/feat-x"), "/src/studio.worktrees/feat-x")
	eq(util.resolve("/src/studio", "/abs/x"), "/abs/x")
	eq(util.resolve("/src", "~/w", "/Users/me"), "/Users/me/w")
end)

test("inside matches whole components", function()
	eq(util.inside("/a/b/c", "/a/b"), true)
	eq(util.inside("/a/b", "/a/b/"), true)
	eq(util.inside("/a/bc", "/a/b"), false)
	eq(util.inside(nil, "/a"), false)
end)

test("shell_quote quotes what needs it", function()
	eq(util.shell_quote("/plain/path.sh"), "/plain/path.sh")
	eq(util.shell_quote("it's"), "'it'\\''s'")
	eq(util.shell_quote("$(rm -rf /)"), "'$(rm -rf /)'")
end)

test("branch_problem mirrors git's common rules", function()
	eq(util.branch_problem("feat/ok-1"), nil)
	eq(util.branch_problem("") ~= nil, true)
	eq(util.branch_problem("has space") ~= nil, true)
	eq(util.branch_problem("a..b") ~= nil, true)
	eq(util.branch_problem("x.lock") ~= nil, true)
	eq(util.branch_problem("-x") ~= nil, true)
end)

-- autoname ----------------------------------------------------------------

test("autoname pool is unique, short and git-safe", function()
	local seen = {}
	eq(#autoname.POOL >= 40, true, "pool size")
	for _, name in autoname.POOL do
		eq(seen[name], nil, "duplicate " .. name)
		seen[name] = true
		eq(util.slug(name), name, "slug of " .. name)
		eq(util.branch_problem(name), nil, "branch " .. name)
		eq(#name <= 10, true, "length of " .. name)
	end
end)

test("autoname skips taken branches, slugs and sessions and rotates", function()
	local pool = { "pearlfish", "manatee", "murex" }
	local name, nxt = autoname.pick({}, 1, "", nil, pool)
	eq(name, "pearlfish")
	eq(nxt, 2)
	name, nxt = autoname.pick({ manatee = true }, 2, "", nil, pool)
	eq(name, "murex")
	eq(nxt, 1)
	local session = function(b)
		return "studio:" .. b
	end
	name = autoname.pick({ ["studio:pearlfish"] = true }, 1, "", session, pool)
	eq(name, "manatee")
	name = autoname.pick({ ["max-pearlfish"] = true }, 1, "max/", nil, pool)
	eq(name, "max/manatee", "slug of a prefixed branch is checked")
	name = autoname.pick({ pearlfish = true, manatee = true, murex = true }, 3, "", nil, pool)
	eq(name, "murex-2")
	eq(autoname.pick({}, 99, "", nil, pool), "murex", "cursor wraps")
end)

-- url ----------------------------------------------------------------------

test("links round-trip", function()
	local link = url.build("create", { token = "t1", branch = "feat/a b&c", base = "origin/main" })
	local action, params = url.parse(link)
	eq(action, "create")
	eq(params.branch, "feat/a b&c")
	eq(params.base, "origin/main")
	eq(params.token, "t1")
	eq((url.parse("https://example.com")), nil)
end)

-- config -------------------------------------------------------------------

test("defaults follow DESIGN.md", function()
	local cfg = config.normalize(nil)
	eq(cfg.root, "../{repo}.worktrees/{slug}")
	eq(cfg.session_name, "{repo}:{branch}")
	eq(#cfg.phases.post_create, 0)
end)

test("normalize validates steps", function()
	local cfg = config.normalize({
		base = { "origin/dev", "origin/main" },
		post_open_actions = { "plugin.branch-changes.open" },
		phases = {
			post_create = {
				{ ["require"] = { "node>=24", "pnpm" } },
				{ copy = { ".env", "apps/*/.env" }, from = "main", if_missing = true },
				{ sync_dir = ".hamster/", from = "main", optional = true },
				{ run = "pnpm install", env = { CI = "true" } },
			},
			services = { { run = "pnpm dev", confirm = "Start?" }, { wait_for = { url = "http://x", timeout_s = 5 } } },
		},
	})
	eq(#cfg.phases.post_create, 4)
	eq(cfg.phases.post_create[2].kind, "copy")
	eq(cfg.phases.post_create[3].optional, true)
	eq(cfg.phases.services[1].kind, "run")
	eq(cfg.phases.services[1].confirm, "Start?")
	eq(cfg.post_open_actions[1], "plugin.branch-changes.open")
end)

test("normalize rejects bad input with the field name", function()
	raises(function()
		config.normalize({ bogus = 1 })
	end, "bogus: unknown key")
	raises(function()
		config.normalize({ phases = { post_create = { { nope = 1 } } } })
	end, "phases.post_create[1]")
	raises(function()
		config.normalize({ phases = { post_create = { { copy = "../secret" } } } })
	end, "relative path inside")
	raises(function()
		config.normalize({ root = "/tmp/fixed" })
	end, "root")
end)

test("cursor and superset configs import", function()
	local c = config.from_cursor({ ["setup-worktree"] = { "npm ci", "cp $ROOT_WORKTREE_PATH/.env .env" } })
	eq(#c.phases.post_create, 2)
	eq(c.phases.post_create[1].run, "npm ci")
	eq(c.source, ".cursor/worktrees.json")
	local s = config.from_superset({ setup = { "bun install" }, teardown = { "docker compose down" } })
	eq(s.phases.post_create[1].run, "bun install")
	eq(s.phases.pre_remove[1].run, "docker compose down")
end)

test("load prefers .tern over importers", function()
	stub.files["/r/.cursor/worktrees.json"] = tern.json.encode({ ["setup-worktree"] = { "a" } })
	eq(config.load("/r").source, ".cursor/worktrees.json")
	stub.files["/r/.tern/worktrees.json"] = tern.json.encode({ branch_prefix = "max/" })
	local cfg = config.load("/r")
	eq(cfg.source, ".tern/worktrees.json")
	eq(cfg.branch_prefix, "max/")
end)

-- setup --------------------------------------------------------------------

test("compile exports vars and guards each step", function()
	local cfg = config.normalize({
		phases = { post_create = { { run = "echo hi", env = { CI = "true" } }, { copy = ".env", if_missing = true, optional = true } } },
	})
	local script = setup.compile("post_create", cfg.phases.post_create, { path = "/w/x", main = "/m", branch = "x", base = "main" })
	has(script, "export WT_PATH=/w/x")
	has(script, 'export ROOT_WORKTREE_PATH="$WT_MAIN"')
	has(script, "( export CI=true; echo hi")
	has(script, "__wt_place copy 1 .env || __wt_warn")
	has(script, "[1/2]")
end)

-- git ----------------------------------------------------------------------

test("parse_worktrees reads porcelain", function()
	local list = git.parse_worktrees(table.concat({
		"worktree /src/studio",
		"HEAD abc123",
		"branch refs/heads/main",
		"",
		"worktree /src/studio.worktrees/feat-x",
		"HEAD def456",
		"branch refs/heads/feat/x",
		"locked in use",
		"",
		"worktree /src/studio.worktrees/old",
		"HEAD 0123456789",
		"detached",
		"prunable gitdir file points to non-existent location",
		"",
	}, "\n"))
	eq(#list, 3)
	eq(list[1].main, true)
	eq(list[1].branch, "main")
	eq(list[2].branch, "feat/x")
	eq(list[2].locked, true)
	eq(list[2].lock_reason, "in use")
	eq(list[3].detached, true)
	eq(list[3].prunable, true)
	eq(list[3].main, false)
end)

-- field --------------------------------------------------------------------

test("field edits at the caret", function()
	local f = field.new("feat")
	field.key(f, stub.key("/", "/"))
	field.key(f, stub.key("x", "x"))
	eq(f.text, "feat/x")
	field.key(f, stub.key("left"))
	field.key(f, stub.key("backspace"))
	eq(f.text, "featx")
	eq(f.cursor, 4)
	eq(field.key(f, stub.key("f5")), false)
end)

-- state --------------------------------------------------------------------

test("state finds the deepest tracked worktree", function()
	state.put({ path = "/w/a", main = "/m", repo = "m", branch = "a", session_name = "m:a" })
	state.put({ path = "/w/a/nested", main = "/m", repo = "m", branch = "n", session_name = "m:n" })
	eq((state.find("/w/a/src") :: any).branch, "a")
	eq((state.find("/w/a/nested/x") :: any).branch, "n")
	eq(state.find("/elsewhere"), nil)
	state.drop("/w/a/nested")
	state.drop("/w/a")
	eq(next(state.all()), nil)
end)

-- host half ----------------------------------------------------------------

test("host half loads and defines its blocks", function()
	require("../host")
	eq(stub.registered.blocks.new ~= nil, true)
	eq(stub.registered.blocks.pick ~= nil, true)
	eq(#stub.registered.events.spawn, 1)
end)

test("spawn filter injects TERN_WT_* inside tracked worktrees only", function()
	state.put({ path = "/w/feat-x", main = "/m", repo = "m", branch = "feat/x", session_name = "m:feat/x" })
	local filter = stub.registered.events.spawn[1]
	local spec = filter({ program = "/bin/zsh", args = {}, cwd = "/w/feat-x/src", env = { TERN_PANE = "1" } })
	eq(spec.env.TERN_WT_ROOT, "/w/feat-x")
	eq(spec.env.TERN_WT_MAIN, "/m")
	eq(spec.env.TERN_WT_BRANCH, "feat/x")
	eq(spec.env.TERN_PANE, "1")
	eq(filter({ program = "/bin/zsh", args = {}, cwd = "/elsewhere", env = {} }), nil)
	state.drop("/w/feat-x")
end)

test("dialog block hands branch and base back as a tokened link", function()
	local dialog = stub.registered.blocks.new
	local cx = stub.block_cx()
	local arg = tern.json.encode({
		token = "tok",
		repo = "studio",
		main = "/src/studio",
		root = "../{repo}.worktrees/{slug}",
		prefix = "",
		session_name = "{repo}:{branch}",
		bases = { "origin/main", "HEAD" },
	})
	local s = dialog.init(cx, { arg }, nil)
	for _, ch in { "f", "e", "a", "t", "/", "x" } do
		dialog.key(s, stub.key(ch, ch), cx)
	end
	dialog.key(s, stub.key("down"), cx)
	local view = dialog.view(s, cx)
	eq(view.main.k, "col")
	dialog.key(s, stub.key("enter"), cx)
	eq(#cx.opened, 1)
	local action, params = url.parse(cx.opened[1])
	eq(action, "create")
	eq(params.token, "tok")
	eq(params.branch, "feat/x")
	eq(params.base, "HEAD")
end)

test("dialog refuses invalid branch names", function()
	local dialog = stub.registered.blocks.new
	local cx = stub.block_cx()
	local s = dialog.init(cx, { tern.json.encode({ token = "t", repo = "r", main = "/r", root = "../{slug}", prefix = "", bases = {} }) }, nil)
	dialog.key(s, stub.key("paste", "bad name"), cx)
	dialog.key(s, stub.key("enter"), cx)
	eq(#cx.opened, 0)
	eq(s.problem ~= nil, true)
end)

test("dialog submits a blank branch for an autoname", function()
	local dialog = stub.registered.blocks.new
	local cx = stub.block_cx()
	local s = dialog.init(cx, { tern.json.encode({ token = "t", repo = "r", main = "/r", root = "../{slug}", prefix = "", bases = { "HEAD" } }) }, nil)
	dialog.view(s, cx)
	dialog.key(s, stub.key("enter"), cx)
	local action, params = url.parse(cx.opened[1])
	eq(action, "create")
	eq(params.branch, "")
end)

test("picker hands the choice back", function()
	local picker = stub.registered.blocks.pick
	local cx = stub.block_cx()
	local s = picker.init(cx, { tern.json.encode({ token = "p", title = "Open", items = { { label = "a", choice = "1" }, { label = "b", choice = "2" } } }) }, nil)
	picker.key(s, stub.key("down"), cx)
	picker.view(s, cx)
	picker.key(s, stub.key("enter"), cx)
	local action, params = url.parse(cx.opened[1])
	eq(action, "pick")
	eq(params.choice, "2")
end)

-- window half --------------------------------------------------------------

test("window half registers six commands, a link route and a status segment", function()
	tern.context = "window"
	require("../window")
	local ids = {}
	for _, c in stub.registered.commands do
		table.insert(ids, c.id)
	end
	table.sort(ids)
	eq(table.concat(ids, ","), "adopt,new,open,prune,remove,setup")
	eq(#stub.registered.links, 1)
	eq(stub.registered.links[1]({ url = "https://example.com", mods = {} }, {}), nil)
end)

test("status segment shows the branch inside a tracked worktree", function()
	state.put({ path = "/w/feat-y", main = "/m", repo = "m", branch = "feat/y", session_name = "m:feat/y" })
	-- `window_start` re-reads the index from kv.
	local cx = { session = { focused = function() return nil end } }
	stub.registered.events.window_start[1](cx)
	local segs = stub.registered.status({ pane = 1, cwd = "/w/feat-y/app", program = "zsh", title = "", busy = false })
	eq(segs[1].text, "⎇ feat/y")
	eq(stub.registered.status({ pane = 1, cwd = "/other", program = "zsh", title = "", busy = false }), nil)
end)

test("window half exports Carly create and list with valid specs", function()
	for _, name in { "create", "list" } do
		local e = stub.registered.exports[name]
		eq(e ~= nil, true, name)
		eq(string.match(name, "^[a-z][a-z0-9_]*$") ~= nil, true)
		eq(#e.spec.sig > 0 and #e.spec.sig <= 1024, true, name .. " sig")
		eq(#e.spec.doc > 0 and #e.spec.doc <= 1024, true, name .. " doc")
	end
end)

test("create with no branch autonames, adds the worktree and reports", function()
	local create = require("../lib/flows/create")
	local config = require("../lib/config")
	stub.kv.autoname_cursor = nil
	local repo = {
		top = "/src/studio",
		common_dir = "/src/studio/.git",
		main = "/src/studio",
		name = "studio",
		branch = "main",
		worktrees = { { path = "/src/studio", branch = "main", main = true, bare = false, detached = false, locked = false, prunable = false } },
	}
	local cfg = config.normalize({ base = { "origin/main" }, phases = { post_create = { { run = "pnpm i" } } } })
	local cx = stub.window_cx("/src/studio")
	local result: any = nil
	stub.processes = {}
	create.run(cx, repo, cfg, { reload = function() end }, nil, nil, function(ok, message)
		result = { ok = ok, message = message }
	end)
	local argv = stub.answer(cx, 0, "main\npearlfish\norigin/main\n")
	eq(argv[4], "for-each-ref")
	argv = stub.answer(cx, 0)
	eq(table.concat(argv, " "), "git -C /src/studio check-ref-format --branch manatee")
	stub.answer(cx, 1) -- rev-parse: no such branch yet
	argv = stub.answer(cx, 0) -- worktree add
	eq(table.concat(argv, " "), "git -C /src/studio worktree add --no-track -b manatee /src/studio.worktrees/manatee origin/main")
	eq(result.ok, true)
	has(result.message, "/src/studio.worktrees/manatee")
	has(result.message, "session studio:manatee")
	has(result.message, "setup started")
	eq(cx.created[1].name, "studio:manatee")
	eq(cx.created[1].cwd, "/src/studio.worktrees/manatee")
	eq(state.get("/src/studio.worktrees/manatee").branch, "manatee")
	eq(stub.kv.autoname_cursor, 3)

	-- The next autoname continues the rotation instead of restarting.
	create.run(cx, repo, cfg, { reload = function() end }, "", "HEAD", nil)
	stub.answer(cx, 0, "main\n")
	argv = stub.answer(cx, 0)
	eq(argv[#argv], "murex")
	stub.processes = {}
	state.drop("/src/studio.worktrees/manatee")
end)

test("create reports git failures to the caller", function()
	local create = require("../lib/flows/create")
	local config = require("../lib/config")
	local repo = { top = "/r", common_dir = "/r/.git", main = "/r", name = "r", worktrees = {} }
	local cx = stub.window_cx("/r")
	local result: any = nil
	stub.processes = {}
	create.run(cx, repo, config.normalize(nil), { reload = function() end }, "feat/x", "HEAD", function(ok, message)
		result = { ok = ok, message = message }
	end)
	stub.answer(cx, 128) -- check-ref-format
	eq(result.ok, false)
	has(result.message, "Not a valid branch name")
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
	error("tests failed", 0)
end
