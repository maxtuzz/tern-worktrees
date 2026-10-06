--!strict
-- A one-line text field's editing, for blocks: the block owns the text and
-- the caret (Tern's `input` node only draws them). Byte offsets, so branch
-- names are treated as ASCII; other text still works, the caret just counts
-- bytes.

local field = {}

export type Field = { text: string, cursor: number }

function field.new(text: string?): Field
	local t = text or ""
	return { text = t, cursor = #t }
end

-- Applies `key` to `f`; returns true when the key edited or moved.
function field.key(f: Field, key: Key): boolean
	local name = key.name
	if name == "paste" then
		local text = string.gsub(key.text or "", "[\r\n]+", "")
		f.text = string.sub(f.text, 1, f.cursor) .. text .. string.sub(f.text, f.cursor + 1)
		f.cursor += #text
	elseif name == "backspace" then
		if key.meta then
			f.text = string.sub(f.text, f.cursor + 1)
			f.cursor = 0
		elseif key.alt or key.ctrl then
			local before = string.sub(f.text, 1, f.cursor)
			local kept = string.match(before, "^(.-)[^/%-_%s]*[/%-_%s]?$") or ""
			f.text = kept .. string.sub(f.text, f.cursor + 1)
			f.cursor = #kept
		elseif f.cursor > 0 then
			f.text = string.sub(f.text, 1, f.cursor - 1) .. string.sub(f.text, f.cursor + 1)
			f.cursor -= 1
		end
	elseif name == "delete" then
		f.text = string.sub(f.text, 1, f.cursor) .. string.sub(f.text, f.cursor + 2)
	elseif name == "left" then
		f.cursor = math.max(0, f.cursor - 1)
	elseif name == "right" then
		f.cursor = math.min(#f.text, f.cursor + 1)
	elseif name == "home" or (key.ctrl and name == "a") then
		f.cursor = 0
	elseif name == "end" or (key.ctrl and name == "e") then
		f.cursor = #f.text
	elseif key.ctrl and name == "u" then
		f.text = string.sub(f.text, f.cursor + 1)
		f.cursor = 0
	elseif key.text and key.text ~= "" and not key.ctrl and not key.meta then
		f.text = string.sub(f.text, 1, f.cursor) .. key.text .. string.sub(f.text, f.cursor + 1)
		f.cursor += #key.text
	else
		return false
	end
	return true
end

return field
