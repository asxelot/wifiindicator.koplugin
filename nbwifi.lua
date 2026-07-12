--[[--
Non-blocking Wi-Fi connect engine (bundled from
https://github.com/asxelot/koreader-nonblocking-wifi).

Replaces NetworkMgr:reconnectOrShowNetworkMenu() with an async state machine:
  * hardware bring-up  -> subprocess (the stock turnOnWifi runs `./enable-wifi.sh`
                          synchronously; on MTK Kobos that's ~4-5s of module loading
                          and mandated sleeps on the UI thread)
  * network scan       -> subprocess (fork + pipe, Trapper-style)
  * WPA association    -> fast synchronous setup, then 250ms status polling via
                          UIManager:scheduleIn (like restore-wifi-async.sh does with wpa_cli)
  * DHCP (obtain-ip)   -> subprocess, polled
The UI event loop keeps running the whole time, so the device stays usable.

On lipc Kindles only the scan blocks (wifid handles association + DHCP itself),
so only the scan is forked and the rest stays stock-like.

Contract notes (frontend/ui/network/manager.lua):
  * enableWifi() only aborts on a literal `false` return from turnOnWifi(); returning nil
    means "pending", so we drive completion ourselves and on failure we must call
    _abortWifiConnection() (stock code signals failure via `return false` instead).
  * complete_callback is enableWifi's connectivity_cb -> scheduleConnectivityCheck(),
    which broadcasts NetworkConnected, manages wifi_was_on and pending_connection.

Coordination: the standalone user patch and this bundled copy both set
NetworkMgr._nbwifi_installed; whichever loads first wins (user patches load before
plugins, so the patch takes precedence when both are present).

Returns { installed = <bool> } so main.lua knows whether to show the toggle.

On the SDL emulator this installs a fake slow backend + instrumentation so the engine
can be exercised in Docker (see NBWIFI_TEST harness at the bottom).
]]--

local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")

local M = { installed = false }

local TEST_MODE = Device:isSDL() and os.getenv("NBWIFI_TEST") == "1"

if NetworkMgr._nbwifi_installed then
    M.installed = NetworkMgr._nbwifi_installed == "wifiindicator"
    if not M.installed then
        logger.info("WifiIndicator: non-blocking Wi-Fi connect already installed by",
            NetworkMgr._nbwifi_installed, "- not installing the bundled copy")
        if TEST_MODE then
            local f = io.open("/config/nbwifi-test.log", "a")
            if f then f:write("PLUGIN_SKIPPED_ALREADY_INSTALLED\n") f:close() end
        end
    end
    return M
end

-- Kindle (FW 5.x, lipc): Amazon's wifid handles association + DHCP by itself after one
-- fast `ensureConnection` call; the only UI-thread blocker in stock KOReader is the scan
-- wait loop in kindleScanThenGetResults (a C.usleep poll, up to 20s -- 40s with the
-- empty-list rescan). We move the scan into a subprocess and keep the rest stock-like.
local KINDLE_LIPC = Device:isKindle() and (pcall(require, "liblipclua"))
if not TEST_MODE and not NetworkMgr.wpa_supplicant and not KINDLE_LIPC then
    return M -- nothing to fix on other platforms
end
NetworkMgr._nbwifi_installed = "wifiindicator"
M.installed = true

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local buffer = require("string.buffer")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local time = require("ui/time")
local util = require("util")
local BD = require("ui/bidi")
local _ = require("gettext")
local T = ffiutil.template
local unpack = unpack or table.unpack -- luacheck: ignore

local POLL_INTERVAL = 0.25

-- The user can flip this in the plugin menu; checked at each entry point, so it
-- takes effect on the next connection attempt, no restart needed.
local function enabled()
    return TEST_MODE or G_reader_settings:nilOrTrue("wifiindicator_nonblocking_wifi")
end

-- Any Wi-Fi teardown invalidates in-flight async steps.
local gen = 0
for _, method in ipairs({"disableWifi", "_abortWifiConnection"}) do
    local orig = NetworkMgr[method]
    NetworkMgr[method] = function(self, ...)
        gen = gen + 1
        return orig(self, ...)
    end
end

local function decodeSSID(ssid)
    local decode = function(b)
        local c = string.char(tonumber(b, 16))
        if c == "\\" then return "\\\\" end
        return c
    end
    local decoded = ssid:gsub("%f[\\]\\x(%x%x)", decode)
    return (decoded:gsub("\\\\", "\\"))
end

-- NEVER use ffiutil.readAllFromFD() here: it blocks until *every* copy of the
-- pipe's write end is closed. The wifi helper scripts spawn daemons that inherit
-- our write end (their fd-hygiene preamble closes sockets and files but skips
-- pipes) and keep it open forever: enable-wifi.sh -> `wpa_supplicant -B`,
-- obtain-ip.sh -> dhcpcd. The blocking read then hangs the UI thread for good;
-- on a real device that's a hard lock only the power button gets you out of.
-- Instead, drain only what FIONREAD reports is already in the pipe.
local function drainPipe(fd, chunks)
    while true do
        local n = ffiutil.getNonBlockingReadSize(fd)
        if not n or n <= 0 then break end
        local buf = ffi.new("char[?]", n)
        local nr = tonumber(ffi.C.read(fd, buf, n))
        if not nr or nr <= 0 then break end
        chunks[#chunks + 1] = ffi.string(buf, nr)
    end
end

-- Run task() in a forked child, deliver its return values to on_done(ok, ...)
-- without ever blocking the UI loop. on_done(false) on spawn failure or timeout.
local function subprocessCall(task, timeout_s, on_done)
    local my_gen = gen
    local pid, parent_read_fd = ffiutil.runInSubProcess(function(_, child_write_fd)
        -- Belt: don't leak our pipe into anything the task execs, so daemons
        -- spawned by the wifi scripts can't hold the write end open (see above).
        -- F_SETFD = 2, FD_CLOEXEC = 1 (POSIX; ffi.C.F_SETFD is missing in older releases)
        pcall(function() ffi.C.fcntl(child_write_fd, 2, ffi.cast("int", 1)) end)
        local results = table.pack(task())
        local ok, str = pcall(buffer.encode, results)
        if not ok then
            logger.warn("nbwifi: cannot serialize subprocess result:", str)
            str = buffer.encode({n = 0})
        end
        ffiutil.writeToFD(child_write_fd, str, true)
    end, true)
    if not pid then
        on_done(false)
        return
    end

    local chunks = {}
    local function closePipe()
        if parent_read_fd then
            ffi.C.close(parent_read_fd)
            parent_read_fd = nil
        end
    end

    -- Reap the zombie after teardown/timeout; the pipe is already closed then.
    local function collect()
        if not ffiutil.isSubProcessDone(pid) then
            UIManager:scheduleIn(1, collect)
        end
    end

    local deadline = time.monotonic() + time.s(timeout_s)
    local function check()
        if gen ~= my_gen then -- connection attempt torn down under us
            ffiutil.terminateSubProcess(pid)
            closePipe()
            UIManager:scheduleIn(1, collect)
            return
        end
        if parent_read_fd then
            -- Suspenders: consume as data comes, so a child writing a result
            -- larger than the pipe buffer can't get stuck (and thus never exit).
            drainPipe(parent_read_fd, chunks)
        end
        if ffiutil.isSubProcessDone(pid) then
            if parent_read_fd then
                drainPipe(parent_read_fd, chunks) -- catch bytes written right before exit
                closePipe()
            end
            local ret
            local data = table.concat(chunks)
            if #data > 0 then
                local ok, t = pcall(buffer.decode, data)
                if ok then ret = t end
            end
            if ret then
                on_done(true, unpack(ret, 1, ret.n))
            else
                on_done(true)
            end
        elseif time.monotonic() > deadline then
            logger.warn("nbwifi: subprocess timed out after", timeout_s, "s")
            ffiutil.terminateSubProcess(pid)
            closePipe()
            UIManager:scheduleIn(1, collect)
            on_done(false)
        else
            UIManager:scheduleIn(POLL_INTERVAL, check)
        end
    end
    UIManager:scheduleIn(POLL_INTERVAL, check)
end

-- Poll check_fn() every 250ms until it returns something truthy or timeout_s elapses.
local function pollUntil(check_fn, timeout_s, on_result)
    local my_gen = gen
    local deadline = time.monotonic() + time.s(timeout_s)
    local function tick()
        if gen ~= my_gen then return end
        local res = check_fn()
        if res then
            on_result(res)
        elseif time.monotonic() > deadline then
            on_result(nil)
        else
            UIManager:scheduleIn(POLL_INTERVAL, tick)
        end
    end
    tick()
end

-- Backend: the device-specific bits. Real wpa_supplicant on device, fakes on the emulator.
local backend = {}

if NetworkMgr.wpa_supplicant then
    local WpaClient = require("lj-wpaclient/wpaclient")
    local bin_to_hex = require("ffi/sha2").bin_to_hex
    local crypto = require("ffi/crypto")

    function backend.calcPsk(ssid, pwd)
        return bin_to_hex(crypto.pbkdf2_hmac_sha1(pwd, ssid, 4096, 32))
    end

    -- Same setup commands as WpaSupplicant:authenticateNetwork(), *without* the
    -- waitForEvent() loop: enable the network and return immediately.
    function backend.authSetup(nm, network)
        local wcli, err = WpaClient.new(nm.wpa_supplicant.ctrl_interface)
        if not wcli then return nil, err end
        local nw_id
        nw_id, err = wcli:addNetwork()
        if nw_id == nil then
            wcli:close()
            return nil, err
        end
        local reply
        reply, err = wcli:setNetwork(nw_id, "ssid", bin_to_hex(network.ssid))
        if reply == nil or reply == "FAIL" then
            wcli:removeNetwork(nw_id)
            wcli:close()
            return nil, err
        end
        if network.password and #network.password == 0 then
            reply, err = wcli:setNetwork(nw_id, "key_mgmt", "NONE")
        else
            reply, err = wcli:setNetwork(nw_id, "psk", network.psk)
        end
        if reply == nil or reply == "FAIL" then
            wcli:removeNetwork(nw_id)
            wcli:close()
            return nil, err
        end
        wcli:enableNetworkByID(nw_id)
        wcli:close()
        return nw_id
    end

    -- wpa_state == COMPLETED check; each call is a couple of fast ctrl-socket commands.
    function backend.getAssociated(nm)
        local wcli = WpaClient.new(nm.wpa_supplicant.ctrl_interface)
        if not wcli then return nil end
        local nw = wcli:getConnectedNetwork()
        wcli:close()
        if nw then nw.ssid = decodeSSID(nw.ssid) end
        return nw
    end

    function backend.authCleanup(nm, nw_id)
        local wcli = WpaClient.new(nm.wpa_supplicant.ctrl_interface)
        if not wcli then return end
        wcli:removeNetwork(nw_id)
        wcli:close()
    end

    function backend.obtainIP(nm) -- runs inside a subprocess
        nm:obtainIP()
    end
elseif KINDLE_LIPC then
    -- wifid connects (and DHCPs) on its own after ensureConnection: don't poll for
    -- association, don't run a DHCP step -- report success right away like stock and
    -- let the connectivity check (complete_callback) confirm the actual connection.
    backend.async_auth = true
    function backend.authSetup(nm, network)
        return nm:authenticateNetwork(network) and 0 or nil -- one lipc set, fast
    end
    -- No backend.calcPsk: Kindle profiles are matched by ESSID, no PSK derivation.
    -- No backend.obtainIP: DHCP is wifid's job.
    -- backend.getAssociated is never reached: getConfiguredNetworks() is nil on Kindle.
end

-- Emulator fakes: same engine, simulated slow hardware. Tunable by the test harness.
local fake_cfg = { enable_s = 5, scan_s = 2, assoc_delay_s = 6, dhcp_s = 3, auth_timeout_s = 20 }
if TEST_MODE then
    local assoc_started

    -- Stand-in for the device turnOnWifi (Kobo & co): blocking enable script, then reconnect.
    NetworkMgr.turnOnWifi = function(self, complete_callback, interactive)
        ffiutil.usleep(fake_cfg.enable_s * 1e6) -- "enable-wifi.sh": blocks whoever runs it
        -- enable-wifi.sh ends with `wpa_supplicant ... -B`: a daemon that inherits
        -- every non-CLOEXEC fd of ours (the script's fd-hygiene loop skips pipes)
        -- and never exits. Model it with a backgrounded sleep.
        os.execute("(sleep 120 >/dev/null 2>&1 &)")
        return self:reconnectOrShowNetworkMenu(complete_callback, interactive)
    end

    backend.calcPsk = function() return "00" end
    backend.authSetup = function()
        assoc_started = time.monotonic()
        return 1
    end
    backend.getAssociated = function()
        if fake_cfg.assoc_delay_s < 0 then return nil end -- simulates an AP we never join
        if assoc_started and time.monotonic() > assoc_started + time.s(fake_cfg.assoc_delay_s) then
            return { id = 1, ssid = "TestAP" }
        end
    end
    backend.authCleanup = function() end
    backend.obtainIP = function()
        -- The foreground sleep is the DHCP lease wait; the backgrounded one models
        -- obtain-ip.sh's dhcpcd daemonizing with our pipe write end still open.
        os.execute("sleep " .. tostring(fake_cfg.dhcp_s) .. "; (sleep 120 >/dev/null 2>&1 &)")
    end

    NetworkMgr.getNetworkList = function()
        ffiutil.usleep(fake_cfg.scan_s * 1e6) -- "slow scan": blocks the *subprocess* only
        return {
            { ssid = "TestAP", signal_quality = 80, flags = "[WPA2-PSK-CCMP][ESS]", password = "secret", psk = "00" },
            { ssid = "Neighbor", signal_quality = 40, flags = "[WPA2-PSK-CCMP][ESS]" },
        }
    end
    NetworkMgr.getConfiguredNetworks = function() return {} end
    NetworkMgr.saveNetwork = function() end
end

local AUTH_TIMEOUT_S = 30 -- stock waits up to ~30 x 1s events; restore-wifi-async.sh uses 15s
local SCAN_TIMEOUT_S = 30
local DHCP_TIMEOUT_S = 30
local BG_WAIT_S = 15      -- manager.lua:1196 wait-for-wpa_supplicant-background-connect

local orig_reconnectOrShowNetworkMenu = NetworkMgr.reconnectOrShowNetworkMenu
function NetworkMgr:reconnectOrShowNetworkMenu(complete_callback, interactive)
    if not enabled() then
        return orig_reconnectOrShowNetworkMenu(self, complete_callback, interactive)
    end
    local my_gen = gen
    local network_list

    local info
    local function setInfo(text)
        if info then UIManager:close(info) end
        info = text and InfoMessage:new{ text = text } or nil
        if info then UIManager:show(info) end
    end

    local function finish(success, ssid, err_msg)
        if gen ~= my_gen then return end
        setInfo(nil)
        if success then
            -- Same bookkeeping as stock (manager.lua:1216)
            self.lease_ssid = ssid
            logger.dbg("nbwifi: lease_ssid set to", ssid)
            if complete_callback then complete_callback() end
            UIManager:show(InfoMessage:new{
                tag = "NetworkMgr",
                -- Same strings as stock (manager.lua:1231): on async-auth backends the
                -- connection isn't actually up yet, we've only *started* connecting.
                text = T(_(backend.async_auth and "Connecting to network %1…" or "Connected to network %1"),
                    BD.wrap(util.fixUtf8(ssid, "�"))),
                timeout = 3,
            })
            logger.dbg("nbwifi: connected to", util.fixUtf8(ssid, "�"))
            if self.wifi_toggle_long_press then
                UIManager:show(require("ui/widget/networksetting"):new{ network_list = network_list })
            end
        else
            UIManager:show(InfoMessage:new{ text = err_msg or _("Connection failed"), timeout = 3 })
            logger.dbg("nbwifi: failed to connect:", err_msg)
            if interactive and network_list then
                UIManager:show(require("ui/widget/networksetting"):new{
                    network_list = network_list,
                    connect_callback = complete_callback,
                })
            else
                -- Stock signals failure by returning false, upon which enableWifi calls
                -- _abortWifiConnection; we already returned, so do it ourselves.
                self:_abortWifiConnection()
            end
        end
        self.wifi_toggle_long_press = nil
    end

    local function obtainIPThenFinish(ssid, network)
        if network then network.connected = true end
        if not backend.obtainIP then -- DHCP is the backend daemon's job (Kindle)
            return finish(true, ssid)
        end
        setInfo(_("Connecting to Wi-Fi…"))
        subprocessCall(function() backend.obtainIP(self) end, DHCP_TIMEOUT_S, function(ok)
            finish(ok, ssid, not ok and _("Error connecting to the network") or nil)
        end)
    end

    -- Try preferred (saved) networks sequentially, like stock pass 2 (manager.lua:1168).
    local function tryPreferred(idx)
        if gen ~= my_gen then return end
        local network, i = nil, idx
        while i <= #network_list do
            if network_list[i].password then
                network = network_list[i]
                break
            end
            i = i + 1
        end

        if not network then
            -- No (more) preferred networks: give wpa_supplicant's own global config a
            -- chance to connect in the background, like stock (manager.lua:1189).
            local configured = self:getConfiguredNetworks()
            if configured and #configured > 0 then
                setInfo(_("Waiting for network connectivity…"))
                pollUntil(function() return backend.getAssociated(self) end, BG_WAIT_S, function(nw)
                    if nw then
                        obtainIPThenFinish(nw.ssid)
                    else
                        finish(false)
                    end
                end)
            else
                finish(false)
            end
            return
        end

        logger.dbg("nbwifi: attempting to authenticate on preferred network", util.fixUtf8(network.ssid, "�"))
        setInfo(_("Authenticating…"))
        if backend.calcPsk and not network.psk then
            network.psk = backend.calcPsk(network.ssid, network.password)
            self:saveNetwork(network)
        end
        local nw_id, err = backend.authSetup(self, network)
        if not nw_id then
            logger.dbg("nbwifi: auth setup failed:", err)
            return tryPreferred(i + 1)
        end
        if backend.async_auth then
            -- The backend daemon takes it from here (Kindle wifid); stock reports
            -- success immediately and defers to the connectivity check. Same here.
            return obtainIPThenFinish(network.ssid, network)
        end
        local timeout = TEST_MODE and fake_cfg.auth_timeout_s or AUTH_TIMEOUT_S
        pollUntil(function() return backend.getAssociated(self) end, timeout, function(nw)
            if gen ~= my_gen then return end
            if nw then
                network.wpa_supplicant_id = nw.id or nw_id
                obtainIPThenFinish(network.ssid, network)
            else
                logger.dbg("nbwifi: authentication timed out on", util.fixUtf8(network.ssid, "�"))
                backend.authCleanup(self, nw_id)
                tryPreferred(i + 1)
            end
        end)
    end

    setInfo(_("Scanning for networks…"))
    local function onScan(ok, list, err)
        if gen ~= my_gen then return end
        if not ok or list == nil then
            return finish(false, nil, err)
        end
        network_list = list
        table.sort(network_list, function(l, r) return l.signal_quality > r.signal_quality end)
        -- Pass 1: wpa_supplicant may already have associated on its own (manager.lua:1154)
        for _, network in ipairs(network_list) do
            if network.connected then
                return obtainIPThenFinish(network.ssid, network)
            end
        end
        tryPreferred(1)
    end
    subprocessCall(function() return self:getNetworkList() end, SCAN_TIMEOUT_S, function(ok, list, err)
        if ok and list and #list == 0 then
            -- Stock rescans once on an empty first scan (#4387)
            logger.warn("nbwifi: initial scan empty, rescanning")
            subprocessCall(function() return self:getNetworkList() end, SCAN_TIMEOUT_S, onScan)
        else
            onScan(ok, list, err)
        end
    end)

    return nil -- "don't know yet"; we run complete_callback / _abortWifiConnection ourselves
end

-- Device turnOnWifi implementations (Kobo/Cervantes/Remarkable/Sony all follow the same
-- `os.execute(<enable script>); return self:reconnectOrShowNetworkMenu(...)` pattern) run the
-- hardware bring-up synchronously on the UI thread. On MTK Kobos (e.g. Libra Colour),
-- enable-wifi.sh contains ~3.5s of hard-coded sleeps plus module loading: that's the "first
-- 5 seconds locked" part. Fork instead: the child runs the stock turnOnWifi with the reconnect
-- step stubbed out (fork = the stub only exists in the child), the parent chains into the async
-- engine above once the script is done.
-- Not needed on Kindle: kindleEnableWifi is two fast lipc sets (the radio bring-up is
-- wifid's async business), and stock turnOnWifi chains into our reconnect by itself.
local ENABLE_TIMEOUT_S = 30

if NetworkMgr.wpa_supplicant or TEST_MODE then
    local orig_turnOnWifi = NetworkMgr.turnOnWifi
    function NetworkMgr:turnOnWifi(complete_callback, interactive)
        if not enabled() then
            return orig_turnOnWifi(self, complete_callback, interactive)
        end
        local my_gen = gen
        local info = InfoMessage:new{ text = _("Turning on Wi-Fi…") }
        UIManager:show(info)
        subprocessCall(function()
            self.reconnectOrShowNetworkMenu = function() end -- child: hardware bring-up only
            orig_turnOnWifi(self, nil, false)
        end, ENABLE_TIMEOUT_S, function(ok)
            UIManager:close(info)
            if gen ~= my_gen then return end
            if not ok then
                logger.warn("nbwifi: Wi-Fi hardware bring-up failed or timed out")
                self:_abortWifiConnection()
                UIManager:show(InfoMessage:new{ text = _("Error turning on Wi-Fi"), timeout = 3 })
                return
            end
            self:reconnectOrShowNetworkMenu(complete_callback, interactive)
        end)
        return nil -- pending: we drive completion / abort ourselves (see contract notes above)
    end
end

logger.info("WifiIndicator: non-blocking Wi-Fi connect engine installed")

-- ---------------------------------------------------------------------------
-- Emulator test harness (Docker): heartbeat + a success run and a failure run.
-- ---------------------------------------------------------------------------
if TEST_MODE then
    local LOG_PATH = "/config/nbwifi-test.log"
    os.remove(LOG_PATH)
    local function tlog(msg)
        local f = io.open(LOG_PATH, "a")
        if f then
            f:write(string.format("%.3f %s\n", time.to_s(time.monotonic()), msg))
            f:close()
        end
        logger.info("nbwifi-test:", msg)
    end

    -- Detect abort (failure path) for the log
    local orig_abort = NetworkMgr._abortWifiConnection
    NetworkMgr._abortWifiConnection = function(self, ...)
        tlog("ABORT_WIFI_CONNECTION")
        return orig_abort(self, ...)
    end

    local function heartbeat()
        tlog("HB")
        UIManager:scheduleIn(0.1, heartbeat)
    end

    tlog("PATCH_LOADED")
    UIManager:scheduleIn(1, heartbeat)

    -- Run 1: success. enable 5s -> scan 2s -> associate after 6s -> DHCP 3s => callback + "Connected"
    -- Goes through the full turnOnWifi wrapper, so the blocking fake enable step is covered too.
    UIManager:scheduleIn(5, function()
        tlog("RUN1_START (success path)")
        NetworkMgr:turnOnWifi(function() tlog("RUN1_COMPLETE_CALLBACK") end, false)
    end)

    -- Run 2: failure. enable 5s, then AP never associates, 5s auth timeout => abort, no callback
    UIManager:scheduleIn(32, function()
        fake_cfg.assoc_delay_s = -1
        fake_cfg.auth_timeout_s = 5
        tlog("RUN2_START (failure path)")
        NetworkMgr:turnOnWifi(function() tlog("RUN2_COMPLETE_CALLBACK_SHOULD_NOT_HAPPEN") end, false)
    end)

    -- Run 3: Kindle-style backend. Scan in subprocess, auth kicks off the daemon and
    -- succeeds immediately (async_auth), no PSK derivation, no DHCP step => callback.
    UIManager:scheduleIn(48, function()
        backend.async_auth = true
        backend.calcPsk = nil
        backend.obtainIP = nil
        backend.authSetup = function() return 0 end
        tlog("RUN3_START (kindle path)")
        NetworkMgr:reconnectOrShowNetworkMenu(function() tlog("RUN3_COMPLETE_CALLBACK") end, false)
    end)

    UIManager:scheduleIn(60, function() tlog("TEST_DONE") end)
end

return M
