-- One-off test harness for wifiindicator.koplugin.
-- Run from the koreader repo root:
--   luajit plugins/wifiindicator.koplugin/test/test_main.lua plugins/wifiindicator.koplugin/main.lua

local plugin_path = arg[1] or "plugins/wifiindicator.koplugin/main.lua"

-- ---------------------------------------------------------------- stubs --
local shown = {}
local broadcasts = {}
local wifi = { on = false, connected = false }

local UIManager = {
    unschedule = function() end,
    scheduleIn = function() end,
    close = function() end,
    setDirty = function() end,
    broadcastEvent = function(self, ev) table.insert(broadcasts, ev.name) end,
}
UIManager.show = function(self, widget, ...)
    table.insert(shown, widget)
end

local settings_data = {
    wifiindicator_show_icon = false, -- keep corner-toast code path out of these tests
}
_G.G_reader_settings = {
    nilOrTrue = function(self, key)
        local v = settings_data[key]
        if v == nil then return true end
        return v
    end,
    flipNilOrTrue = function() end,
}

local identity_gettext = setmetatable({}, { __call = function(_, s) return s end })

local FakeTouchMenu = {}
FakeTouchMenu.init = function(menu)
    menu.show_parent = menu
    menu.time_info = { name = "time_info" }
    menu.device_info = {
        menu.time_info,
        resetLayout = function() end,
    }
end
FakeTouchMenu.updateItems = function(menu) end

package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = 0 } end
package.preload["device"] = function()
    return { screen = { scaleBySize = function(_, n) return n end } }
end
package.preload["ui/widget/container/framecontainer"] = function()
    return { new = function(self, t) return t end }
end
package.preload["ui/widget/iconwidget"] = function()
    return { new = function(self, t) return t end }
end
package.preload["ui/size"] = function()
    return { padding = { small = 2 }, span = { horizontal_default = 4 } }
end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(self, t) return t end }
end
package.preload["logger"] = function()
    return { dbg = function() end, warn = function() end, info = function() end }
end
package.preload["gettext"] = function() return identity_gettext end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["ui/widget/horizontalspan"] = function()
    return { new = function(_, o) o = o or {}; o.is_span = true; return o end }
end
package.preload["ui/widget/iconbutton"] = function()
    local IconButton = {}
    IconButton.__index = IconButton
    IconButton.new = function(_, o)
        o = o or {}
        o.is_icon_button = true
        return setmetatable(o, IconButton)
    end
    function IconButton:setIcon(icon)
        if icon ~= self.icon then self.icon = icon end
    end
    return IconButton
end
package.preload["ui/network/manager"] = function()
    return {
        isWifiOn = function() return wifi.on end,
        isConnected = function() return wifi.connected end,
    }
end
package.preload["ui/widget/touchmenu"] = function() return FakeTouchMenu end

-- ------------------------------------------------------------- helpers --
local failures = 0
local function check(cond, label)
    print(string.format("[%s] %s", cond and "PASS" or "FAIL", label))
    if not cond then failures = failures + 1 end
end

local function isSuppressed(text)
    shown = {}
    UIManager:show({ text = text })
    return #shown == 0
end

local function newMenu()
    local menu = {}
    FakeTouchMenu.init(menu)
    return menu
end

local WifiIndicator = assert(loadfile(plugin_path))()

-- --------------------------------------- popup suppression (regression) --
for __, msg in ipairs({
    "Scanning for networks…",
    "Connection failed",
    "Unable to communicate with the Wi-Fi backend",
    "Scanning for Wi-Fi networks timed out",
    "Error connecting to the network",
    "Connecting to network MyHomeWifi…",
    "Turning on Wi-Fi…",
    "You can now retry the action that required network access",
}) do
    check(isSuppressed(msg), "suppressed: " .. msg)
end
check(not isSuppressed("Book saved"), "passed through: Book saved")
check(not isSuppressed("Connection failed, but with extra text"),
    "passed through: Connection failed, but with extra text")
