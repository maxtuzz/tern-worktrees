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
local repos = require("../lib/repos")
local quick = require("../lib/quick")
local known = require("../lib/known")

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

-- repos (the known-repos registry) -----------------------------------------

test("repos derives aliases from paths and checks them", function()
	eq(repos.alias_from_path("/Users/me/dev/studio-gsm"), "studio-gsm")
	eq(repos.alias_from_path("/src/Studio GSM/"), "studio-gsm")
	eq(repos.alias_problem("studio"), nil)
	eq(repos.alias_problem("tern-worktrees"), nil)
	eq(repos.alias_problem("") ~= nil, true)
	eq(repos.alias_problem("has space") ~= nil, true)
	eq(repos.alias_problem("-x") ~= nil, true)
	eq(repos.alias_problem("off") ~= nil, true, "quick-entry keyword")
	eq(repos.alias_problem("FROM") ~= nil, true, "keywords are case-insensitive")
end)

test("repos add defaults the alias, keeps paths unique and refuses clashes", function()
	local reg = repos.add({}, { path = "/src/studio-gsm", now = 10 })
	eq(reg.studio_gsm, nil)
	eq(reg["studio-gsm"].alias, "studio-gsm")
	eq(reg["studio-gsm"].used_at, 10)
	eq(repos.get(reg, "STUDIO-GSM") ~= nil, true, "lookup is case-insensitive")

	reg = repos.add(reg, { path = "/src/studio-gsm", alias = "studio", base = "dev", now = 11 })
	eq(next(reg, next(reg)), nil, "re-aliasing replaces, never duplicates")
	eq(reg.studio.path, "/src/studio-gsm")
	eq(reg.studio.base, "dev")

	reg = repos.add(reg, { path = "/src/tern", now = 12 })
	raises(function()
		repos.add(reg, { path = "/src/other", alias = "studio" })
	end, "already points at /src/studio-gsm")
	raises(function()
		repos.add(reg, { path = "relative/path" })
	end, "must be absolute")
	raises(function()
		repos.add(reg, { path = "/src/x", alias = "off" })
	end, "quick-entry keyword")
end)

