-- Palette entries for the OpenRCT2 blocks and the game pane.
--
-- "Play" opens the live `openrct2.game` block and docks a Tern browser pane on
-- the openrct2-web server beside it. The block's Game button opens GAME_LINK,
-- which route.link claims and sends through the same logic.
local PORT = "@PORT@"
local PREFIX = "http://127.0.0.1:" .. PORT .. "/"
local GAME_LINK = PREFIX .. "#play"

-- The page is the whole game, so while it has focus the browser address bar
-- is hidden; the sheet is empty at every other time.
local KIOSK_CSS = ".kit-web-bar { display: none !important; }"
local kiosk_pane = nil

local function is_game_block(info)
	return info.block == "openrct2.game" or info.block == "plugin.openrct2.game"
end

local function is_game_page(info)
	return info.kind == "browser" and type(info.url) == "string" and string.sub(info.url, 1, #PREFIX) == PREFIX
end

-- Parked panes have no tab; docking against one shows nothing, so Play only
-- reuses panes that are on screen.
local function find(cx, test)
	for _, info in ipairs(cx.session:panes()) do
		if info.tab ~= nil and not info.parked and test(info) then
			return info.pane
		end
	end
	return nil
end

local function open_page(cx, owner)
	local page = find(cx, is_game_page)
	if page ~= nil then
		cx.layout:focus(page)
		return
	end
	cx.browser:call({ op = "open", owner = owner, url = PREFIX }):next(function(result, err, cx2)
		local block = result ~= nil and result.ok ~= nil and result.ok.block or nil
		if block == nil then
			local why = err
			if why == nil and result ~= nil and result.error ~= nil then
				why = result.error.message
			end
			cx2:toast("error", "Could not open the game pane", tostring(why))
			return
		end
		local docked, reason = cx2.layout:dock(block, owner, "right")
		if not docked then
			cx2:toast("error", "Could not dock the game pane", reason)
		end
		-- A driven page keeps a fixed page size; released, it follows the pane.
		cx2.browser:call({ op = "release", block = block })
	end)
end

local function play(cx)
	local block = find(cx, is_game_block)
	if block == nil then
		block = cx:new_block("openrct2.game", {}, "split")
	end
	if block == nil then
		cx:toast("error", "No Tern host here defines the OpenRCT2 game block")
		return
	end
	open_page(cx, block)
end

local function open_block(cx, args, how)
	local pane = cx:new_block("openrct2.park", args, how)
	if pane == nil then
		cx:toast("error", "No Tern host here defines the OpenRCT2 block")
	end
	return pane
end

tern.command({
	id = "play",
	title = "OpenRCT2: Play",
	group = "OpenRCT2",
	icon = "play",
	keys = { "cmd+alt+o" },
	run = play,
})

tern.command({
	id = "park",
	title = "OpenRCT2: Park",
	group = "OpenRCT2",
	icon = "canvas",
	run = function(cx)
		open_block(cx, {}, "split")
	end,
})

tern.command({
	id = "choose",
	title = "OpenRCT2: Choose Park",
	group = "OpenRCT2",
	icon = "list",
	run = function(cx)
		open_block(cx, { "pick" }, "split")
	end,
})

tern.route.link(function(link, cx)
	if link.url == GAME_LINK then
		play(cx)
		return { handled = true }
	end
	return nil
end)

-- A tab whose focused pane is the game page or the game block reads "OpenRCT2".
tern.chrome.tab_title(function(tab)
	if string.sub(tab.title, 1, 8) == "OpenRCT2" then
		return "OpenRCT2"
	end
	return nil
end)

local function set_kiosk(pane)
	kiosk_pane = pane
	tern.css("openrct2-kiosk", pane ~= nil and KIOSK_CSS or "")
end

tern.on("focus", function(ev, cx)
	local info = cx.session:pane(ev.pane)
	if info ~= nil and is_game_page(info) then
		if kiosk_pane ~= ev.pane then
			set_kiosk(ev.pane)
		end
	elseif kiosk_pane ~= nil then
		set_kiosk(nil)
	end
end)

tern.on("pane_closed", function(ev)
	if kiosk_pane ~= nil and ev.pane == kiosk_pane then
		set_kiosk(nil)
	end
end)