shown = {}
UIManager:show({ name = "no text" })
check(#shown == 1, "passed through: widget without text")

-- ------------------------------------------------- menu icon: injection --
wifi.on, wifi.connected = true, true
local menu = newMenu()
check(menu.device_info[1] ~= nil and menu.device_info[1].is_icon_button == true,
    "menu icon: IconButton injected at head of device_info")
check(menu.device_info[2] ~= nil and menu.device_info[2].is_span == true,
    "menu icon: span between icon and time")
check(menu.device_info[3] == menu.time_info,
    "menu icon: time_info still present after icon")
check(menu._wifiindicator_icon == menu.device_info[1],
    "menu icon: icon reachable as menu._wifiindicator_icon")
check(menu.device_info[1].icon == "wifi.open.100",
    "menu icon: connected state at build time")

settings_data.wifiindicator_menu_icon = false
local menu_off = newMenu()
check(menu_off.device_info[1] == menu_off.time_info,
    "menu icon: setting off -> no injection")
settings_data.wifiindicator_menu_icon = nil

assert(loadfile(plugin_path))() -- second plugin instance (FileManager + ReaderUI)
local menu2 = newMenu()
local icon_count = 0
for __, w in ipairs(menu2.device_info) do
    if w.is_icon_button then icon_count = icon_count + 1 end
end
check(icon_count == 1, "menu icon: double plugin load still injects exactly one icon")

-- ---------------------------------------------- menu icon: state refresh --
wifi.on, wifi.connected = true, true
local menu_state = newMenu()
wifi.on, wifi.connected = true, false
FakeTouchMenu.updateItems(menu_state)
check(menu_state._wifiindicator_icon.icon == "wifi.open.50",
    "menu icon: on-but-disconnected -> wifi.open.50 after updateItems")
wifi.on, wifi.connected = false, false
FakeTouchMenu.updateItems(menu_state)
check(menu_state._wifiindicator_icon.icon == "wifi.open.0",
    "menu icon: off -> wifi.open.0 after updateItems")
wifi.on, wifi.connected = true, true
FakeTouchMenu.updateItems(menu_state)
check(menu_state._wifiindicator_icon.icon == "wifi.open.100",
    "menu icon: connected -> wifi.open.100 after updateItems")

settings_data.wifiindicator_menu_icon = false
local menu_state_off = newMenu()
local ok_no_icon = pcall(FakeTouchMenu.updateItems, menu_state_off)
check(ok_no_icon, "menu icon: updateItems is a no-op without injected icon")
settings_data.wifiindicator_menu_icon = nil

-- ------------------------------------------------------ menu icon: tap --
local function clearBroadcasts()
    -- clear in place: the UIManager stub captured `broadcasts` as an upvalue,
    -- so reassigning `broadcasts = {}` would break the link
    for i = #broadcasts, 1, -1 do broadcasts[i] = nil end
end

wifi.on, wifi.connected = false, false
local menu_tap = newMenu()
clearBroadcasts()
menu_tap._wifiindicator_icon.callback()
check(broadcasts[1] == "ToggleWifi" and #broadcasts == 1,
    "menu icon: tap broadcasts ToggleWifi")
check(menu_tap._wifiindicator_icon.icon == "wifi.open.50",
    "menu icon: tap while off shows optimistic connecting state")

wifi.on, wifi.connected = true, true
local menu_tap2 = newMenu()
clearBroadcasts()
menu_tap2._wifiindicator_icon.callback()
check(broadcasts[1] == "ToggleWifi",
    "menu icon: tap while connected broadcasts ToggleWifi")
check(menu_tap2._wifiindicator_icon.icon == "wifi.open.0",
    "menu icon: tap while connected shows optimistic off state")

-- -------------------------------------------------- settings checkbox --
local menu_items = {}
WifiIndicator.addToMainMenu(WifiIndicator, menu_items)
local sub = menu_items.wifi_indicator.sub_item_table
check(#sub == 3, "settings: three checkboxes in plugin menu")
check(sub[3].checked_func() == true, "settings: menu icon default on")

-- ---------------------------------------------- delete plugin settings --
local deleted = {}
_G.G_reader_settings.delSetting = function(self, key) table.insert(deleted, key) end
WifiIndicator.deletePluginSettings(WifiIndicator)
table.sort(deleted)
check(#deleted == 3
    and deleted[1] == "wifiindicator_menu_icon"
    and deleted[2] == "wifiindicator_show_icon"
    and deleted[3] == "wifiindicator_suppress_popups",
    "settings: deletePluginSettings removes all three keys")

print(failures == 0 and "ALL TESTS PASSED" or (failures .. " TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
