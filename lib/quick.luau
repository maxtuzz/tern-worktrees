--!strict
-- The two one-line grammars the `worktrees.line` dialog collects. Pure (no
-- `tern` calls), so both the block (for its live preview) and the window
-- (which decides) parse with the same rules.
--
--   quick entry:  [repo] [branch] [off <base>]
--   add repo:     <path> [as <alias>] [off <base>]
--
-- Forgiving on purpose: extra spaces are ignored, the keywords are
-- case-insensitive, and `off` has the sugar spellings `from`, `@base`,
-- `--base base` and `--base=base`.

local util = require("./util")

local quick = {}

export type Entry = {
	repo: string?,
	branch: string?,
	base: string?,
	problem: string?,
}

export type RepoEntry = {
	path: string?,
	alias: string?,
	base: string?,
	problem: string?,
}

local BASE_WORDS: { [string]: boolean } = { off = true, from = true, ["--base"] = true, ["-b"] = true }
local ALIAS_WORDS: { [string]: boolean } = { as = true, ["--alias"] = true }

local function words(line: string?): { string }
	local out: { string } = {}
	for word in string.gmatch(line or "", "%S+") do
		table.insert(out, word)
	end
	return out
end

-- The base `token` introduces, as (value, consumed_next). `value` is nil when
-- the token isn't a base at all, and "" when it is but names nothing.
local function base_of(token: string, next_token: string?): (string?, boolean)
	local lower = string.lower(token)
	if BASE_WORDS[lower] then
		return next_token or "", next_token ~= nil
	end
	local inline = string.match(token, "^%-%-base=(.*)$")
	if inline ~= nil then
		return inline, false
	end
	if string.sub(token, 1, 1) == "@" then
		return string.sub(token, 2), false
	end
	return nil, false
end

-- `[repo] [branch] [off <base>]`. The first bare word is the repository only
-- when `is_alias` knows it; everything else bare is the branch. A blank line
-- parses to all-nil: the caller's "here, with an autoname".
function quick.parse(line: string?, is_alias: ((token: string) -> boolean)?): Entry
	local tokens = words(line)
	local out: Entry = {}
	local bare = 0
	local i = 1
	while i <= #tokens do
		local token = tokens[i]
		local base, consumed = base_of(token, tokens[i + 1])
		if base ~= nil then
			if base == "" then
				out.problem = "Name a base after " .. token
				return out
			end
			if out.base ~= nil then
				out.problem = string.format("Two bases: %s and %s", out.base, base)
				return out
			end
			out.base = base
			if consumed then
				i += 1
			end
		else
			bare += 1
			if bare == 1 and is_alias ~= nil and is_alias(token) then
				out.repo = token
			elseif out.branch == nil then
				out.branch = token
			else
				out.problem = string.format("Nothing fits %q — the line is [repo] [branch] [off <base>]", token)
				return out
			end
		end
		i += 1
	end
	return out
end

-- `<path> [as <alias>] [off <base>]`.
function quick.parse_repo(line: string?): RepoEntry
	local tokens = words(line)
	local out: RepoEntry = {}
	local i = 1
	while i <= #tokens do
		local token = tokens[i]
		local lower = string.lower(token)
		local base, consumed = base_of(token, tokens[i + 1])
		if ALIAS_WORDS[lower] then
			local alias = tokens[i + 1]
			if alias == nil then
				out.problem = "Name an alias after " .. token
				return out
			end
			out.alias = alias
			i += 1
		elseif base ~= nil then
			if base == "" then
				out.problem = "Name a base after " .. token
				return out
			end
			out.base = base
			if consumed then
				i += 1
			end
		elseif out.path == nil then
			out.path = token
		else
			out.problem = string.format("Nothing fits %q — the line is <path> [as <alias>] [off <base>]", token)
			return out
		end
		i += 1
	end
	if out.path ~= nil then
		out.path = util.trim(out.path)
	end
	return out
end

return quick
