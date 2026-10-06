--!strict
-- Pure string and path helpers shared by both halves. No `tern` calls, so
-- the test runner can load this module with plain `luau`.

local util = {}

-- `s` without leading and trailing whitespace.
function util.trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or "")
end

-- `path` without trailing slashes ("/" stays "/").
function util.strip_slash(path: string): string
	local out = string.gsub(path, "(.)/+$", "%1")
	return out
end

-- Last path component.
function util.basename(path: string): string
	local p = util.strip_slash(path)
	return string.match(p, "([^/]+)$") or p
end

-- Everything before the last component ("/" for top-level paths).
function util.dirname(path: string): string
	local p = util.strip_slash(path)
	local up = string.match(p, "^(.*)/[^/]*$")
	if up == nil or up == "" then
		return "/"
	end
	return up
end

-- An absolute path with `.` and `..` components resolved lexically.
function util.normalize(path: string): string
	local parts: { string } = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			if #parts > 0 then
				table.remove(parts)
			end
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

-- `path` resolved against directory `base` (absolute paths win; `~` uses `home`).
function util.resolve(base: string, path: string, home: string?): string
	if (path == "~" or string.sub(path, 1, 2) == "~/") and home then
		return util.normalize(home .. string.sub(path, 2))
	end
	if string.sub(path, 1, 1) == "/" then
		return util.normalize(path)
	end
	return util.normalize(base .. "/" .. path)
end

-- Whether `path` is `root` or lies under it.
function util.inside(path: string?, root: string): boolean
	if path == nil or path == "" then
		return false
	end
	local p = util.strip_slash(path)
	local r = util.strip_slash(root)
	return p == r or r == "/" or string.sub(p, 1, #r + 1) == r .. "/"
end

-- `path` with the home directory shown as `~`.
function util.tilde(path: string, home: string?): string
	if home and home ~= "" and util.inside(path, home) then
		return "~" .. string.sub(path, #util.strip_slash(home) + 1)
	end
	return path
end

-- A directory-safe name for `branch`: slashes and anything unusual become `-`.
function util.slug(branch: string): string
	local s = string.gsub(branch, "[^%w%._%-]+", "-")
	s = string.gsub(s, "%-%-+", "-")
	s = string.gsub(s, "^[%-%.]+", "")
	s = string.gsub(s, "%-+$", "")
	return if s == "" then "worktree" else s
end

-- `template` with `{name}` placeholders filled from `vars`; unknown names stay.
function util.render(template: string, vars: { [string]: string }): string
	local out = string.gsub(template, "{([%w_]+)}", function(name: string): string?
		return vars[name]
	end)
	return out
end

-- `s` quoted for POSIX shells.
function util.shell_quote(s: string): string
	if s ~= "" and string.match(s, "^[%w%._/%-=:@,+]+$") then
		return s
	end
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- Lines of `text`, without trailing carriage returns.
function util.lines(text: string): { string }
	local out: { string } = {}
	for line in string.gmatch(text, "[^\n]+") do
		local clean = string.gsub(line, "\r$", "")
		table.insert(out, clean)
	end
	return out
end

-- A local branch name check that mirrors the common `git check-ref-format`
-- rules, so the dialog can complain before anything runs. Git still checks.
function util.branch_problem(name: string): string?
	if name == "" then
		return "Type a branch name"
	end
	if string.find(name, "[%s~%^:%?%*%[\\%c]") then
		return "Branch names can't contain spaces or ~ ^ : ? * [ \\"
	end
	if string.find(name, "%.%.", 1) or string.find(name, "@{", 1, true) then
		return "Branch names can't contain .. or @{"
	end
	if string.sub(name, 1, 1) == "-" or string.sub(name, 1, 1) == "/" or string.sub(name, -1) == "/" then
		return "Branch names can't start with - or start/end with /"
	end
	if string.sub(name, -1) == "." or string.sub(name, -5) == ".lock" then
		return "Branch names can't end with . or .lock"
	end
	return nil
end

return util
