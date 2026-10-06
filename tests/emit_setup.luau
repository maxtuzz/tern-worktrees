-- Prints a compiled post_create script for tests/setup_e2e.sh;
-- tests/setup_e2e.sh substitutes @WT_PATH@ and @WT_MAIN@.
local stub = require("./stub")
local config = require("../lib/config")
local setup = require("../lib/setup")

local _ = stub
local path, main = "@WT_PATH@", "@WT_MAIN@"
local cfg = config.normalize({
	phases = {
		post_create = {
			{ ["require"] = { "bash", "git>=1.0" } },
			{ copy = { ".env", "apps/*/.env" }, from = "main", if_missing = true },
			{ symlink = "shared" },
			{ sync_dir = ".hamster/", optional = true },
			{ sync_dir = "missing-dir", optional = true },
			{ run = "echo \"$WT_BRANCH:$CI\" > ran.txt", env = { CI = "true" } },
		},
	},
})
print(setup.compile("post_create", cfg.phases.post_create, { path = path, main = main, branch = "feat/x", base = "main" }))
