--!strict
-- Rotating sea-creature autonames for worktrees created without a branch
-- name (by Carly, or a blank dialog). `pick` is pure (tested with plain
-- luau); the window keeps the rotation cursor in `tern.kv`.

local util = require("./util")

local autoname = {}

autoname.POOL = {
	"pearlfish", "manatee", "murex", "halfbeak", "narwhal", "nautilus", "cuttle", "dugong",
	"wrasse", "remora", "triton", "sculpin", "grouper", "tarpon", "marlin", "puffer",
	"blenny", "goby", "hagfish", "lamprey", "seahorse", "squid", "octopus", "beluga",
	"walrus", "otter", "orca", "barnacle", "limpet", "cowrie", "conch", "krill",
	"anchovy", "sardine", "skate", "stingray", "sunfish", "tuna", "urchin", "whelk",
}

-- The first name from `pool`, starting at 1-based `cursor` and wrapping,
-- whose branch (`prefix .. name`), slug and session name aren't `taken`.
-- When the whole pool is taken, numbered names follow (`pearlfish-2`, …).
-- Returns the branch and the cursor for next time.
function autoname.pick(
	taken: { [string]: boolean },
	cursor: number?,
	prefix: string?,
	session_name: ((branch: string) -> string)?,
	pool: { string }?
): (string, number)
	local names = pool or autoname.POOL
	local n = #names
	local start = ((math.floor(cursor or 1) - 1) % n) + 1
	local pre = prefix or ""
	local function free(branch: string): boolean
		if taken[branch] or taken[util.slug(branch)] then
			return false
		end
		return not (session_name and taken[session_name(branch)])
	end
	for round = 1, 100 do
		for i = 0, n - 1 do
			local index = (start - 1 + i) % n + 1
			local name = names[index]
			local branch = pre .. (if round == 1 then name else name .. "-" .. round)
			if free(branch) then
				return branch, index % n + 1
			end
		end
	end
	error("no free autoname", 0)
end

return autoname
