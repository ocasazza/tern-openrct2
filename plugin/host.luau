--[[
Render a RollerCoaster Tycoon 2 park inside a Tern block. The picture comes
from OpenRCT2's own offscreen renderer (`openrct2 screenshot ... giant`), so
every pixel is real game art from the player's own install; the block chooses
the view and shows the result in a Tern surface.
]]

local ui = tern.ui

-- The Nix build replaces this with the packaged OpenRCT2; TERN_OPENRCT2_BIN
-- wins at run time so a different build can be pointed at.
local BIN = "@OPENRCT2@"

local DATA = tern.plugin.data
local OUT = DATA .. "/park.png"
local READ_CAP = 16 * 1024 * 1024
local MAX_SIDE = 4096
local ZOOM_MIN, ZOOM_MAX = 0, 3
local RENDER_TIMEOUT_MS = 300000
local TICK_MS = 1000
local REPUBLISH_TICKS = 10

local PARK_EXT = { [".park"] = true, [".sv6"] = true, [".sc6"] = true, [".sea"] = true }

local SAVE_DIRS = {
	"Library/Application Support/OpenRCT2/save",
	".config/OpenRCT2/save",
	".local/share/OpenRCT2/save",
}

local CONFIG_INI = {
	"Library/Application Support/OpenRCT2/config.ini",
	".config/OpenRCT2/config.ini",
}

-- Directories that hold a RollerCoaster Tycoon 2 install, relative to HOME:
-- the game data is platform-independent, so a Windows copy under Steam counts.
local RCT2_SUFFIXES = {
	"Library/Application Support/Steam/steamapps/common/RollerCoaster Tycoon 2",
	"Library/Application Support/Steam/steamapps/common/RollerCoaster Tycoon 2 Triple Thrill Pack",
	".steam/steam/steamapps/common/RollerCoaster Tycoon 2",
	".local/share/Steam/steamapps/common/RollerCoaster Tycoon 2",
	"GOG Games/RollerCoaster Tycoon 2",
	"Games/RollerCoaster Tycoon 2",
}

-- ------------------------------------------------------------------ helpers --

