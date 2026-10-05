-- A stand-in for Tern's `tern` global, enough to load both entries under
-- plain `luau` and drive their handlers. It records what the plugin
-- registers and does; it is not a model of Tern's behavior.

local stub = {}

-- Installs the global `tern` (declared before the local of the same name).
local function install(t: any)
	tern = t
end

local kv: { [string]: any } = {}
local files: { [string]: string } = {}
local json_store: { [string]: any } = {}
local json_seq = 0

stub.registered = {
	commands = {} :: { any },
	blocks = {} :: { [string]: any },
	events = {} :: { [string]: { any } },
	links = {} :: { any },
	status = nil :: any,
}
stub.processes = {} :: { any }
stub.timers = {} :: { any }

local function node(k: string, p: any?, c: any?): any
	return { k = k, p = p, c = c }
end

local ui = {
	span = function(t, s)
		return { t = t, s = s }
	end,
	text = function(spans)
		return node("text", { spans = spans })
	end,
	col = function(children)
		return node("col", nil, children)
	end,
	row = function(children)
		return node("row", nil, children)
	end,
	kv = function(items)
		return node("kv", { items = items })
	end,
	rule = function(label)
		return node("rule", { label = label })
	end,
	badge = function(t, tone)
		return node("badge", { text = t, tone = tone })
	end,
	list = function(items)
		local c = {}
		for i, it in items do
			c[i] = node("item", { label = it.label })
		end
		return node("list", {}, c)
	end,
	node = node,
}

local tern: any = {
	context = "host",
	plugin = { id = "worktrees", name = "Worktree Sessions", dir = "/plugin", data = "/data" },
	runtime = { os = "macos", jit = false },
	log = { debug = function(...) end, info = function(...) end, warn = function(...) end, error = function(...) end },
	json = {
		encode = function(v)
			json_seq += 1
			local key = "json#" .. json_seq
			json_store[key] = v
			return key
		end,
		decode = function(text)
			local v = json_store[text]
			if v == nil then
				error("tern.json.decode: not stub JSON")
			end
			return v
		end,
		array = function(t)
			return t or {}
		end,
		null = {},
	},
	now = function()
		return os.clock() * 1000
	end,
	getenv = function(name)
		return if name == "HOME" then "/Users/me" else nil
	end,
	timer = function(ms, fn)
		table.insert(stub.timers, { ms = ms, fn = fn })
		return { cancel = function() end }
	end,
	kv = {
		get = function(k)
			return kv[k]
		end,
		set = function(k, v)
			kv[k] = v
		end,
	},
	fs = {
		read = function(p)
			return files[p] or error("tern.fs.read " .. p .. ": No such file")
		end,
		write = function(p, t)
			files[p] = t
		end,
		exists = function(p)
			return files[p] ~= nil
		end,
		mkdir = function(_p) end,
		list = function(_p)
			return {}
		end,
		remove = function(p)
			files[p] = nil
		end,
	},
	process = {
		run = function(argv, opts, cb)
			table.insert(stub.processes, { argv = argv, opts = opts, cb = cb })
		end,
	},
	ui = ui,
	block = {
		define = function(id, def)
			stub.registered.blocks[id] = def
		end,
	},
	pane = {
		write = function(_p, _t) end,
		list = function()
			return {}
		end,
	},
	on = function(name, fn)
		stub.registered.events[name] = stub.registered.events[name] or {}
		table.insert(stub.registered.events[name], fn)
	end,
	command = function(def)
		table.insert(stub.registered.commands, def)
	end,
	bind = function(_c, _a) end,
	route = {
		open = function(_fn) end,
		link = function(fn)
			table.insert(stub.registered.links, fn)
		end,
	},
	chrome = {
		status = function(fn)
			stub.registered.status = fn
		end,
		refresh = function() end,
		tab_title = function(_fn) end,
		window_title = function(_fn) end,
	},
	css = function(_n, _s) end,
}

install(tern)
stub.tern = tern
stub.kv = kv
stub.files = files

-- A block cx that records effects.
function stub.block_cx(): any
	local cx = { pane = 7, cwd = "/", cols = 80, rows = 24, opened = {}, frames = {}, exited = nil }
	function cx:open(target)
		table.insert(self.opened, target)
	end
	function cx:frame(ops)
		table.insert(self.frames, ops)
	end
	function cx:exit(code)
		self.exited = code
	end
	function cx:render() end
	function cx:save() end
	function cx:toast(_l, _t, _s) end
	function cx:copy(_t) end
	return cx
end

function stub.key(name: string, text: string?): any
	return { name = name, text = text, ctrl = false, alt = false, shift = false, meta = false }
end

return stub
