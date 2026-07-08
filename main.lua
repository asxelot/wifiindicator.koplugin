--[[--
Wi-Fi status icon plugin.

Suppresses the Wi-Fi connection InfoMessage popups (the ones that show up
when Wi-Fi is being restored after waking up the device, among others) and
shows a small, transient Wi-Fi status icon in the top left corner of the
screen instead.

@module koplugin.WifiIndicator
--]]--

local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local IconWidget = require("ui/widget/iconwidget")
local NetworkMgr = require("ui/network/manager")
local Size = require("ui/size")
local TouchMenu = require("ui/widget/touchmenu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

-- How long the corner icon stays on screen (matches the timeout of the
-- popups it replaces).
local ICON_TIMEOUT_S = 3
-- Icon size, in unscaled pixels.
local ICON_SIZE = 24
-- Distance from the screen corner, in unscaled pixels.
local ICON_MARGIN = 4

local ICON_CONNECTED = "wifi.open.100"
local ICON_CONNECTING = "wifi.open.50"
local ICON_DISCONNECTED = "wifi.open.0"

-- Turn a (translated) message template into an anchored Lua pattern:
-- escape pattern magic characters, and let the %1 placeholder match anything
-- (it's substituted with the SSID at display time).
local function msgToPattern(msg)
    local pat = msg:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    pat = pat:gsub("%%%%1", ".-")
    return "^" .. pat .. "$"
end

-- The popups we intercept, mapped to the icon (if any) shown in their stead.
-- These must be the exact source strings used by NetworkMgr/NetworkListener/
-- NetworkSetting, so that gettext resolves them to the same translations.
local INTERCEPTED_MESSAGES = {
    { msg = _("Connecting to network %1…"), icon = ICON_CONNECTING }, -- NetworkMgr (Kindle)
    { msg = _("Connected to network %1"), icon = ICON_CONNECTED }, -- NetworkMgr, NetworkSetting
    { msg = _("Scanning for networks…"), icon = ICON_CONNECTING }, -- NetworkMgr:reconnectOrShowNetworkMenu
    { msg = _("Connection failed"), icon = ICON_DISCONNECTED }, -- NetworkMgr:reconnectOrShowNetworkMenu
    { msg = _("Error connecting to the network"), icon = ICON_DISCONNECTED }, -- NetworkMgr
    { msg = _("Unable to communicate with the Wi-Fi backend"), icon = ICON_DISCONNECTED }, -- Kindle getNetworkList
    { msg = _("Scanning for Wi-Fi networks timed out"), icon = ICON_DISCONNECTED }, -- Kindle getNetworkList
    { msg = _("Connecting to Wi-Fi…"), icon = ICON_CONNECTING },
    { msg = _("Waiting for network connectivity…"), icon = ICON_CONNECTING },
    { msg = _("Turning on Wi-Fi…"), icon = ICON_CONNECTING },
    { msg = _("Turning off Wi-Fi…") },
    { msg = _("Wi-Fi off."), icon = ICON_DISCONNECTED },
    { msg = _("Already connected to network %1."), icon = ICON_CONNECTED },
    { msg = _("Already connected."), icon = ICON_CONNECTED },
    { msg = _("You can now retry the action that required network access") },
}
for __, entry in ipairs(INTERCEPTED_MESSAGES) do
    entry.pattern = msgToPattern(entry.msg)
end

-- Module-level, so the icon and the UIManager.show patch are shared between
-- the FileManager and ReaderUI instances of the plugin.
local icon_frame
local hideIcon, showIcon

hideIcon = function()
    UIManager:unschedule(hideIcon)
    if icon_frame then
        UIManager:close(icon_frame, "ui")
        icon_frame = nil
    end
end

showIcon = function(icon_name)
    hideIcon()
    icon_frame = FrameContainer:new{
        bordersize = 0,
        padding = Size.padding.small,
        toast = true, -- transparent to input, stacked on top
        IconWidget:new{
            icon = icon_name,
            width = Screen:scaleBySize(ICON_SIZE),
            height = Screen:scaleBySize(ICON_SIZE),
            alpha = true, -- keep the icon's transparency instead of flattening onto white
        },
    }
    local margin = Screen:scaleBySize(ICON_MARGIN)
    UIManager:show(icon_frame, "ui", nil, margin, margin)
    UIManager:scheduleIn(ICON_TIMEOUT_S, hideIcon)
end

local function interceptedIcon(widget)
    if not widget or type(widget.text) ~= "string" then
        return
    end
    for __, entry in ipairs(INTERCEPTED_MESSAGES) do
        if widget.text:match(entry.pattern) then
            return entry
        end
    end
end

-- Wrap UIManager:show once, to filter out the Wi-Fi popups.
if not UIManager._wifiindicator_orig_show then
    UIManager._wifiindicator_orig_show = UIManager.show
    UIManager.show = function(self, widget, ...)
        if G_reader_settings:nilOrTrue("wifiindicator_suppress_popups") then
            local entry = interceptedIcon(widget)
            if entry then
                logger.dbg("WifiIndicator: suppressed popup:", widget.text)
                if entry.icon and G_reader_settings:nilOrTrue("wifiindicator_show_icon") then
                    showIcon(entry.icon)
                end
                return
            end
        end
        return UIManager._wifiindicator_orig_show(self, widget, ...)
    end
end

local function wifiStateIcon()
    if NetworkMgr:isConnected() then
        return ICON_CONNECTED
    elseif NetworkMgr:isWifiOn() then
        return ICON_CONNECTING
    end
    return ICON_DISCONNECTED
end

-- Wi-Fi status icon in the TouchMenu footer, left of the clock.
-- The menu is rebuilt on every open, so the setting takes effect on the
-- next open, and state is never stale.
if not TouchMenu._wifiindicator_orig_init then
    TouchMenu._wifiindicator_orig_init = TouchMenu.init
    TouchMenu.init = function(menu)
        TouchMenu._wifiindicator_orig_init(menu)
        if not G_reader_settings:nilOrTrue("wifiindicator_menu_icon") then
            return
        end
        if not menu.device_info then
            logger.warn("WifiIndicator: TouchMenu.device_info not found, skipping menu icon")
            return
        end
        local icon_size = Screen:scaleBySize(menu.fface and menu.fface.orig_size or 20)
        menu._wifiindicator_icon = IconButton:new{
            icon = wifiStateIcon(),
            width = icon_size,
            height = icon_size,
            show_parent = menu.show_parent,
            callback = function()
                -- Optimistic state; the true state is re-read on the next
                -- updateItems call or menu open.
                local turning_on = not NetworkMgr:isWifiOn()
                menu._wifiindicator_icon:setIcon(turning_on and ICON_CONNECTING or ICON_DISCONNECTED)
                UIManager:setDirty(menu.show_parent, "ui")
                UIManager:broadcastEvent(Event:new("ToggleWifi"))
            end,
        }
        table.insert(menu.device_info, 1, HorizontalSpan:new{ width = Size.span.horizontal_default })
        table.insert(menu.device_info, 1, menu._wifiindicator_icon)
        menu.device_info:resetLayout()
    end
end

if not TouchMenu._wifiindicator_orig_updateItems then
    TouchMenu._wifiindicator_orig_updateItems = TouchMenu.updateItems
    TouchMenu.updateItems = function(menu, ...)
        TouchMenu._wifiindicator_orig_updateItems(menu, ...)
        if menu._wifiindicator_icon then
            -- setIcon is a no-op when the icon name is unchanged
            menu._wifiindicator_icon:setIcon(wifiStateIcon())
        end
    end
end

local WifiIndicator = WidgetContainer:extend{
    name = "wifiindicator",
    is_doc_only = false,
}

function WifiIndicator:init()
    self.ui.menu:registerToMainMenu(self)
end

function WifiIndicator:addToMainMenu(menu_items)
    menu_items.wifi_indicator = {
        text = _("Wi-Fi status icon"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text = _("Replace Wi-Fi popups with a corner icon"),
                checked_func = function()
                    return G_reader_settings:nilOrTrue("wifiindicator_suppress_popups")
                end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("wifiindicator_suppress_popups")
                end,
            },
            {
                text = _("Show icon on connect and disconnect"),
                checked_func = function()
                    return G_reader_settings:nilOrTrue("wifiindicator_show_icon")
                end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("wifiindicator_show_icon")
                end,
            },
            {
                text = _("Show Wi-Fi status in menu bar"),
                checked_func = function()
                    return G_reader_settings:nilOrTrue("wifiindicator_menu_icon")
                end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("wifiindicator_menu_icon")
                end,
            },
        },
    }
end

-- These events are broadcast by NetworkMgr, and are what actually tells us
-- the connection state changed (the Kindle Wi-Fi restore on wakeup is
-- asynchronous, and doesn't necessarily go through any of the popups above).
function WifiIndicator:onNetworkConnected()
    if G_reader_settings:nilOrTrue("wifiindicator_show_icon") then
        showIcon(ICON_CONNECTED)
    end
    -- Don't return true: NetworkListener & co. need this event, too.
end

function WifiIndicator:onNetworkDisconnected()
    if G_reader_settings:nilOrTrue("wifiindicator_show_icon") then
        showIcon(ICON_DISCONNECTED)
    end
end

-- Don't leave a stale icon around across suspend/exit.
function WifiIndicator:onSuspend()
    hideIcon()
end

function WifiIndicator:onCloseWidget()
    hideIcon()
end

return WifiIndicator