local function push(list, item)
	if item ~= nil then
		list[#list + 1] = item
	end
	return list
end

local function basename(path)
	return (string.match(path, "([^/]+)$")) or path
end

local function dirname(path)
	return (string.match(path, "^(.*)/[^/]+$")) or ""
end

local function ext(path)
	local suffix = string.match(path, "(%.[^./]+)$")
	return suffix ~= nil and string.lower(suffix) or ""
end

local function alive(state)
	local ok, panes = pcall(tern.pane.list)
	if not ok or type(panes) ~= "table" or state.cx == nil then
		return false
	end
	for _, info in ipairs(panes) do
		if info.pane == state.cx.pane then
			return true
		end
	end
	return false
end

-- PNG dimensions from the IHDR chunk, so a giant render can be rejected before
-- it reaches an image node (4096 px a side is the limit).
local function png_size(bytes)
	if type(bytes) ~= "string" or #bytes < 24 then
		return nil
	end
	if string.sub(bytes, 1, 8) ~= "\137PNG\r\n\26\n" then
		return nil
	end
	local function be32(at)
		local a, b, c, d = string.byte(bytes, at, at + 3)
		return a * 16777216 + b * 65536 + c * 256 + d
	end
	return be32(17), be32(21)
end

-- ------------------------------------------------------------- park sources --

local function game_path()
	local home = tern.getenv("HOME") or ""
	for _, rel in ipairs(CONFIG_INI) do
		local ok, text = pcall(tern.fs.read, home .. "/" .. rel, 256 * 1024)
		if ok and type(text) == "string" then
			local value = string.match(text, "game_path%s*=%s*\"([^\"]+)\"")
				or string.match(text, "game_path%s*=%s*([^\r\n]+)")
			if value ~= nil and value ~= "" then
				return (string.gsub(value, "%s+$", ""))
			end
		end
	end
	return nil
end

local function exists(path)
	local ok, value = pcall(tern.fs.exists, path)
	return ok and value == true
end

local function looks_like_rct2(dir)
	return exists(dir .. "/Data/g1.dat") or exists(dir .. "/data/g1.dat")
end

-- The renderer takes --rct2-data-path, so the block can use an install without
-- the user configuring OpenRCT2 first.
local function rct2_path()
	local override = tern.getenv("TERN_RCT2_PATH")
	if override ~= nil and override ~= "" and looks_like_rct2(override) then
		return override
	end
	local configured = game_path()
	if configured ~= nil and looks_like_rct2(configured) then
		return configured
	end
	local home = tern.getenv("HOME") or ""
	for _, rel in ipairs(RCT2_SUFFIXES) do
		local dir = home .. "/" .. rel
		if looks_like_rct2(dir) then
			return dir
		end
	end
	return nil
end

local function discover()
	local found, seen = {}, {}
	local function add(path)
		if type(path) ~= "string" or path == "" or seen[path] then
			return
		end
		if not PARK_EXT[ext(path)] then
			return
		end
		if not exists(path) then
			return
		end
		seen[path] = true
		found[#found + 1] = { path = path, name = basename(path), dir = dirname(path) }
	end

	local override = tern.getenv("TERN_OPENRCT2_PARK")
	if override ~= nil and override ~= "" then
		add(override)
	end

	local home = tern.getenv("HOME") or ""
	for _, rel in ipairs(SAVE_DIRS) do
		local dir = home .. "/" .. rel
		local ok, names = pcall(tern.fs.list, dir)
		if ok and type(names) == "table" then
			for _, name in ipairs(names) do
				add(dir .. "/" .. name)
			end
		end
	end

	local roots = {}
	push(roots, rct2_path())
	push(roots, game_path())
	for _, root in ipairs(roots) do
		local ok, names = pcall(tern.fs.list, root .. "/Scenarios")
		if ok and type(names) == "table" then
			for _, name in ipairs(names) do
				add(root .. "/Scenarios/" .. name)
			end
		end
	end

	table.sort(found, function(a, b)
		return string.lower(a.name) < string.lower(b.name)
	end)
	return found
end

-- ------------------------------------------------------------------ render --

local start_render

local function fail(state, text)
	state.phase = "error"
	state.error = text
	state.rendering = false
	if state.cx ~= nil then
		state.cx:render()
	end
end

-- OpenRCT2 writes coloured diagnostics; a block shows plain text.
local function plain(text)
	if type(text) ~= "string" then
		return text
	end
	return (string.gsub(string.gsub(text, "\27%[[%d;]*m", ""), "\r", ""))
end

local function render_done(state, gen, result)
	if gen ~= state.gen then
		return
	end
	local live = state.cx
	if live == nil then
		return
	end
	state.rendering = false
	if result.timed_out then
		fail(state, "OpenRCT2 did not finish the render in time")
		return
	end
	if result.status ~= 0 then
		-- OpenRCT2 reports load failures on stdout, so fall back to it.
		local why = result.stderr
		if type(why) ~= "string" or why == "" then
			why = result.stdout
		end
		if type(why) ~= "string" or why == "" then
			why = "exit " .. tostring(result.status)
		end
		fail(state, "OpenRCT2 failed: " .. plain(string.sub(why, 1, 400)))
		return
	end
	local ok, bytes = pcall(tern.fs.read, OUT, READ_CAP)
	if not ok or type(bytes) ~= "string" or #bytes == 0 then
		fail(state, "OpenRCT2 wrote no image to " .. OUT)
		return
	end
	local w, h = png_size(bytes)
	if w == nil then
		fail(state, "OpenRCT2 wrote something that is not a PNG")
		return
	end
	if (w > MAX_SIDE or h > MAX_SIDE) and state.zoom < ZOOM_MAX then
		state.zoom = state.zoom + 1
		state.detail = "Image was " .. w .. "x" .. h .. "; retrying at zoom " .. state.zoom
		start_render(state)
		return
	end
	state.bytes = bytes
	state.blob = live:blob(bytes, "image/png")
	state.width, state.height = w, h
	state.phase = "ready"
	state.detail = w .. "x" .. h
	live:render()
end

start_render = function(state)
	local live = state.cx
	if live == nil or state.park == nil or state.rendering then
		return
	end
	state.gen = state.gen + 1
	local gen = state.gen
	state.rendering = true
	state.phase = "rendering"
	state.detail = "Rendering " .. state.park.name .. "..."
	live:render()

	local bin = tern.getenv("TERN_OPENRCT2_BIN")
	if bin == nil or bin == "" then
		bin = BIN
	end
	local argv = {
		bin,
		"screenshot",
		state.park.path,
		OUT,
		"giant",
		tostring(state.zoom),
		tostring(state.rotation),
	}
	local rct2 = rct2_path()
	if rct2 ~= nil then
		argv[#argv + 1] = "--rct2-data-path"
		argv[#argv + 1] = rct2
	end
	local ok, err = pcall(tern.process.run, argv, { timeout_ms = RENDER_TIMEOUT_MS }, function(result)
		render_done(state, gen, result)
	end)
	if not ok then
		fail(state, "Cannot run OpenRCT2: " .. tostring(err))
	end
end

local function start_loop(state, cx)
	state.cx = cx
	tern.timer(TICK_MS, function()
		local live = state.cx
		if state.stopped or live == nil or not alive(state) then
			return
		end
		state.tick = state.tick + 1
		-- A window that missed the blob (hidden tab, restored pane) never asks
		-- again, so the pane republishes the picture on a slow round.
		if state.phase == "ready" and state.bytes ~= nil and state.tick % REPUBLISH_TICKS == 0 then
			state.blob = live:blob(state.bytes, "image/png")
			live:render()
		end
		start_loop(state, live)
	end)
end

-- -------------------------------------------------------------------- view --

local function message(state)
	local hint
	if rct2_path() == nil then
		hint = "Point TERN_RCT2_PATH at a RollerCoaster Tycoon 2 install: the folder holding Data/ and Scenarios/."
	else
		hint = "Save a park in OpenRCT2, or set TERN_OPENRCT2_PARK to one. Press r to try again."
	end
	return ui.col({
		ui.text(ui.span(state.error or state.detail or "Working...", "warning")),
		ui.text(ui.span(hint, "muted")),
	})
end

local function button(icon, act, title)
	return ui.node("icon", { key = act, name = icon, role = "btn", title = title, actions = { click = act } })
end

local function dock(state)
	local rows = {}
	if state.phase == "error" then
		rows[#rows + 1] = button("revert", "retry", "Render again (r)")
		rows[#rows + 1] = button("list", "pick", "Choose another park (p)")
	else
		rows[#rows + 1] = button("zoom-in", "zoom-in", "Closer (z)")
		rows[#rows + 1] = button("zoom-out", "zoom-out", "Further out (x)")
		rows[#rows + 1] = button("compass", "rotate", "Rotate the view (r)")
		rows[#rows + 1] = button("redo", "refresh", "Render again")
		rows[#rows + 1] = button("list", "pick", "Choose another park (p)")
	end
	local status
	if state.phase == "ready" then
		status = string.format("%s -- zoom %d, rotation %d, %s", state.park.name, state.zoom, state.rotation,
			state.detail or "")
	else
		status = state.error or state.detail or "Working..."
	end
	return ui.col({
		ui.node("row", { key = "btns", role = "btns" }, rows),
		ui.text(ui.span(status, "muted")),
	})
end

local function picker_view(state)
	local picker = state.picker
	local items = {}
	for _, entry in ipairs(picker.list) do
		items[#items + 1] = {
			id = entry.path,
			label = entry.name,
			detail = entry.dir,
		}
	end
	return ui.node("picker", {
		key = "picker",
		size = "screen",
		title = "Choose a park",
		noun = "park",
		query = picker.q,
		items = items,
		selected = picker.sel,
		total = #items,
		empty = { ui.span("No park matches that.", "muted") },
		actions = {
			{ id = "open", label = "Open", keys = { "enter" }, primary = true },
			{ id = "close", label = "Close", keys = { "escape" } },
		},
	})
end

local function view(state, cx)
	state.cx = cx
	if state.picker ~= nil then
		return { main = ui.col({ picker_view(state) }), dock = dock(state) }
	end
	if state.phase == "error" or state.park == nil then
		return { main = message(state), dock = dock(state) }
	end
	local kids = {}
	if state.blob ~= nil then
		kids[#kids + 1] = ui.node("image", {
			key = "park",
			role = "park",
			blob = state.blob,
			alt = state.park.name,
		})
	else
		kids[#kids + 1] = ui.text(ui.span(state.detail or "Rendering...", "muted"))
	end
	return { main = ui.node("col", { key = "stage", grow = 1 }, kids), dock = dock(state) }
end

-- ------------------------------------------------------------------ events --

local function refilter(state)
	local picker = state.picker
	local found = {}
	local needle = string.lower(picker.q)
	for _, entry in ipairs(state.parks) do
		if needle == ""
			or string.find(string.lower(entry.name), needle, 1, true) ~= nil
			or string.find(string.lower(entry.dir), needle, 1, true) ~= nil
		then
			found[#found + 1] = entry
		end
	end
	picker.list = found
	picker.sel = found[1] ~= nil and found[1].path or nil
end

local function open_picker(state)
	state.picker = { q = "", sel = nil, list = {} }
	refilter(state)
end

local function choose(state, path)
	for _, entry in ipairs(state.parks) do
		if entry.path == path then
			state.park = entry
			state.phase = "rendering"
			state.detail = "Rendering " .. entry.name .. "..."
			start_render(state)
			return
		end
	end
end

local function zoom(state, delta)
	local next_zoom = math.max(ZOOM_MIN, math.min(ZOOM_MAX, state.zoom + delta))
	if next_zoom == state.zoom then
		return false
	end
	state.zoom = next_zoom
	start_render(state)
	return true
end

local function on_action(state, ev)
	local act = ev.act
	if act == "zoom-in" then
		zoom(state, -1)
	elseif act == "zoom-out" then
		zoom(state, 1)
	elseif act == "rotate" then
		state.rotation = (state.rotation + 1) % 4
		start_render(state)
	elseif act == "refresh" or act == "retry" then
		start_render(state)
	elseif act == "pick" then
		state.parks = discover()
		if #state.parks == 0 then
			fail(state, "No park files found")
			return
		end
		open_picker(state)
	elseif act == "close" then
		state.picker = nil
	elseif act == "open" then
		if state.picker ~= nil and state.picker.sel ~= nil then
			local path = state.picker.sel
			state.picker = nil
			choose(state, path)
		end
	end
end

local function picker_key(state, key)
	local picker = state.picker
	if key.name == "escape" then
		state.picker = nil
	elseif key.name == "enter" then
		if picker.sel ~= nil then
			local path = picker.sel
			state.picker = nil
			choose(state, path)
		end
	elseif key.name == "up" then
		for index, entry in ipairs(picker.list) do
			if entry.path == picker.sel and index > 1 then
				picker.sel = picker.list[index - 1].path
				break
			end
		end
	elseif key.name == "down" then
		for index, entry in ipairs(picker.list) do
			if entry.path == picker.sel and picker.list[index + 1] ~= nil then
				picker.sel = picker.list[index + 1].path
				break
			end
		end
	elseif key.name == "backspace" then
		picker.q = string.sub(picker.q, 1, #picker.q - 1)
		refilter(state)
	elseif key.text ~= nil and #key.text > 0 and not key.ctrl and not key.meta then
		picker.q = picker.q .. key.text
		refilter(state)
	else
		return false
	end
	return true
end

-- ------------------------------------------------------------------- block --

local definition = {
	init = function(cx, args, saved)
		local state = {
			cx = cx,
			phase = "scan",
			detail = "Looking for parks...",
			error = nil,
			parks = {},
			park = nil,
			picker = nil,
			zoom = ZOOM_MAX,
			rotation = 0,
			blob = nil,
			bytes = nil,
			width = nil,
			height = nil,
			gen = 0,
			tick = 0,
			rendering = false,
			stopped = false,
		}
		if type(saved) == "table" then
			if type(saved.zoom) == "number" then
				state.zoom = math.max(ZOOM_MIN, math.min(ZOOM_MAX, math.floor(saved.zoom)))
			end
			if type(saved.rotation) == "number" then
				state.rotation = math.floor(saved.rotation) % 4
			end
		end
		pcall(tern.fs.mkdir, DATA)
		state.parks = discover()
		if #state.parks == 0 then
			state.phase = "error"
			state.error = "No RollerCoaster Tycoon 2 park files found"
			start_loop(state, cx)
			return state
		end
		local wanted = type(saved) == "table" and saved.park or nil
		if type(args) == "table" then
			for _, arg in ipairs(args) do
				if arg == "pick" then
					wanted = nil
					state.pick_flag = true
				end
			end
		end
		if wanted ~= nil then
			choose(state, wanted)
		end
		if state.park == nil and state.pick_flag then
			open_picker(state)
		end
		if state.park == nil and state.picker == nil then
			choose(state, state.parks[1].path)
		end
		start_loop(state, cx)
		return state
	end,

	view = view,

	title = function(state)
		if state.park == nil then
			return "OpenRCT2"
		end
		return "OpenRCT2 -- " .. state.park.name
	end,

	key = function(state, key)
		if state.picker ~= nil then
			return picker_key(state, key)
		end
		if key.name == "p" then
			state.parks = discover()
			if #state.parks > 0 then
				open_picker(state)
			end
		elseif key.name == "z" then
			return zoom(state, -1)
		elseif key.name == "x" then
			return zoom(state, 1)
		elseif key.name == "r" then
			state.rotation = (state.rotation + 1) % 4
			start_render(state)
		elseif key.name == "g" then
			start_render(state)
		else
			return false
		end
		return true
	end,

	event = function(state, ev)
		if ev.ev == "action" then
			on_action(state, ev)
		elseif ev.ev == "select" then
			if state.picker ~= nil and type(ev.item) == "string" then
				state.picker.sel = ev.item
			end
		elseif ev.ev == "activate" then
			if state.picker ~= nil and type(ev.item) == "string" then
				local path = ev.item
				state.picker = nil
				choose(state, path)
			end
		end
	end,

	save = function(state)
		return {
			v = 1,
			park = state.park ~= nil and state.park.path or nil,
			zoom = state.zoom,
			rotation = state.rotation,
		}
	end,
}


-- --------------------------------------------------------------- game block --

-- The block reads and drives the openrct2-web server; window.luau owns the
-- game pane, and a link to GAME_LINK asks it to focus or open that pane.
local PORT = "@PORT@"
local API_URL = "http://127.0.0.1:" .. PORT .. "/api"
local GAME_LINK = "http://127.0.0.1:" .. PORT .. "/#play"
local POLL_MS = 2000
local FETCH_TIMEOUT_MS = 8000
local MONTHS = { "March", "April", "May", "June", "July", "August", "September", "October" }

local function api(body, done)
	local ok, err = pcall(tern.fetch, API_URL, {
		method = "POST",
		headers = { ["Content-Type"] = "application/json" },
		body = tern.json.encode(body),
		timeout_ms = FETCH_TIMEOUT_MS,
	}, function(result)
		done(result)
	end)
	if not ok then
		done({ status = 0, headers = {}, body = "", error = tostring(err), timed_out = false })
	end
end

-- Sorts a response into the block's connection states: "down" (server
-- unreachable), "waiting" (503 game_not_connected), "error", "connected".
local function classify(result)
	if result.error ~= nil then
		return "down", result.error, nil
	end
	local ok, data = pcall(tern.json.decode, result.body)
	if not ok or type(data) ~= "table" then
		return "down", "HTTP " .. tostring(result.status) .. " without a JSON body", nil
	end
	if data.ok == false then
		local err = type(data.error) == "table" and data.error or {}
		if err.code == "game_not_connected" then
			return "waiting", nil, nil
		end
		return "error", tostring(err.code or "error") .. ": " .. tostring(err.message or ""), nil
	end
	return "connected", nil, data
end

local function thousands(n)
	local text = tostring(math.floor(math.abs(n)))
	local out = string.reverse((string.gsub(string.reverse(text), "(%d%d%d)", "%1,")))
	out = string.gsub(out, "^,", "")
	return (n < 0 and "-" or "") .. out
end

-- OpenRCT2 keeps money in tenths of a currency unit.
local function money(tenths)
	if type(tenths) ~= "number" then
		return "-"
	end
	local abs = math.floor(math.abs(tenths))
	return (tenths < 0 and "-$" or "$") .. thousands(abs // 10) .. "." .. tostring(abs % 10)
end

local function objective_text(scenario)
	local obj = scenario.objective
	if type(obj) ~= "table" then
		return "none"
	end
	local keys = {}
	for key in pairs(obj) do
		if key ~= "type" then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys)
	local parts = { tostring(obj.type or "objective") }
	for _, key in ipairs(keys) do
		parts[#parts + 1] = key .. " " .. tostring(obj[key])
	end
	return table.concat(parts, ", ")
end

local game_poll

local function game_apply(state, result)
	local conn, detail, data = classify(result)
	state.conn, state.detail = conn, detail
	state.info = conn == "connected" and data or nil
end

game_poll = function(state)
	if state.polling or state.stopped or state.cx == nil then
		return
	end
	state.polling = true
	api({ v = "status" }, function(result)
		state.polling = false
		game_apply(state, result)
		state.cx:render()
	end)
end

local function game_send(state, body, label)
	api(body, function(result)
		local conn, detail = classify(result)
		if conn ~= "connected" and state.cx ~= nil then
			state.cx:toast("error", label .. " failed", detail or conn)
		end
		state.polling = false
		game_poll(state)
	end)
end

local function game_loop(state)
	tern.timer(POLL_MS, function()
		if state.stopped or state.cx == nil or not alive(state) then
			state.stopped = true
			return
		end
		game_poll(state)
		game_loop(state)
	end)
end

local function game_toggle_pause(state)
	if state.info == nil then
		return
	end
	game_send(state, { v = "pause", paused = not state.info.paused }, "Pause")
end

local function game_command(state, act, value)
	if act == "pause" then
		game_toggle_pause(state)
	elseif act == "speed" and tonumber(value) ~= nil then
		game_send(state, { v = "speed", speed = tonumber(value) }, "Speed")
	elseif act == "save" then
		game_send(state, { v = "save", filename = "tern" }, "Save")
	elseif act == "game" then
		state.cx:open(GAME_LINK)
	else
		return false
	end
	return true
end

local function tile(id, label, value)
	return ui.node("col", { key = "stat-" .. id, role = "stat" }, {
		ui.text(ui.span(label, "muted")),
		ui.text(ui.span(value, "strong")),
	})
end

local function game_banner(state)
	if state.conn == "connected" then
		local park = state.info.park or {}
		local when = ""
		local date = state.info.date
		if type(date) == "table" then
			when = string.format("%s %s, year %s", MONTHS[(date.month or 0) + 1] or "?", tostring(date.day or "?"),
				tostring(date.year or "?"))
		end
		return ui.node("row", { key = "banner", role = "banner" }, {
			ui.text(ui.span(park.name or "OpenRCT2", "strong")),
			ui.text(ui.span(when, "muted")),
		})
	elseif state.conn == "waiting" then
		return ui.node("row", { key = "banner", role = "banner-wait" }, {
			ui.text(ui.span("Game not connected -- open the game pane (g)", "warning")),
		})
	elseif state.conn == "down" then
		return ui.node("row", { key = "banner", role = "banner-down" }, {
			ui.text(ui.span("openrct2-web is not reachable on port " .. PORT, "error")),
			ui.text(ui.span(state.detail or "", "muted")),
		})
	elseif state.conn == "error" then
		return ui.node("row", { key = "banner", role = "banner-down" }, {
			ui.text(ui.span(state.detail or "error", "error")),
		})
	end
	return ui.node("row", { key = "banner", role = "banner-wait" }, { ui.text(ui.span("Connecting...", "muted")) })
end

local function game_view(state, cx)
	state.cx = cx
	local kids = { game_banner(state) }
	if state.conn == "connected" then
		local info = state.info
		local park = info.park or {}
		local scenario = type(info.scenario) == "table" and info.scenario or {}
		local tiles = {
			tile("cash", "Cash", money(park.cash)),
			tile("guests", "Guests", tostring(park.guests or "-")),
			tile("rating", "Park rating", tostring(park.rating or "-")),
			tile("rides", "Rides", tostring(type(info.counts) == "table" and info.counts.rides or "-")),
			tile("objective", "Objective", objective_text(scenario)),
			tile("scenario", "Scenario", tostring(scenario.name or "-") .. " (" .. tostring(scenario.status or "-") .. ")"),
			tile("run", "Game", (info.paused and "paused" or "running") .. ", speed " .. tostring(info.speed or "?")),
		}
		kids[#kids + 1] = ui.node("col", { key = "stats", role = "stats" }, tiles)
	end
	return { main = ui.node("col", { key = "game", grow = 1 }, kids), dock = nil }
end

local function game_button(act, label, title)
	return ui.el("button", {
		key = act,
		class = "kit-btn",
		text = label,
		title = title,
		actions = { click = act },
	})
end

local function game_dock(state)
	local paused = state.info ~= nil and state.info.paused == true
	local rows = {
		game_button("pause", paused and "Resume" or "Pause", "Pause or resume (space)"),
		game_button("speed=1", "1", "Speed 1 (1)"),
		game_button("speed=2", "2", "Speed 2 (2)"),
		game_button("speed=3", "3", "Speed 3 (3)"),
		game_button("speed=4", "4", "Speed 4 (4)"),
		game_button("save", "Save", "Save the park as tern (s)"),
		game_button("game", "Game", "Focus or open the game pane (g)"),
	}
	return ui.node("row", { key = "btns", role = "btns" }, rows)
end

local game_definition = {
	init = function(cx)
		local state = { cx = cx, conn = "connecting", polling = false, stopped = false }
		game_poll(state)
		game_loop(state)
		return state
	end,

	view = function(state, cx)
		local view = game_view(state, cx)
		view.dock = game_dock(state)
		return view
	end,

	title = function(state)
		local park = state.info ~= nil and state.info.park or nil
		if type(park) == "table" and type(park.name) == "string" and park.name ~= "" then
			return "OpenRCT2 -- " .. park.name
		end
		return "OpenRCT2"
	end,

	key = function(state, key)
		if key.ctrl or key.meta or key.alt then
			return false
		end
		local name = key.name
		local handled
		if name == "space" then
			handled = game_command(state, "pause")
		elseif name == "1" or name == "2" or name == "3" or name == "4" then
			handled = game_command(state, "speed", name)
		elseif name == "s" then
			handled = game_command(state, "save")
		elseif name == "g" then
			handled = game_command(state, "game")
		end
		if not handled then
			return false
		end
		return true
	end,

	event = function(state, ev)
		if ev.ev == "action" then
			game_command(state, ev.act, ev.value)
		end
	end,

	save = function()
		return { v = 1 }
	end,
}

tern.block.define("game", game_definition)
tern.block.define("park", definition)