test("repos remove, set_base and touch leave the rest alone", function()
	local reg = repos.add(repos.add({}, { path = "/src/a", now = 1 }), { path = "/src/b", now = 2 })
	eq(#repos.mru(reg), 2)
	eq(repos.mru(reg)[1].alias, "b", "most recently used first")

	reg = repos.set_base(reg, "A", "origin/dev")
	eq(reg.a.base, "origin/dev")
	eq(repos.set_base(reg, "a", nil).a.base, nil, "a blank base clears it")

	reg = repos.touch(reg, "/src/a", 9)
	eq(repos.mru(reg)[1].alias, "a")
	eq(repos.touch(reg, "/nowhere", 99), reg, "an unknown path changes nothing")

	reg = repos.remove(reg, "b")
	eq(reg.b, nil)
	eq(reg.a ~= nil, true)
	raises(function()
		repos.remove(reg, "b")
	end, "No known repository")
	raises(function()
		repos.set_base(reg, "b", "x")
	end, "No known repository")
end)

test("repos register auto-names, keeps aliases unique and touches what it knows", function()
	local reg = repos.register({}, "/src/studio", 5)
	eq(reg.studio.path, "/src/studio")
	eq(reg.studio.used_at, 5)
	reg = repos.register(reg, "/elsewhere/studio", 6)
	eq(reg["studio-2"].path, "/elsewhere/studio")
	reg = repos.register(reg, "/src/studio", 7)
	eq(reg.studio.used_at, 7, "a known path is touched, not re-added")
	eq(reg["studio-2"].used_at, 6)
	eq(repos.register(reg, "/", 8)["."], nil)
end)

test("repos normalize skips malformed entries", function()
	local reg = repos.normalize({
		studio = { path = "/src/studio/", base = "dev", used_at = 3 },
		bad = { base = "dev" },
		["has space"] = { path = "/src/x" },
		junk = "nope",
	})
	eq(reg.studio.path, "/src/studio", "trailing slashes go")
	eq(reg.studio.used_at, 3)
	eq(reg.bad, nil)
	eq(reg["has space"], nil)
	eq(reg.junk, nil)
	eq(next(repos.normalize("nope")), nil)
end)

test("repos.json declarations win over the store but keep its MRU time", function()
	local declared = repos.declared({
		repos = {
			studio = { path = "~/dev/studio-gsm", base = "dev" },
			tern = { path = "/src/tern" },
		},
	}, "/Users/me")
	eq(declared.studio.path, "/Users/me/dev/studio-gsm")
	eq(declared.studio.declared, true)
	eq(declared.studio.fixed_base, true)
	eq(declared.tern.fixed_base, nil)
	eq(next(repos.declared({ studio = "~/dev/studio-gsm" }, "/Users/me")) ~= nil, true, "a bare path works")
	eq(repos.declared({ { alias = "studio", path = "/src/s" } }, nil).studio.path, "/src/s", "an array works")

	local stored = repos.normalize({
		studio = { path = "/Users/me/dev/studio-gsm", base = "main", used_at = 42 },
		old = { path = "/src/tern", used_at = 7 },
	})
	local merged = repos.merge(stored, declared)
	eq(merged.studio.base, "dev", "the file's base wins")
	eq(merged.studio.used_at, 42, "the store's last-used time survives")
	eq(merged.old, nil, "a stale alias for a declared path goes")
	eq(merged.tern.path, "/src/tern")
	raises(function()
		repos.remove(merged, "studio")
	end, "declared in repos.json")
	raises(function()
		repos.set_base(merged, "studio", "x")
	end, "set in repos.json")
	eq(repos.set_base(merged, "tern", "dev").tern.base, "dev", "an unpinned base is still settable")
	eq(repos.merge(stored, {}), stored)
end)

-- quick entry --------------------------------------------------------------

test("quick entry parses [repo] [branch] [off <base>]", function()
	local aliases = { studio = true, tern = true }
	local is_alias = function(t: string): boolean
		return aliases[string.lower(t)] == true
	end
	local function p(line: string): any
		return quick.parse(line, is_alias)
	end
	local blank = p("")
	eq(blank.repo, nil)
	eq(blank.branch, nil)
	eq(blank.base, nil)
	eq(blank.problem, nil)

	eq(p("off dev").base, "dev")
	eq(p("off dev").repo, nil)
	eq(p("  from   origin/dev  ").base, "origin/dev", "extra spaces and `from`")

	local one = p("studio off dev")
	eq(one.repo, "studio")
	eq(one.branch, nil)
	eq(one.base, "dev")

	local full = p("studio feat/foo off dev")
	eq(full.repo, "studio")
	eq(full.branch, "feat/foo")
	eq(full.base, "dev")

	eq(p("feat/foo").branch, "feat/foo")
	eq(p("feat/foo").repo, nil)
	eq(p("STUDIO").repo, "STUDIO", "aliases match case-insensitively")
	eq(p("studio").branch, nil)
	eq(p("studio studio").branch, "studio", "a branch named like an alias goes second")

	eq(p("@dev").base, "dev")
	eq(p("--base=dev").base, "dev")
	eq(p("--base dev").base, "dev")
	eq(p("tern feat/x @origin/main").base, "origin/main")
	eq(quick.parse("studio off dev").repo, nil, "without a predicate nothing is a repo")
	eq(quick.parse("studio off dev").branch, "studio")
end)

test("quick entry reports what it can't place", function()
	local p = quick.parse
	has(p("off").problem :: string, "Name a base after off")
	has(p("@").problem :: string, "Name a base after @")
	has(p("a off dev off main").problem :: string, "Two bases")
	has(p("a b c").problem :: string, "Nothing fits")
end)

test("add-repo entry parses <path> [as <alias>] [off <base>]", function()
	local bare = quick.parse_repo("~/dev/studio-gsm")
	eq(bare.path, "~/dev/studio-gsm")
	eq(bare.alias, nil)
	eq(bare.base, nil)

	local full = quick.parse_repo("  /src/studio  as studio off dev ")
	eq(full.path, "/src/studio")
	eq(full.alias, "studio")
	eq(full.base, "dev")
	eq(quick.parse_repo("/src/s --alias s @main").alias, "s")
	eq(quick.parse_repo("/src/s --alias s @main").base, "main")
	eq(quick.parse_repo("").path, nil)
	has(quick.parse_repo("/src/s as").problem :: string, "Name an alias after as")
	has(quick.parse_repo("/a /b").problem :: string, "Nothing fits")
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

test("dialog's base field takes any ref, and filters the list as you type", function()
	local dialog = stub.registered.blocks.new
	local cx = stub.block_cx()
	local s = dialog.init(cx, { tern.json.encode({
		token = "t",
		repo = "studio",
		main = "/src/studio",
		root = "../{repo}.worktrees/{slug}",
		prefix = "",
		session_name = "{repo}:{branch}",
		bases = { "origin/dev", "origin/main", "HEAD" },
		refs = { "origin/dev", "origin/main", "HEAD", "release/24.2", "feat/other" },
	}) }, nil)
	-- The field starts empty so the first keystroke filters; blank submits
	-- the best base, which the placeholder and the preview name.
	eq(s.base.text, "")
	eq(s.focus, "branch")
	dialog.view(s, cx)

	-- Tab moves to the base field; typing filters to what matches.
	dialog.key(s, stub.key("tab"), cx)
	eq(s.focus, "base")
	dialog.key(s, stub.key("paste", "rele"), cx)
	dialog.view(s, cx)
	dialog.key(s, stub.key("down"), cx)
	eq(s.base.text, "release/24.2", "↑↓ writes the highlighted ref into the field")

	-- A ref the suggestions never listed still goes through verbatim.
	for _ = 1, #"release/24.2" do
		dialog.key(s, stub.key("backspace"), cx)
	end
	dialog.key(s, stub.key("paste", "dev"), cx)
	dialog.view(s, cx)
	dialog.key(s, stub.key("tab"), cx)
	eq(s.focus, "branch", "Tab goes back to the branch field")
	dialog.key(s, stub.key("paste", "feat/x"), cx)
	dialog.key(s, stub.key("enter"), cx)
	local action, params = url.parse(cx.opened[1])
	eq(action, "create")
	eq(params.branch, "feat/x")
	eq(params.base, "dev", "the window resolves a bare name against origin")
end)

test("dialog with an untouched base submits the best one", function()
	local dialog = stub.registered.blocks.new
	local cx = stub.block_cx()
	local s = dialog.init(cx, { tern.json.encode({
		token = "t",
		repo = "studio",
		main = "/src/studio",
		root = "../{slug}",
		prefix = "",
		bases = { "origin/dev", "origin/main", "HEAD" },
	}) }, nil)
	dialog.view(s, cx)
	dialog.key(s, stub.key("paste", "feat/x"), cx)
	dialog.key(s, stub.key("enter"), cx)
	eq(select(2, url.parse(cx.opened[1])).base, "origin/dev")
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

test("line block hands the typed line back under its own action", function()
	local line = stub.registered.blocks.line
	local cx = stub.block_cx()
	local s = line.init(cx, { tern.json.encode({
		token = "ln",
		action = "quick",
		title = "Quick worktree",
		grammar = "quick",
		aliases = { "studio" },
		hints = { { text = "[repo] [branch] [off <base>]" } },
	}) }, nil)
	line.view(s, cx)
	line.key(s, stub.key("paste", "studio off dev"), cx)
	line.view(s, cx) -- the preview parses while you type
	line.key(s, stub.key("enter"), cx)
	local action, params = url.parse(cx.opened[1])
	eq(action, "quick")
	eq(params.token, "ln")
	eq(params.line, "studio off dev")

	-- Escape cancels, and a bad grammar line previews its problem.
	local cx2 = stub.block_cx()
	local s2 = line.init(cx2, { tern.json.encode({ token = "ln2", action = "addrepo", title = "Add repo", grammar = "repo" }) }, nil)
	line.key(s2, stub.key("paste", "/a /b"), cx2)
	line.view(s2, cx2)
	line.key(s2, stub.key("escape"), cx2)
	eq((url.parse(cx2.opened[1])), "cancel")
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

test("window half registers its commands, a link route and a status segment", function()
	tern.context = "window"
	require("../window")
	local ids = {}
	for _, c in stub.registered.commands do
		table.insert(ids, c.id)
	end
	table.sort(ids)
	eq(table.concat(ids, ","), "addrepo,adopt,new,open,prune,quick,remove,rmrepo,setbase,setup")
	eq(#stub.registered.links, 1)
	eq(stub.registered.links[1]({ url = "https://example.com", mods = {} }, {}), nil)
end)

test("new tabs and splits in a worktree session start in the worktree", function()
	local anchor = require("../lib/anchor")
	state.put({ path = "/w/feat-z", main = "/m", repo = "m", branch = "feat/z", session_name = "m:feat/z" })
	-- `window_start` re-reads the index the overrides read.
	stub.registered.events.window_start[1]({ session = { focused = function() return nil end } })

	-- A pane that wandered off to ~ in a worktree session still anchors,
	-- because the session binding decides, not the focused pane's cwd.
	local cx = stub.window_cx("/Users/me")
	cx.sessions.current = function(_self)
		return { id = 1, name = "m:feat/z", host = 0, current = true, locked = false, tabs = 1 }
	end
	eq(stub.registered.overrides.new_tab(cx), true)
	eq(cx.launched[1].launch.cwd, "/w/feat-z")
	eq(stub.registered.overrides.split_right(cx), true)
	eq(cx.launched[2].kind, "split")
	eq(cx.launched[2].dir, "right")
	eq(cx.launched[2].launch.cwd, "/w/feat-z")
	eq(stub.registered.overrides.split_down(cx) , true)
	eq(cx.launched[3].dir, "down")

	-- An ordinary session is left entirely alone.
	local plain = stub.window_cx("/Users/me")
	eq(stub.registered.overrides.new_tab(plain), nil, "Tern's own behavior runs")
	eq(#plain.launched, 0)

	-- Falling back to the focused pane when the session name doesn't match.
	local by_cwd = stub.window_cx("/w/feat-z/app")
	eq(stub.registered.overrides.new_tab(by_cwd), true)
	eq(by_cwd.launched[1].launch.cwd, "/w/feat-z")
	state.drop("/w/feat-z")
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

test("window half exports Carly create, list, repos and add_repo with valid specs", function()
	local names = {}
	for name in stub.registered.exports do
		table.insert(names, name)
	end
	table.sort(names)
	eq(table.concat(names, ","), "add_repo,create,list,repos")
	eq(#names <= 16, true, "at most 16 exports")
	for _, name in names do
		local e = stub.registered.exports[name]
		eq(string.match(name, "^[a-z][a-z0-9_]?[a-z0-9_]*$") ~= nil and #name <= 24, true, name)
		eq(#e.spec.sig > 0 and #e.spec.sig <= 1024, true, name .. " sig")
		eq(#e.spec.doc > 0 and #e.spec.doc <= 1024, true, name .. " doc")
	end
end)

test("create with no branch autonames, adds the worktree and reports", function()
	local create = require("../lib/flows/create")
	local config = require("../lib/config")
	stub.kv.autoname_cursor = nil
	stub.kv.repos = nil
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
	argv = stub.answer(cx, 0) -- the base lives on origin, so freshen just it
	eq(table.concat(argv, " "), "git -C /src/studio fetch --quiet origin main")
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
	-- Creating inside a repository registers it, so it works from anywhere.
	eq((known.get("studio") :: any).path, "/src/studio")

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
	stub.answer(cx, 0, "main\n") -- for-each-ref
	stub.answer(cx, 128) -- check-ref-format
	eq(result.ok, false)
	has(result.message, "Not a valid branch name")
end)

-- base resolution ----------------------------------------------------------

test("a typed base falls back to its origin ref, and defaults are ordered", function()
	local create = require("../lib/flows/create")
	local config = require("../lib/config")
	local refs = { main = true, ["origin/main"] = true, ["origin/dev"] = true }
	eq(create.resolve_base("main", refs), "main")
	eq(create.resolve_base("dev", refs), "origin/dev", "only the remote has it")
	eq(create.resolve_base("origin/dev", refs), "origin/dev")
	eq(create.resolve_base("nope", refs), "nope", "git reports the rest")
	eq(create.resolve_base("", refs), "")

	local cfg = config.normalize({ base = { "origin/main", "main" } })
	eq(create.pick_base("dev", refs, cfg, nil), "origin/dev")
	eq(create.pick_base("", refs, cfg, nil), "origin/main", "first configured base that exists")
	eq(create.pick_base("", refs, cfg, { prefer = "dev" }), "origin/dev", "the repo's default base comes first")
	eq(create.pick_base("", { x = true }, cfg, nil), "HEAD")
	eq(create.pick_base("", refs, cfg, { prefer = "gone" }), "origin/main", "a default base that no longer exists is skipped")
	eq(
		table.concat(create.bases(cfg, refs, { current = "feat/x", prefer = "dev" }), ","),
		"origin/dev,origin/main,main,feat/x,HEAD"
	)
	eq(table.concat(create.bases(cfg, refs, { prefer = "gone" }), ","), "origin/main,main,HEAD")

	eq(create.fetch_spec("origin/dev"), "dev")
	eq(create.fetch_spec("origin/feat/x"), "feat/x")
	eq(create.fetch_spec("main"), nil, "local refs aren't fetched")
	eq(create.fetch_spec("upstream/dev"), nil, "only origin")
	eq(create.fetch_spec("origin/HEAD"), nil)
end)

test("the repository's own trunk beats a guess at main, but not an explicit base", function()
	local create = require("../lib/flows/create")
	local config = require("../lib/config")

	-- `origin/HEAD -> origin/dev` is how a repo states its trunk. Its short
	-- name is `origin`, not `origin/HEAD`, so it is read by full refname.
	local refs, head, remote = create.parse_refs(table.concat({
		"refs/heads/main\tmain\t",
		"refs/heads/feat/x\tfeat/x\t",
		"refs/remotes/origin/main\torigin/main\t",
		"refs/remotes/origin/dev\torigin/dev\t",
		"refs/remotes/origin/HEAD\torigin\torigin/dev",
	}, "\n"))
	eq(head, "origin/dev")
	eq(refs["origin/dev"], true)
	eq(refs["origin"], nil, "the trunk pointer is an alias, not a base")
	eq(remote["origin/dev"], true)
	eq(remote["feat/x"], nil, "a local branch can hold a slash too")
	eq(refs["feat/x"], true)

	-- A bare listing still yields its refs rather than nothing.
	local plain, plain_head = create.parse_refs("main\norigin/main\n")
	eq(plain.main, true)
	eq(plain["origin/main"], true)
	eq(plain_head, nil)

	-- No `.tern/worktrees.json`: the default base list is only a guess, so
	-- the trunk leads. This is the "my main branch is dev" case.
	local guessed = config.normalize(nil)
	eq(guessed.base_configured, false)
	eq(create.pick_base("", refs, guessed, { remote_head = head }), "origin/dev")
	eq(
		table.concat(create.bases(guessed, refs, { current = "feat/x", remote_head = head }), ","),
		"origin/dev,origin/main,main,feat/x,HEAD"
	)

	-- An explicit list is a decision, so it outranks the trunk.
	local chosen = config.normalize({ base = { "origin/main" } })
	eq(chosen.base_configured, true)
	eq(create.pick_base("", refs, chosen, { remote_head = head }), "origin/main")
	eq(table.concat(create.bases(chosen, refs, { remote_head = head }), ","), "origin/main,origin/dev,HEAD")

	-- A registered default base still beats both.
	eq(create.pick_base("", refs, chosen, { prefer = "dev", remote_head = head }), "origin/dev")
end)

test("base suggestions put the ranked choices first, then remotes, then local", function()
	local create = require("../lib/flows/create")
	local refs = { ["origin/dev"] = true, ["origin/zoo"] = true, main = true, zebra = true, apple = true }
	local remote = { ["origin/dev"] = true, ["origin/zoo"] = true }
	-- Remotes before local branches: one alphabetical list buries origin/*
	-- behind hundreds of local branches (studio has 660 of them).
	eq(table.concat(create.suggestions({ "origin/dev", "HEAD" }, refs, remote), ","), "origin/dev,HEAD,origin/zoo,apple,main,zebra")
	eq(#create.suggestions({ "origin/dev" }, refs, remote, 3), 3, "the rest is capped")
	eq(
		table.concat(create.suggestions({ "HEAD" }, refs, nil), ","),
		"HEAD,apple,main,origin/dev,origin/zoo,zebra",
		"no remote set: one list"
	)
end)

-- the known-repos store ----------------------------------------------------

test("the known-repos store round-trips through kv and repos.json", function()
	stub.kv.repos = nil
	stub.files["/data/repos.json"] = nil
	eq(#known.mru(), 0)

	local entry = known.add({ path = "/src/studio-gsm", alias = "studio", base = "dev", now = 100 })
	eq(entry.alias, "studio")
	eq(stub.kv.repos.studio.path, "/src/studio-gsm", "written to kv under \"repos\"")
	known.add({ path = "/src/tern", now = 101 })
	eq(table.concat({ known.mru()[1].alias, known.mru()[2].alias }, ","), "tern,studio")

	known.register("/src/studio-gsm")
	eq(known.mru()[1].alias, "studio", "register touches a known repo")
	eq((known.by_path("/src/studio-gsm") :: any).base, "dev")

	known.set_base("tern", "origin/main")
	eq((known.get("TERN") :: any).base, "origin/main")
	known.remove("tern")
	eq(known.get("tern"), nil)

	-- repos.json declares one, and is authoritative for it.
	stub.files["/data/repos.json"] = tern.json.encode({
		repos = { carly = { path = "~/dev/carly", base = "dev" } },
	})
	eq((known.get("carly") :: any).path, "/Users/me/dev/carly")
	eq((known.get("carly") :: any).declared, true)
	raises(function()
		known.remove("carly")
	end, "declared in repos.json")

	-- A malformed file warns and is ignored rather than breaking the palette.
	stub.files["/data/repos.json"] = "{ not json"
	eq(known.get("carly"), nil)
	eq((known.get("studio") :: any).alias, "studio")
	stub.files["/data/repos.json"] = nil
	stub.kv.repos = nil
end)

-- create from outside any repository ---------------------------------------

test("quick entry creates in a named repo from a directory that isn't one", function()
	local create = require("../lib/flows/create")
	stub.processes = {}
	stub.kv.repos = { studio = { alias = "studio", path = "/src/studio", base = "dev", used_at = 1 } }
	-- A shell in no repository at all: the alias on the line decides.
	local cx = stub.window_cx("/tmp/nowhere")
	create.from_line(cx, { reload = function() end }, "  studio feat/foo off dev  ")

	-- app.target → the registry entry's path → git.repo
	local argv = stub.answer(cx, 0, "/src/studio\n/src/studio/.git\n")
	eq(argv[4], "rev-parse")
	eq(argv[3], "/src/studio", "resolved from the registry, not the cwd")
	argv = stub.answer(cx, 0, "worktree /src/studio\nHEAD abc123\nbranch refs/heads/main\n")
	eq(argv[5], "list")
	-- create.run: refs, then `dev` resolves to origin/dev
	argv = stub.answer(cx, 0, "main\norigin/main\norigin/dev\n")
	eq(argv[4], "for-each-ref")
	argv = stub.answer(cx, 0) -- check-ref-format
	eq(argv[#argv], "feat/foo")
	stub.answer(cx, 1) -- rev-parse: the branch is new
	argv = stub.answer(cx, 0) -- fetch just the base
	eq(table.concat(argv, " "), "git -C /src/studio fetch --quiet origin dev")
	argv = stub.answer(cx, 0) -- worktree add
	eq(table.concat(argv, " "), "git -C /src/studio worktree add --no-track -b feat/foo /src/studio.worktrees/feat-foo origin/dev")
	eq(cx.created[1].name, "studio:feat/foo")
	eq(cx.created[1].cwd, "/src/studio.worktrees/feat-foo")
	eq((state.get("/src/studio.worktrees/feat-foo") :: any).base, "origin/dev")
	eq(known.mru()[1].used_at > 1, true, "the repo moves to the front of the picker")
	state.drop("/src/studio.worktrees/feat-foo")
	stub.processes = {}
end)

test("a base that can't be fetched still creates, and says so", function()
	local create = require("../lib/flows/create")
	local config = require("../lib/config")
	stub.processes = {}
	stub.kv.repos = nil
	local repo = {
		top = "/src/r",
		common_dir = "/src/r/.git",
		main = "/src/r",
		name = "r",
		branch = "main",
		worktrees = { { path = "/src/r", branch = "main", main = true, bare = false, detached = false, locked = false, prunable = false } },
	}
	local cx = stub.window_cx("/src/r")
	local result: any = nil
	create.run(cx, repo, config.normalize(nil), { reload = function() end }, "feat/x", "origin/main", function(ok, message)
		result = { ok = ok, message = message }
	end)
	stub.answer(cx, 0, "main\norigin/main\n") -- for-each-ref
	stub.answer(cx, 0) -- check-ref-format
	stub.answer(cx, 1) -- rev-parse: the branch is new
	stub.answer(cx, 128, "") -- fetch fails: offline
	local argv = stub.answer(cx, 0) -- worktree add runs anyway
	eq(argv[#argv], "origin/main")
	eq(result.ok, true)
	has(result.message, "used the local ref")
	state.drop("/src/r.worktrees/feat-x")
	stub.processes = {}
	stub.kv.repos = nil
end)

test("quick entry reports a line it can't parse instead of guessing", function()
	local create = require("../lib/flows/create")
	stub.processes = {}
	local cx = stub.window_cx("/tmp/nowhere")
	create.from_line(cx, { reload = function() end }, "a b c")
	eq(#stub.processes, 0, "nothing ran")
	has(cx.toasts[#cx.toasts].sub, "Nothing fits")
end)

-- the registry commands, dialog and all ------------------------------------

-- Answers the `line` or `pick` block the window just opened, the way the
-- host half's block would: through a `tern-worktrees://` link.
local function answer_block(cx: any, action: string, params: { [string]: string })
	local app = require("../lib/app")
	local ctx = stub.last_block(cx)
	local sent: { [string]: string } = { token = ctx.token }
	for k, v in params do
		sent[k] = v
	end
	app.link({ url = url.build(action, sent), mods = {} }, cx)
end

test("Add repo, Set default base and Remove repo drive the registry", function()
	local app = require("../lib/app")
	local shared = { reload = function() end }
	stub.processes = {}
	stub.kv.repos = nil
	local cx = stub.window_cx("/src/studio")

	-- "Add repo…" prefills the focused pane's repository.
	app.run("addrepo", cx, shared)
	stub.answer(cx, 0, "/src/studio\n/src/studio/.git\n") -- rev-parse
	stub.answer(cx, 0, "worktree /src/studio\nHEAD abc\nbranch refs/heads/main\n")
	local ctx, kind = stub.last_block(cx)
	eq(kind, "worktrees.line")
	eq(ctx.value, "/src/studio")
	eq(ctx.grammar, "repo")

	answer_block(cx, "addrepo", { line = "/src/studio as studio off dev" })
	stub.answer(cx, 0, "/src/studio\n/src/studio/.git\n")
	stub.answer(cx, 0, "worktree /src/studio\nHEAD abc\nbranch refs/heads/main\n")
	eq((known.get("studio") :: any).base, "dev")
	eq(cx.toasts[#cx.toasts].text, "Added studio")

	-- "Set default base…" skips the picker when only one repo is known.
	app.run("setbase", cx, shared)
	eq(select(2, stub.last_block(cx)), "worktrees.line")
	eq((stub.last_block(cx) :: any).value, "dev")
	answer_block(cx, "setbase", { line = " origin/main " })
	eq((known.get("studio") :: any).base, "origin/main")
	-- Each dialog's token is one-shot, so a second answer needs a second ask.
	app.run("setbase", cx, shared)
	answer_block(cx, "setbase", { line = "" })
	eq((known.get("studio") :: any).base, nil, "a blank line clears it")

	-- "Remove repo…" drops the entry; the worktrees stay.
	known.add({ path = "/src/tern", now = 5 })
	app.run("rmrepo", cx, shared)
	eq(select(2, stub.last_block(cx)), "worktrees.pick")
	eq(#(stub.last_block(cx) :: any).items, 2)
	answer_block(cx, "pick", { choice = "1" })
	eq(#known.mru(), 1)
	eq(known.mru()[1].alias, "tern", "the newer entry was listed first and removed")

	-- A path that isn't a repository is refused, and nothing is stored.
	app.run("addrepo", cx, shared)
	stub.answer(cx, 128, "") -- rev-parse for the prefill
	answer_block(cx, "addrepo", { line = "/tmp/nope" })
	stub.answer(cx, 128, "fatal: not a git repository")
	eq(cx.toasts[#cx.toasts].text, "Not a git repository")
	eq(known.get("nope"), nil)
	eq(#stub.processes, 0, "every git call was answered")
	stub.kv.repos = nil
end)

test("New worktree from outside a repo picks a repository, then opens the dialog", function()
	local app = require("../lib/app")
	local shared = { reload = function() end }
	stub.processes = {}
	stub.kv.repos = {
		studio = { alias = "studio", path = "/src/studio", base = "dev", used_at = 2 },
		tern = { alias = "tern", path = "/src/tern", used_at = 9 },
	}
	local cx = stub.window_cx("/tmp/nowhere")
	app.run("new", cx, shared)
	stub.answer(cx, 128, "fatal: not a git repository") -- the cwd isn't one

	local pick, kind = stub.last_block(cx)
	eq(kind, "worktrees.pick")
	eq(table.concat({ pick.items[1].label, pick.items[2].label }, ","), "tern,studio", "most recent first")

	answer_block(cx, "pick", { choice = "2" }) -- studio
	stub.answer(cx, 0, "/src/studio\n/src/studio/.git\n")
	stub.answer(cx, 0, "worktree /src/studio\nHEAD abc\nbranch refs/heads/main\n")
	stub.answer(cx, 0, "main\norigin/main\norigin/dev\n") -- for-each-ref
	local dialog = stub.last_block(cx)
	eq(select(2, stub.last_block(cx)), "worktrees.new")
	eq(dialog.repo, "studio")
	eq(dialog.bases[1], "origin/dev", "the registered default base leads")
	eq(#stub.processes, 0)
	stub.kv.repos = nil
end)

test("a repo whose trunk is dev offers dev first, with no configuration at all", function()
	local app = require("../lib/app")
	stub.processes = {}
	stub.kv.repos = nil
	stub.files["/src/studio/.tern/worktrees.json"] = nil
	local cx = stub.window_cx("/src/studio")
	app.run("new", cx, { reload = function() end })
	stub.answer(cx, 0, "/src/studio\n/src/studio/.git\n")
	stub.answer(cx, 0, "worktree /src/studio\nHEAD abc\nbranch refs/heads/feat/brief\n")
	stub.answer(cx, 0, table.concat({
		"refs/heads/feat/brief\tfeat/brief\t",
		"refs/heads/main\tmain\t",
		"refs/remotes/origin/main\torigin/main\t",
		"refs/remotes/origin/dev\torigin/dev\t",
		"refs/remotes/origin/HEAD\torigin\torigin/dev",
		"refs/remotes/origin/release\torigin/release\t",
	}, "\n"))
	local dialog = stub.last_block(cx)
	eq(table.concat(dialog.bases, ","), "origin/dev,origin/main,main,feat/brief,HEAD")
	eq(dialog.refs[1], "origin/dev", "suggestions lead with the ranked choices")
	eq(table.find(dialog.refs, "origin/release") ~= nil, true, "every other ref is suggested too")
	eq(table.find(dialog.refs, "origin"), nil, "the trunk pointer isn't offered as a base")
	eq(#stub.processes, 0)
end)

-- Palette → dialog → link → git, with the real block driving the link.
test("the whole New worktree path creates a worktree and its session", function()
	local app = require("../lib/app")
	local dialog = stub.registered.blocks.new
	stub.processes = {}
	stub.kv.repos = nil
	stub.kv.autoname_cursor = nil
	local cx = stub.window_cx("/src/studio")
	app.run("new", cx, { reload = function() end })
	stub.answer(cx, 0, "/src/studio\n/src/studio/.git\n")
	stub.answer(cx, 0, "worktree /src/studio\nHEAD abc\nbranch refs/heads/feat/brief\n")
	stub.answer(cx, 0, table.concat({
		"refs/heads/feat/brief\tfeat/brief\t",
		"refs/remotes/origin/dev\torigin/dev\t",
		"refs/remotes/origin/main\torigin/main\t",
		"refs/remotes/origin/HEAD\torigin\torigin/dev",
	}, "\n"))

	-- The host half's block, on the argument the window actually sent.
	local block_cx = stub.block_cx()
	local s = dialog.init(block_cx, { (cx.blocks[#cx.blocks].args)[1] }, nil)
	dialog.view(s, block_cx)
	dialog.key(s, stub.key("paste", "feat/login"), block_cx)
	dialog.key(s, stub.key("enter"), block_cx)
	eq(#block_cx.opened, 1, "Enter opened a link")

	-- …and the link it opened, back through the window's route.
	app.link({ url = block_cx.opened[1], mods = {} }, cx)
	local argv = stub.answer(cx, 0, "feat/brief\norigin/dev\norigin/main\n") -- for-each-ref
	eq(argv[4], "for-each-ref")
	argv = stub.answer(cx, 0) -- check-ref-format
	eq(argv[#argv], "feat/login")
	stub.answer(cx, 1) -- rev-parse: the branch is new
	argv = stub.answer(cx, 0) -- fetch the base
	eq(table.concat(argv, " "), "git -C /src/studio fetch --quiet origin dev")
	argv = stub.answer(cx, 0) -- worktree add
	eq(table.concat(argv, " "), "git -C /src/studio worktree add --no-track -b feat/login /src/studio.worktrees/feat-login origin/dev")
	eq(cx.created[1].name, "studio:feat/login", "the session opened")
	eq(cx.created[1].cwd, "/src/studio.worktrees/feat-login")
	eq(#stub.processes, 0)
	state.drop("/src/studio.worktrees/feat-login")
	stub.kv.repos = nil
end)

test("a link whose dialog outlived its window says so instead of doing nothing", function()
	local app = require("../lib/app")
	stub.processes = {}
	local cx = stub.window_cx("/src/studio")
	-- A token this window never issued: an expired dialog, or one from the
	-- window VM a plugin reload replaced.
	app.link({ url = url.build("create", { token = "stale", branch = "x", base = "HEAD" }), mods = {} }, cx)
	eq(#stub.processes, 0, "nothing ran")
	eq(cx.toasts[#cx.toasts].text, "That dialog has expired")
end)

test("with nothing known and nowhere to look, New worktree says what to do", function()
	local app = require("../lib/app")
	stub.processes = {}
	stub.kv.repos = nil
	local cx = stub.window_cx("/tmp/nowhere")
	app.run("new", cx, { reload = function() end })
	stub.answer(cx, 128, "") -- rev-parse: not a git repository
	eq(#stub.processes, 0)
	eq(cx.toasts[#cx.toasts].text, "No known repositories")
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
	error("tests failed", 0)
end
