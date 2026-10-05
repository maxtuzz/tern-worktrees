--!strict
-- `tern-worktrees://<action>?k=v&…` links: how the host half's blocks hand
-- an answer to the window half (block `cx:open` → window `tern.route.link`).

local url = {}

url.SCHEME = "tern-worktrees"

local function encode(s: string): string
	local out = string.gsub(s, "[^%w%-%._~]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end)
	return out
end

local function decode(s: string): string
	local plus = string.gsub(s, "%+", " ")
	local out = string.gsub(plus, "%%(%x%x)", function(h: string): string
		return string.char(tonumber(h, 16) :: number)
	end)
	return out
end

url.encode = encode
url.decode = decode

-- A link for `action` carrying `params` (keys sorted, so links are stable).
function url.build(action: string, params: { [string]: string }): string
	local keys: { string } = {}
	for k in params do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, k in keys do
		table.insert(parts, encode(k) .. "=" .. encode(params[k]))
	end
	local query = if #parts > 0 then "?" .. table.concat(parts, "&") else ""
	return url.SCHEME .. "://" .. action .. query
end

-- The action and params of one of our links, or nil for any other URL.
function url.parse(link: string): (string?, { [string]: string })
	local action, rest = string.match(link, "^tern%-worktrees://([%w_%-]+)/?(.*)$")
	local params: { [string]: string } = {}
	if action == nil then
		return nil, params
	end
	local query = string.match(rest or "", "^%?(.*)$") or ""
	for pair in string.gmatch(query, "[^&]+") do
		local k, v = string.match(pair, "^([^=]*)=(.*)$")
		if k then
			params[decode(k)] = decode(v :: string)
		else
			params[decode(pair)] = ""
		end
	end
	return action, params
end

return url
