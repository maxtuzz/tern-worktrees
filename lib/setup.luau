--!strict
-- The setup engine: compiles a phase's declarative steps into one bash
-- script. The window half writes it to the plugin's data directory and types
-- `bash <script>` into the worktree's pane, so setup is visible, Ctrl-C-able
-- and costs the plugin no budget. `compile` is pure (tested with plain luau).
--
-- Scripts target macOS's bash 3.2: no `**` globs, no associative arrays.

local util = require("./util")

local setup = {}

export type Vars = {
	path: string, -- WT_PATH
	main: string, -- WT_MAIN, ROOT_WORKTREE_PATH
	branch: string, -- WT_BRANCH
	base: string, -- WT_BASE
}

local q = util.shell_quote

local PRELUDE = [[
__wt_step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
__wt_ok() { printf '\033[32m✓ %s\033[0m\n' "$1"; }
__wt_warn() { printf '\033[33m! %s\033[0m\n' "$1"; }
__wt_fail() { printf '\033[31m✗ %s\033[0m\n' "$1"; printf '\033[31mSetup stopped.\033[0m Fix it, then run "Re-run setup" from the palette.\n'; exit 1; }
__wt_confirm() { local a; printf '%s [y/N] ' "$1"; read -r a; case "$a" in [Yy]*) return 0 ;; *) return 1 ;; esac; }
# $1 >= $2, comparing dotted numeric versions.
__wt_version_ge() {
	local IFS=. i a b
	local -a have want
	have=($1); want=($2)
	for ((i = 0; i < ${#want[@]}; i++)); do
		a=${have[i]:-0}; b=${want[i]:-0}; a=${a//[^0-9]/}; b=${b//[^0-9]/}
		if ((10#${a:-0} > 10#${b:-0})); then return 0; fi
		if ((10#${a:-0} < 10#${b:-0})); then return 1; fi
	done
	return 0
}
# __wt_require tool [min_version]
__wt_require() {
	command -v "$1" >/dev/null 2>&1 || { echo "  missing: $1"; return 1; }
	[ -z "${2:-}" ] && { echo "  found: $1"; return 0; }
	local v
	v=$("$1" --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)*' | head -n 1)
	if [ -z "$v" ] || ! __wt_version_ge "$v" "$2"; then echo "  $1 ${v:-?} is older than $2"; return 1; fi
	echo "  found: $1 $v"
}
# __wt_place copy|symlink if_missing(0|1) glob…   (globs relative to $WT_MAIN)
__wt_place() {
	local mode=$1 if_missing=$2 pat f src dst n=0 IFS=$'\n'
	shift 2
	local -a found
	found=()
	shopt -s nullglob dotglob
	cd "$WT_MAIN" || return 1
	for pat in "$@"; do
		for f in $pat; do found+=("$f"); done
	done
	cd "$WT_PATH" || return 1
	shopt -u nullglob dotglob
	for f in ${found[@]+"${found[@]}"}; do
		src="$WT_MAIN/$f"; dst="$WT_PATH/$f"
		if [ "$if_missing" = 1 ] && { [ -e "$dst" ] || [ -L "$dst" ]; }; then echo "  = $f (exists)"; continue; fi
		mkdir -p "$(dirname "$dst")" || return 1
		if [ "$mode" = symlink ]; then
			rm -rf "$dst" && ln -s "$src" "$dst" || return 1
		elif [ -d "$src" ]; then
			mkdir -p "$dst" && cp -R "$src/." "$dst/" || return 1
		else
			cp -p "$src" "$dst" || return 1
		fi
		echo "  + $f"; n=$((n + 1))
	done
	[ "$n" -gt 0 ] || [ ${#found[@]} -gt 0 ] || echo "  (nothing matched)"
}
# __wt_sync dir   (mirror $WT_MAIN/dir into $WT_PATH/dir)
__wt_sync() {
	local d=${1%/}
	[ -d "$WT_MAIN/$d" ] || { echo "  missing: $d"; return 1; }
	mkdir -p "$WT_PATH/$d" || return 1
	if command -v rsync >/dev/null 2>&1; then rsync -a "$WT_MAIN/$d/" "$WT_PATH/$d/"; else cp -R "$WT_MAIN/$d/." "$WT_PATH/$d/"; fi
}
# __wt_wait_url url timeout_s / __wt_wait_port port timeout_s
__wt_wait_url() {
	local end=$((SECONDS + $2))
	until curl -fsS -o /dev/null --max-time 2 "$1" 2>/dev/null; do
		[ "$SECONDS" -ge "$end" ] && return 1
		sleep 1
	done
}
__wt_wait_port() {
	local end=$((SECONDS + $2))
	until nc -z 127.0.0.1 "$1" >/dev/null 2>&1; do
		[ "$SECONDS" -ge "$end" ] && return 1
		sleep 1
	done
}
]]

-- A short label for a step, for the script's headings.
function setup.describe(s: { [string]: any }): string
	local kind = s.kind
	if kind == "run" then
		return s.run
	elseif kind == "copy" or kind == "symlink" then
		return kind .. " " .. table.concat(s.paths, ", ") .. " from main"
	elseif kind == "sync_dir" then
		return "sync " .. table.concat(s.paths, ", ") .. " from main"
	elseif kind == "wait_for" then
		return "wait for " .. (s.url or ("port " .. tostring(s.port)))
	elseif kind == "require" then
		return "require " .. table.concat(s.tools, ", ")
	elseif kind == "confirm" then
		return s.question
	end
	return tostring(kind)
end

-- The shell command (one line or a block) that performs `s`; fails non-zero.
local function body(s: { [string]: any }): string
	local kind = s.kind
	if kind == "run" then
		local parts: { string } = {}
		if s.env then
			local keys: { string } = {}
			for k in s.env do
				table.insert(keys, k)
			end
			table.sort(keys)
			for _, k in keys do
				table.insert(parts, "export " .. k .. "=" .. q(s.env[k]) .. ";")
			end
		end
		if s.cwd then
			table.insert(parts, "cd " .. q(s.cwd) .. " &&")
		end
		table.insert(parts, s.run)
		return "( " .. table.concat(parts, " ") .. "\n)"
	elseif kind == "copy" or kind == "symlink" then
		local args: { string } = {}
		for _, p in s.paths do
			table.insert(args, q(p))
		end
		return string.format("__wt_place %s %d %s", kind, if s.if_missing then 1 else 0, table.concat(args, " "))
	elseif kind == "sync_dir" then
		local cmds: { string } = {}
		for _, p in s.paths do
			table.insert(cmds, "__wt_sync " .. q(p))
		end
		return "{ " .. table.concat(cmds, " && ") .. "; }"
	elseif kind == "wait_for" then
		local timeout = math.max(1, math.floor(s.timeout_s or 120))
		if s.url then
			return string.format("__wt_wait_url %s %d", q(s.url), timeout)
		end
		return string.format("__wt_wait_port %d %d", math.floor(s.port), timeout)
	elseif kind == "require" then
		local cmds: { string } = {}
		for _, spec in s.tools do
			local name, version = string.match(spec, "^(.-)>=(.+)$")
			if name then
				table.insert(cmds, "__wt_require " .. q(name) .. " " .. q(version :: string))
			else
				table.insert(cmds, "__wt_require " .. q(spec))
			end
		end
		-- Check every tool before failing, so one run lists everything missing.
		return "{ __wt_r=0; " .. table.concat(cmds, " || __wt_r=1; ") .. " || __wt_r=1; [ $__wt_r = 0 ]; }"
	end
	error("unknown step kind " .. tostring(kind))
end

-- The bash script that runs `steps` in the worktree `vars.path`, titled `phase`.
function setup.compile(phase: string, steps: { { [string]: any } }, vars: Vars): string
	local out: { string } = {
		"#!/usr/bin/env bash",
		"# Generated by tern-worktrees: " .. phase .. " for " .. vars.branch .. ". Safe to delete.",
		"export WT_PATH=" .. q(vars.path),
		"export WT_MAIN=" .. q(vars.main),
		"export WT_BRANCH=" .. q(vars.branch),
		"export WT_BASE=" .. q(vars.base),
		'export ROOT_WORKTREE_PATH="$WT_MAIN"',
		PRELUDE,
		'cd "$WT_PATH" || exit 1',
		string.format("printf '\\033[1mtern-worktrees\\033[0m %%s · %%s\\n' %s %s", q(phase), q(vars.branch)),
	}
	for i, s in steps do
		local label = string.format("[%d/%d] %s", i, #steps, setup.describe(s))
		table.insert(out, "")
		table.insert(out, "__wt_step " .. q(label))
		if s.kind == "confirm" then
			table.insert(out, string.format("__wt_confirm %s || { __wt_warn 'Stopped at your answer'; exit 0; }", q(s.question)))
			continue
		end
		local on_fail = if s.optional
			then "__wt_warn " .. q("optional step failed: " .. setup.describe(s))
			else "__wt_fail " .. q("failed: " .. setup.describe(s))
		local run = body(s) .. " || " .. on_fail
		if s.kind == "run" and s.confirm then
			table.insert(out, string.format("if __wt_confirm %s; then", q(s.confirm)))
			table.insert(out, run)
			table.insert(out, "else __wt_warn 'skipped'; fi")
		else
			table.insert(out, run)
		end
	end
	table.insert(out, "")
	table.insert(out, "__wt_ok " .. q(phase .. " done"))
	table.insert(out, "")
	return table.concat(out, "\n")
end

-- Writes the script for `steps` into the plugin data directory and returns
-- its path, or nil when there is nothing to run.
function setup.write(phase: string, steps: { { [string]: any } }, vars: Vars): string?
	if #steps == 0 then
		return nil
	end
	local dir = tern.plugin.data .. "/setup"
	tern.fs.mkdir(dir)
	local path = string.format("%s/%s-%s.sh", dir, util.slug(util.basename(vars.main) .. "-" .. vars.branch), phase)
	tern.fs.write(path, setup.compile(phase, steps, vars))
	return path
end

return setup
