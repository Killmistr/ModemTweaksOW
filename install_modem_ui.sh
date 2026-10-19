#!/bin/sh

echo "Installing Modem UI..."

mkdir -p /usr/lib/lua/luci/controller/
mkdir -p /usr/lib/lua/luci/view/modem/

echo "Deploying /usr/lib/lua/luci/controller/modem.lua..."
cat << \EOF > /usr/lib/lua/luci/controller/modem.lua
module("luci.controller.modem", package.seeall)

local json = require "luci.jsonc"
local sys = require "luci.sys"
local util = require "luci.util"
local uci = require "luci.model.uci".cursor()

function index()
    entry({"admin", "modem"}, firstchild(), _("Modem"), 60).dependent = false
    entry({"admin", "modem", "modeminfo"}, template("modem/modeminfo"), _("Modem Info"), 10)
    entry({"admin", "modem", "antenna"}, template("modem/antenna"), _("Setup antenna"), 15)
    entry({"admin", "modem", "sms"}, template("modem/sms"), _("SMS-managment"), 20)
    entry({"admin", "modem", "esim"}, template("modem/esim"), _("eSIM Managment"), 30)
    entry({"admin", "modem", "ussd"}, template("modem/ussd"), _("USSD-команды"), 40)
    entry({"admin", "modem", "pingcheck"}, template("modem/pingcheck"), _("Internet Status"), 50)

    -- eSIM API endpoints (adapted from epm)
    entry({"admin", "modem", "esim", "status"}, call("esim_status"), nil).leaf = true
    entry({"admin", "modem", "esim", "profiles"}, call("esim_profiles"), nil).leaf = true
    entry({"admin", "modem", "esim", "toggle"}, call("esim_toggle"), nil).leaf = true
    entry({"admin", "modem", "esim", "download"}, call("esim_download_profile"), nil).leaf = true
    entry({"admin", "modem", "esim", "delete"}, call("esim_delete_profile"), nil).leaf = true
    entry({"admin", "modem", "esim", "nickname"}, call("esim_change_nickname"), nil).leaf = true
    entry({"admin", "modem", "esim", "apn"}, call("esim_apn"), nil).leaf = true

    -- Unified Live Data API endpoint
    entry({"admin", "modem", "data"}, call("get_modem_data"), nil).leaf = true
    entry({"admin", "modem", "recovery_action"}, call("action_recovery_service"), nil).leaf = true
    
    -- Background Speedtest Traffic Generator APIs
    entry({"admin", "modem", "speedtest_start"}, call("speedtest_start"), nil).leaf = true
    entry({"admin", "modem", "speedtest_stop"}, call("speedtest_stop"), nil).leaf = true
    entry({"admin", "modem", "speedtest_status"}, call("speedtest_status"), nil).leaf = true

    -- Manual repair logging API
    entry({"admin", "modem", "log_manual_repair"}, call("log_manual_repair"), nil).leaf = true

    -- Loss logs export APIs
    entry({"admin", "modem", "get_logread"}, call("get_logread"), nil).leaf = true
    entry({"admin", "modem", "get_dmesg"}, call("get_dmesg"), nil).leaf = true
    entry({"admin", "modem", "get_combined_logs"}, call("get_combined_logs"), nil).leaf = true
    entry({"admin", "modem", "reset_usb_port"}, call("reset_usb_port"), nil).leaf = true

    -- Pingcheck APIs
    entry({"admin", "modem", "pingcheck_data"}, call("get_pingcheck_data"), nil).leaf = true
    entry({"admin", "modem", "download_bugreport"}, call("download_bugreport"), nil).leaf = true
    entry({"admin", "modem", "delete_bugreport"}, call("delete_bugreport"), nil).leaf = true
    entry({"admin", "modem", "clear_pingcheck_log"}, call("clear_pingcheck_log"), nil).leaf = true
end

-- Build env for LPAC command
function build_lpac_env()
    local env_vars = {}
    local config = {}

    -- Try to read from 'lpac' configuration first (modern openwrt style)
    local has_lpac_config = false
    uci:foreach("lpac", "global", function(s)
        config.apdu_backend = s.apdu_backend
        config.http_backend = s.http_backend
        config.apdu_debug = s.apdu_debug
        config.http_debug = s.http_debug
        has_lpac_config = true
    end)

    if has_lpac_config then
        -- Also read uqmi specific config from 'lpac' config
        uci:foreach("lpac", "uqmi", function(s)
            config.qmi_device = s.device
            config.uqmi_debug = s.debug
        end)
    else
        -- Fallback to legacy 'epm' configuration
        uci:foreach("epm", "epm", function(s)
            config = s
        end)
    end

    -- Use defaults optimized for uqmi (APDU) and curl (HTTP)
    if not config or not next(config) then
        config = {
            apdu_backend = 'uqmi',
            http_backend = 'curl',
            qmi_device = '/dev/cdc-wdm0',
            qmi_sim_slot = '1',
            mbim_device = '/dev/cdc-wdm0',
            mbim_proxy = '1',
            apdu_debug = '0',
            http_debug = '0',
            at_device = '',
            at_debug = '0'
        }
    end

    -- If defaults are partially missing, fill them in
    config.apdu_backend = config.apdu_backend or 'uqmi'
    config.http_backend = config.http_backend or 'curl'
    config.qmi_device = config.qmi_device or '/dev/cdc-wdm0'
    config.qmi_sim_slot = config.qmi_sim_slot or '1'

    -- Build environmental variables
    if config.apdu_backend then
        table.insert(env_vars, "LPAC_APDU=" .. config.apdu_backend)
    end
    if config.http_backend then
        table.insert(env_vars, "LPAC_HTTP=" .. config.http_backend)
    end

    -- Backend-specific variables
    if config.apdu_backend == 'uqmi' then
        if config.qmi_device and config.qmi_device ~= "" then
            table.insert(env_vars, "LPAC_APDU_QMI_DEVICE=" .. config.qmi_device)
        end
        if config.qmi_sim_slot and config.qmi_sim_slot ~= "" then
            table.insert(env_vars, "LPAC_APDU_QMI_UIM_SLOT=" .. config.qmi_sim_slot)
        end
        if config.uqmi_debug and config.uqmi_debug ~= '0' then
            table.insert(env_vars, "LPAC_APDU_UQMI_DEBUG=1")
        elseif config.apdu_debug and config.apdu_debug ~= '0' then
            table.insert(env_vars, "LPAC_APDU_UQMI_DEBUG=1")
        end
    elseif config.apdu_backend == 'qmi' then
        if config.qmi_device and config.qmi_device ~= "" then
            table.insert(env_vars, "LPAC_QMI_DEV=" .. config.qmi_device)
        end
    elseif config.apdu_backend == 'mbim' then
        local mbim_dev = config.mbim_device or config.qmi_device or '/dev/cdc-wdm0'
        table.insert(env_vars, "MBIM_DEVICE=" .. mbim_dev)
        local mbim_proxy = config.mbim_proxy or '1'
        table.insert(env_vars, "MBIM_USE_PROXY=" .. mbim_proxy)
    elseif config.apdu_backend == 'at' then
        if config.at_device and config.at_device ~= "" then
            table.insert(env_vars, "AT_DEVICE=" .. config.at_device)
        end
        if config.at_debug and config.at_debug ~= '0' then
            table.insert(env_vars, "AT_DEBUG=1")
        end
    end

    if config.apdu_debug and config.apdu_debug ~= '0' then
        table.insert(env_vars, "LIBEUICC_DEBUG_APDU=1")
    end
    if config.http_debug and config.http_debug ~= '0' then
        table.insert(env_vars, "LIBEUICC_DEBUG_HTTP=1")
    end

    return table.concat(env_vars, " ")
end

function exec_lpac_command(cmd_args, timeout_seconds)
    local env = build_lpac_env()
    local timeout = timeout_seconds or 30
    
    -- Auto-detect executable location
    local lpac_bin = "/usr/bin/lpac"
    local f_bin = io.open("/usr/bin/lpac", "r")
    if f_bin then
        f_bin:close()
    else
        local f_lib = io.open("/usr/lib/lpac", "r")
        if f_lib then
            lpac_bin = "/usr/lib/lpac"
            f_lib:close()
        else
            lpac_bin = "lpac"
        end
    end
    
    local full_cmd = env .. " timeout " .. timeout .. " " .. lpac_bin .. " " .. cmd_args
    local result = sys.exec(full_cmd)
    local exit_code = os.execute(full_cmd .. " >/dev/null 2>&1")
    if exit_code == 124 then return nil, "Command timed out" end
    return result
end

function esim_status()
    local result, error_msg = exec_lpac_command("chip info", 5)
    if not result then
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, error = error_msg or "Failed to execute lpac"})
        return
    end
    local data = json.parse(result)
    if data and data.type == "lpa" and data.payload and data.payload.code == 0 then
        luci.http.prepare_content("application/json")
        luci.http.write_json({
            success = true,
            eid = data.payload.data.eidValue,
            info = data.payload.data.EUICCInfo2
        })
    else
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, error = "Failed to parse eSIM info"})
    end
end

function esim_profiles()
    local result, error_msg = exec_lpac_command("profile list", 20)
    if not result then
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, error = error_msg or "Failed to execute lpac"})
        return
    end
    local data = json.parse(result)
    if data and data.type == "lpa" and data.payload and data.payload.code == 0 then
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = true, profiles = data.payload.data or {}})
    else
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, error = "Failed to parse profile list"})
    end
end

function esim_toggle()
    local iccid = luci.http.formvalue("iccid")
    local action = luci.http.formvalue("action")
    if not iccid or not action then
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, error = "Missing parameters"})
        return
    end
    local cmd_args = string.format("profile %s %s", action, util.shellquote(iccid))
    local result = exec_lpac_command(cmd_args, 30)
    if result then
        local data = json.parse(result)
        if data and data.type == "lpa" and data.payload and data.payload.code == 0 then
            -- Auto-process and remove notifications to notify carrier
            exec_lpac_command("notification process -a -r", 40)
            luci.http.prepare_content("application/json")
            luci.http.write_json({
                success = true, 
                message = "Profile " .. action .. "d successfully. Carrier notified. Recommended to verify/set APN and perform a Power Cycle reboot."
            })
        else
            luci.http.prepare_content("application/json")
            luci.http.write_json({success = false, error = data and data.payload and data.payload.message or "Failed"})
        end
    else
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, error = "Failed to execute lpac"})
    end
end

function esim_download_profile()
    local smdp_server = luci.http.formvalue("smdp_server")
    local activation_code = luci.http.formvalue("activation_code")
    local qr_code = luci.http.formvalue("qr_code")

    local cmd_args = ""
    if qr_code and qr_code ~= "" then
        cmd_args = "profile download -a " .. util.shellquote(qr_code)
    elseif smdp_server and smdp_server ~= "" and activation_code and activation_code ~= "" then
        cmd_args = "profile download -s " .. util.shellquote(smdp_server) .. " -m " .. util.shellquote(activation_code)
    else
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, error = "Provide QR code or SM-DP+ and activation code"})
        return
    end

    local result, error_msg = exec_lpac_command(cmd_args, 90)
    if result then
        local data = nil
        for line in result:gmatch("[^\r\n]+") do
            if line:match("^%s*{.*}%s*$") then
                local s, j = pcall(function() return json.parse(line:match("^%s*(.-)%s*$")) end)
                if s and j and j.type == "lpa" then data = j end
            end
        end
        
        if data and data.payload and data.payload.code == 0 then
            -- Auto-process and remove notifications to notify carrier
            exec_lpac_command("notification process -a -r", 40)
        end
        
        luci.http.prepare_content("application/json")
        if data then 
            luci.http.write_json({
                success = (data.payload.code == 0), 
                payload = data.payload,
                message = "Profile downloaded successfully. Carrier notified. Recommended to verify/set APN and perform a Power Cycle reboot."
            }) 
        else 
            luci.http.write_json({success = false, error = "Invalid LPA result"}) 
        end
    else
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, error = error_msg or "Execution failed"})
    end
end

function esim_delete_profile()
    local iccid = luci.http.formvalue("iccid")
    if not iccid then return end
    local result = exec_lpac_command("profile delete " .. util.shellquote(iccid), 30)
    local data = json.parse(result or "")
    if data and data.payload and data.payload.code == 0 then
        -- Auto-process and remove notifications to notify carrier
        exec_lpac_command("notification process -a -r", 40)
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({success = (data and data.payload and data.payload.code == 0)})
end

function esim_change_nickname()
    local iccid = luci.http.formvalue("iccid")
    local nickname = luci.http.formvalue("nickname")
    if not iccid or not nickname then return end
    local result = exec_lpac_command("profile nickname " .. util.shellquote(iccid) .. " " .. util.shellquote(nickname), 30)
    local data = json.parse(result or "")
    luci.http.prepare_content("application/json")
    luci.http.write_json({success = (data and data.payload and data.payload.code == 0)})
end

function esim_apn()
    local method = luci.http.getenv("REQUEST_METHOD")
    
    -- Find cellular interface name in UCI
    local cell_iface = nil
    uci:foreach("network", "interface", function(s)
        local proto = s.proto or ""
        local device = s.device or ""
        if proto == "qmi" or proto == "mbim" or proto == "modemmanager" or proto == "modem" or s['.name'] == "MODEM" or device:match("cdc%-wdm") then
            cell_iface = s['.name']
        end
    end)
    cell_iface = cell_iface or "MODEM"
    
    if method == "POST" then
        local apn = luci.http.formvalue("apn")
        if apn then
            apn = apn:gsub("%s+", "")
            uci:set("network", cell_iface, "apn", apn)
            -- Also set network.wan.apn if wan has qmi/mbim
            if cell_iface ~= "wan" and (uci:get("network", "wan", "proto") == "qmi" or uci:get("network", "wan", "proto") == "mbim") then
                uci:set("network", "wan", "apn", apn)
            end
            uci:commit("network")
            luci.http.prepare_content("application/json")
            luci.http.write_json({success = true, apn = apn, interface = cell_iface})
        else
            luci.http.prepare_content("application/json")
            luci.http.write_json({success = false, error = "Missing APN parameter"})
        end
    else
        -- GET method
        local apn = uci:get("network", cell_iface, "apn") or ""
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = true, apn = apn, interface = cell_iface})
    end
end

local function exec(cmd)
    local safe_cmd = cmd
    if not cmd:match("^timeout%s") then
        safe_cmd = "timeout 3 " .. cmd
    end
    local h = io.popen(safe_cmd .. " 2>/dev/null")
    if h then
        local res = h:read("*a")
        h:close()
        if res then
            res = res:gsub("\27%[[%d;]*m", "")
            return res
        end
    end
    return ""
end

local function toHex(n)
    local num = tonumber(n)
    if not num then return "-" end
    num = math.floor(num)
    if num == 0 then return "0" end
    local hexchars = "0123456789ABCDEF"
    local res = ""
    while num > 0 do
        local rem = math.floor(num % 16)
        res = string.sub(hexchars, rem + 1, rem + 1) .. res
        num = math.floor(num / 16)
    end
    return res
end

local function is_recovery_running()
    -- Check using pgrep first
    local f = io.popen("pgrep -f '[m]odem_recovery_daemon.lua' >/dev/null && echo 'yes' || echo 'no'")
    local res = f and f:read("*a")
    if f then f:close() end
    if res and res:match("yes") then
        return true
    end

    -- Fallback to standard ps -w if pgrep is not installed or returns no match
    local f2 = io.popen("ps -w | grep -v grep | grep -q '[m]odem_recovery_daemon.lua' && echo 'yes' || echo 'no'")
    local res2 = f2 and f2:read("*a")
    if f2 then f2:close() end
    return res2 and res2:match("yes") ~= nil
end

local function is_recovery_enabled()
    local f = io.popen("/etc/init.d/modem_recovery enabled && echo 'yes' || echo 'no'")
    local res = f and f:read("*a")
    if f then f:close() end
    return res and res:match("yes") ~= nil
end

function action_recovery_service()
    local act = luci.http.formvalue("action")
    local success = false
    if act == "start" then
        os.execute("/etc/init.d/modem_recovery start")
        os.execute("sleep 1")
        success = true
    elseif act == "stop" then
        os.execute("/etc/init.d/modem_recovery stop")
        os.execute("sleep 1")
        success = true
    elseif act == "enable" then
        os.execute("/etc/init.d/modem_recovery enable")
        os.execute("sleep 1")
        success = true
    elseif act == "disable" then
        os.execute("/etc/init.d/modem_recovery disable")
        os.execute("sleep 1")
        success = true
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({success = success})
end

function get_modem_data()
    -- Read recovery metrics if available
    local recovery_metrics = {}
    local mf = io.open("/tmp/modem_recovery_metrics.json", "r")
    if mf then
        local content = mf:read("*a")
        mf:close()
        if content then
            local success, parsed = pcall(json.parse, content)
            if success and type(parsed) == "table" then
                recovery_metrics = parsed
            end
        end
    end

    -- Check if any modem is present
    local m_list = exec("mmcli -L") or ""
    local has_modem = (m_list:match("ModemManager1/Modem/(%d+)") ~= nil)
    
    if not has_modem then
        local speed_data = {rx_speed = 0, tx_speed = 0, history = {}, loadavg = 0, load_history = {}}
        local s_f = io.open("/tmp/modem_speed.json", "r")
        if s_f then
            local content = s_f:read("*a")
            s_f:close()
            local success, parsed = pcall(json.parse, content)
            if success and type(parsed) == "table" then
                speed_data = parsed
            end
        end

        luci.http.prepare_content("application/json")
        luci.http.write_json({
            success = true,
            has_modem = false,
            state_str = "Отсутствует",
            plmn_display = "Нет сети",
            uptime_str = "-",
            ip_addr = "-",
            rx_mb = "0",
            tx_mb = "0",
            total_mb = "0",
            recovery_metrics = recovery_metrics,
            recovery_daemon_running = is_recovery_running(),
            recovery_daemon_enabled = is_recovery_enabled(),
            speed = speed_data
        })
        return
    end

    -- 1. Scan QMI devices
    local wdm_devs = {}
    local ls_h = io.popen("ls /dev/cdc-wdm* 2>/dev/null")
    if ls_h then
        for line in ls_h:lines() do table.insert(wdm_devs, line) end
        ls_h:close()
    end
    if #wdm_devs == 0 then table.insert(wdm_devs, "/dev/cdc-wdm0") end

    local qmi_dev = luci.http.formvalue("qmi_dev") or wdm_devs[1]
    
    -- Always use QMI proxy to avoid protocol conflicts with ModemManager
    local qmi_cmd = "timeout 3 qmicli -d " .. qmi_dev .. " -p "
    local qmi_test = exec("timeout 1 qmicli -d " .. qmi_dev .. " -p --nas-get-signal-info") or ""
    local is_qmi_responsive = true
    if qmi_test:match("error:") or qmi_test == "" then
        is_qmi_responsive = false
    end

    -- 2. Find MMCLI index
    local mmcli_idx = "any"
    local port_match = qmi_dev:match("cdc%-wdm%d+")
    for id in m_list:gmatch("ModemManager1/Modem/(%d+)") do
        local chk_m = exec("mmcli -m " .. id) or ""
        local matched_port = chk_m:match("(cdc%-wdm%d+)")
        if matched_port then
            if port_match and matched_port == port_match then
                mmcli_idx = id
            end
        end
    end

    local mm_cmd = "mmcli -m " .. mmcli_idx
    local mmcli_out = exec(mm_cmd) or ""

    local active_sim_current = "1"
    local uim_out = exec(qmi_cmd .. "--uim-get-card-status") or ""
    local active_slot = uim_out:match("Primary GW:%s*slot%s*'([1-9]%d*)'")
    if active_slot then
        active_sim_current = active_slot
    else
        active_sim_current = mmcli_out:match("slot (%d+):[^\n]*%(active%)") or "1"
    end
    
    local modes_full = mmcli_out:match("Modes.-|%s*(.-)\n%s*%-%-%-%-%-") or mmcli_out:match("Modes.-|%s*(.*)") or ""
    local current_rat_str = "Auto"
    local curr_a, curr_p = nil, nil
    local curr_val_current = "any"
    
    local modes_block = ""
    if modes_full ~= "" then
        modes_block = modes_full:match("supported:%s*(.-)current:") or modes_full
        current_rat_str = modes_full:match("current:%s*([^\n\r]+)") or "Auto"
        curr_a = current_rat_str:match("allowed:%s*([^;]+)")
        curr_p = current_rat_str:match("preferred:%s*([a-z0-9]+)")
        if curr_a and curr_p then
            curr_val_current = curr_a:gsub(",%s*", "|"):gsub("%s+", "") .. ":" .. curr_p
        end
    end

    local uptime_str = "-"
    local uptime_sec = exec("ubus call network.interface dump | jsonfilter -e '@.interface[@.interface=\"MODEM\"].uptime' 2>/dev/null") or ""
    uptime_sec = uptime_sec:gsub("%s+", "")
    if uptime_sec ~= "" and tonumber(uptime_sec) then
        local s = tonumber(uptime_sec)
        local d = math.floor(s / 86400)
        local h = math.floor((s % 86400) / 3600)
        local m = math.floor((s % 3600) / 60)
        local r_s = s % 60
        if d > 0 then
            uptime_str = string.format("%dd %dh %dm %ds", d, h, m, r_s)
        elseif h > 0 then
            uptime_str = string.format("%dh %dm %ds", h, m, r_s)
        else
            uptime_str = string.format("%dm %ds", m, r_s)
        end
    end

    local qmi_sig_info = ""
    local qmi_band = ""
    local qmi_loc = ""
    local qmi_ca = ""
    local qmi_sys = ""
    local qmi_txrx = ""

    if is_qmi_responsive then
        qmi_sig_info = (qmi_cmd:match("-p ") and qmi_test ~= "" and qmi_test) or exec(qmi_cmd .. "--nas-get-signal-info") or ""
        qmi_band = exec(qmi_cmd .. "--nas-get-rf-band-info") or ""
        qmi_loc = exec(qmi_cmd .. "--nas-get-cell-location-info") or ""
        qmi_ca = exec(qmi_cmd .. "--nas-get-lte-cphy-ca-info") or ""
        qmi_sys = exec(qmi_cmd .. "--nas-get-system-info") or ""
        qmi_txrx = exec(qmi_cmd .. "--nas-get-tx-rx-info=lte") or ""
    end

    local net_iface = mmcli_out:match("net.-ports:%s*([a-zA-Z0-9%-_]+)") or "wwan0"
    local ifconfig_out = exec("ifconfig " .. net_iface) or ""
    
    local rx_mb_str = ifconfig_out:match("RX:%s*(%d+%.%d+)%s*MB") or ifconfig_out:match("RX bytes:%s*.-%((%d+%.%d+)%s*MB%)")
    local tx_mb_str = ifconfig_out:match("TX:%s*(%d+%.%d+)%s*MB") or ifconfig_out:match("TX bytes:%s*.-%((%d+%.%d+)%s*MB%)")
    
    local rx_mb, tx_mb, total_mb = "0.0", "0.0", "0.0"
    if rx_mb_str and tx_mb_str then
        rx_mb = string.format("%.1f", tonumber(rx_mb_str))
        tx_mb = string.format("%.1f", tonumber(tx_mb_str))
        total_mb = string.format("%.1f", tonumber(rx_mb_str) + tonumber(tx_mb_str))
    else
        local rx_bytes = ifconfig_out:match("RX bytes:(%d+)") or ifconfig_out:match("RX packets.-bytes%s+(%d+)") or "0"
        local tx_bytes = ifconfig_out:match("TX bytes:(%d+)") or ifconfig_out:match("TX packets.-bytes%s+(%d+)") or "0"
        rx_mb = string.format("%.1f", tonumber(rx_bytes) / 1048576)
        tx_mb = string.format("%.1f", tonumber(tx_bytes) / 1048576)
        total_mb = string.format("%.1f", (tonumber(rx_bytes) + tonumber(tx_bytes)) / 1048576)
    end
    
    local ip_addr = ifconfig_out:match("inet addr:([0-9%.]+)") or ifconfig_out:match("inet%s+([0-9%.]+)") or "-"
    local state_str = mmcli_out:match("state:%s*([^\n]+)") or "-"
    local failed_reason = mmcli_out:match("failed reason:%s*([^\n]+)")
    if failed_reason then
        state_str = state_str .. " (Failed: " .. failed_reason .. ")"
    end
    local access_tech = mmcli_out:match("access tech:%s*([^%c]+)")
    if access_tech then state_str = state_str .. " (" .. access_tech .. ")" end

    local sim_path = mmcli_out:match("SIM.-path:%s*([^\n]+)") or ""
    local sim_idx = sim_path:match("SIM/(%d+)")
    local sim_out = exec("mmcli -i " .. (sim_idx or "any")) or ""
    local hw_imsi = sim_out:match("imsi:%s*(%d+)") or "-"
    
    local hw_phone = mmcli_out:match("Numbers.-own:%s*([^\n]+)") or "-"
    local op_id = mmcli_out:match("operator id:%s*(%d+)") or ""
    local op_name = mmcli_out:match("operator name:%s*([^\n]+)") or ""
    local plmn_display = "-"
    if op_id ~= "" and op_name ~= "" then
        plmn_display = op_id .. " (" .. op_name .. ")"
    elseif op_id ~= "" then
        plmn_display = op_id
    else
        plmn_display = qmi_loc:match("PLMN: '([^']+)'") or "-"
    end

    local hw_manuf = mmcli_out:match("manufacturer:%s*([^\n]+)") or "-"
    local hw_model = mmcli_out:match("model:%s*([^\n]+)") or "-"
    local hw_rev = mmcli_out:match("h/w revision:%s*([^\n]+)") or "-"
    local hw_imei = mmcli_out:match("equipment id:%s*([a-zA-Z0-9]+)") or "-"
    local hw_fw = mmcli_out:match("firmware revision:%s*(.-)\n%s*|%s*[a-z]")
    if hw_fw then hw_fw = hw_fw:gsub("\n%s*|%s*", " "):gsub("%s+", " ") else hw_fw = mmcli_out:match("firmware revision:%s*([^\n]+)") or "-" end
    
    local nsa_avail_init = qmi_sys:lower():match("5g nsa available:%s*'?([%w%+%-]+)'?") or "-"
    local nsa_display_init = "Нет"
    if nsa_avail_init:lower() == "yes" then nsa_display_init = "Yes" end

    local is_umts = false
    local umts_cid = qmi_loc:match("UMTS Cell ID: '(%d+)'")
    if umts_cid or (access_tech and (access_tech:match("umts") or access_tech:match("hspa") or access_tech:match("hsdpa") or access_tech:match("hsupa"))) then is_umts = true end

    local tac_dec = qmi_loc:match("Tracking Area Code: '(%d+)'") or qmi_loc:match("Location Area Code: '(%d+)'")
    local tac_str = "-"
    if tac_dec then tac_str = tac_dec .. " (" .. toHex(tac_dec) .. ")" end

    local gcid_dec = qmi_loc:match("Global Cell ID: '(%d+)'")
    local gcid_hex, enb_dec, enb_hex, cid_dec, cid_hex = "-", "-", "-", "-", "-"
    
    if gcid_dec then
        local dec = tonumber(gcid_dec)
        gcid_hex = toHex(dec)
        enb_dec = tostring(math.floor(dec / 256))
        enb_hex = toHex(math.floor(dec / 256))
        cid_dec = tostring(math.floor(dec % 256))
        cid_hex = toHex(math.floor(dec % 256))
    elseif umts_cid then
        gcid_dec = umts_cid
        gcid_hex = toHex(tonumber(umts_cid))
        local cell_id = qmi_loc:match("Cell ID: '(%d+)'")
        if cell_id then
            cid_dec = cell_id
            cid_hex = toHex(tonumber(cell_id))
        end
    else
        gcid_dec = "-"
    end

    local plmn_num = op_id
    if not plmn_num or plmn_num == "" then
        local qmi_plmn = qmi_loc:match("PLMN: '([^']+)'")
        if qmi_plmn then
            plmn_num = qmi_plmn:gsub("%D", "")
        end
    end
    if plmn_num == "" or plmn_num == "-" then plmn_num = nil end

    if plmn_num then
        if #plmn_num < 6 then
            local mcc = plmn_num:sub(1, 3)
            local mnc = plmn_num:sub(4)
            while #mnc < 3 do
                mnc = "0" .. mnc
            end
            plmn_num = mcc .. mnc
        end
        local plmn_replacements = {
            ["250011"] = "250002"
        }
        if plmn_replacements[plmn_num] then
            plmn_num = plmn_replacements[plmn_num]
        end
    end

    local tech_num = nil
    local num_val = nil
    local include_lac = false
    local a_tech = access_tech and access_tech:lower() or ""
    local is_nsa = false
    if nsa_display_init == "Yes" or nsa_display_init == "yes" then
        is_nsa = true
    end

    if (a_tech:match("5g") or a_tech:match("nr")) and not is_nsa then
        tech_num = 4
        local nr_cid_dec = qmi_loc:match("NR5G Cell ID: '(%d+)'")
        if not nr_cid_dec then
            local nr_block = qmi_loc:match("NR5G Cell Info(.-)%-") or qmi_loc:match("NR5G Cell Info(.*)")
            if nr_block then
                nr_cid_dec = nr_block:match("Cell ID: '(%d+)'")
            end
        end
        if nr_cid_dec then
            local dec = tonumber(nr_cid_dec)
            if dec then
                num_val = tostring(math.floor(dec / 4096))
            end
        end
    elseif a_tech:match("lte") or is_nsa then
        tech_num = 3
        if enb_dec and enb_dec ~= "-" and enb_dec ~= "" then
            num_val = enb_dec
        end
    elseif a_tech:match("umts") or a_tech:match("hsp") or a_tech:match("wcdma") or is_umts then
        tech_num = 2
        if cid_dec and cid_dec ~= "-" and cid_dec ~= "" then
            num_val = cid_dec
        end
        include_lac = true
    elseif a_tech:match("gsm") or a_tech:match("gprs") or a_tech:match("edge") then
        tech_num = 1
        if cid_dec and cid_dec ~= "-" and cid_dec ~= "" then
            num_val = cid_dec
        end
        include_lac = true
    else
        if is_umts then
            tech_num = 2
            num_val = cid_dec
            include_lac = true
        elseif enb_dec and enb_dec ~= "-" and enb_dec ~= "" then
            tech_num = 3
            num_val = enb_dec
        end
    end

    local fourcells_url = ""
    if plmn_num and tech_num and num_val and num_val ~= "-" and num_val ~= "" then
        fourcells_url = "https://4cells.ru/?plmn=" .. plmn_num .. "&tech=" .. tech_num .. "&num=" .. num_val
        if include_lac and tac_dec and tac_dec ~= "" and tac_dec ~= "-" then
            fourcells_url = fourcells_url .. "&lac=" .. tac_dec
        end
    end

    local serv_pci = qmi_loc:match("Serving Cell ID: '(%d+)'") or qmi_loc:match("Primary Scrambling Code: '(%d+)'") or "-"
    
    local ta_match = qmi_loc:match("LTE Timing Advance: '(%d+)'")
    local ta_text = "-"
    if ta_match then
        local ta_dist = math.floor(tonumber(ta_match) * 78.12)
        ta_text = ta_match .. " (~" .. ta_dist .. " m)"
    elseif qmi_loc:match("unavailable") then
        ta_text = "Обновите страницу и/или начните передачу данных для отображения"
    end

    local lte_rssi = qmi_sig_info:match("LTE:.-RSSI:%s*'([^']+)'") or "-"
    local lte_rsrq = qmi_sig_info:match("LTE:.-RSRQ:%s*'([^']+)'") or "-"
    local lte_rsrp = qmi_sig_info:match("LTE:.-RSRP:%s*'([^']+)'") or "-"
    local lte_snr  = qmi_sig_info:match("LTE:.-SNR:%s*'([^']+)'") or "-"

    local umts_rscp = qmi_sig_info:match("UMTS:.-RSCP:%s*'([^']+)'") or qmi_loc:match("RSCP: '(%-?%d+)'")
    local umts_ecio = qmi_sig_info:match("UMTS:.-ECIO:%s*'([^']+)'") or qmi_loc:match("ECIO: '(%-?%d+)'")

    if is_umts and umts_rscp then
        lte_rsrp = umts_rscp
        lte_rsrq = umts_rscp
        if umts_ecio then lte_snr = umts_ecio else lte_snr = "-" end
    end

    local nr_rsrp = qmi_sig_info:match("5G:.-RSRP:%s*'?([^'\r\n]+)'?") or "-"
    local nr_snr  = qmi_sig_info:match("5G:.-S[IN]*R:%s*'?([^'\r\n]+)'?") or "-"
    local nr_rsrq = qmi_sig_info:match("5G:.-RSRQ:%s*'?([^'\r\n]+)'?") or "-"
    
    if nr_rsrp == "-" then nr_rsrp = "n/a" end
    if nr_rsrq == "-" then nr_rsrq = "n/a" end
    if nr_snr == "-" then nr_snr = "n/a" end

    local serv_band = qmi_ca:match("Primary Cell Info.-LTE Band: 'eutran%-([^']+)'") or qmi_band:match("Active Band Class:%s*'eutran%-([^']+)'") or "-"
    local serv_earfcn = qmi_ca:match("Primary Cell Info.-RX Channel: '([^']+)'") or qmi_band:match("Active Band Class:%s*'eutran%-[^']+'[%s\r\n]+Active Channel:%s*'([^']+)'") or "-"
    local serv_bw = qmi_ca:match("Primary Cell Info.-DL Bandwidth: '([^']+)'") or qmi_band:match("Radio Interface:%s*'lte'[%s\r\n]+Bandwidth:%s*'([^']+)'") or "-"
    
    if serv_band == "-" and is_umts then
        serv_earfcn = qmi_loc:match("UTRA Absolute RF Channel Number: '(%d+)'") or "-"
        serv_bw = "5"
        
        local wb = qmi_band:match("Active Band Class:%s*'wcdma%-([^']+)'")
        if wb then
            if wb == "2100" then serv_band = "1"
            elseif wb == "900" then serv_band = "8"
            elseif wb == "850" then serv_band = "5"
            elseif wb == "1900" then serv_band = "2"
            elseif wb == "1800" then serv_band = "3"
            else serv_band = wb end
        else
            serv_band = qmi_band:match("Active Band Class:%s*'utran%-([^']+)'") or "-"
        end
    end
    if serv_bw:match("null") then serv_bw = "Unknown" end

    local nr_band = qmi_band:match("Active Band Class:%s*'nr5g%-([^']+)'") or "-"
    local nr_arfcn = qmi_band:match("Active Band Class:%s*'nr5g%-[^']+'[%s\r\n]+Active Channel:%s*'([^']+)'") or "-"
    local nr_bw = qmi_band:match("Radio Interface:%s*'5gnr'[%s\r\n]+Bandwidth:%s*'([^']+)'") or "-"
    if nr_bw:match("null") then nr_bw = "Unknown" end

    local lte_percent = 0
    local lte_rp_num = tonumber((lte_rsrp:match("%-?%d+%.?%d*")))
    if lte_rp_num and lte_rp_num < 0 then lte_percent = math.floor((lte_rp_num + 125) * (100 / 50)) end
    if lte_percent < 0 then lte_percent = 0 elseif lte_percent > 100 then lte_percent = 100 end

    local lte_snr_percent = 0
    local lte_snr_num = tonumber((lte_snr:match("%-?%d+%.?%d*")))
    if lte_snr_num then
        lte_snr_percent = math.floor((lte_snr_num + 5) * (100 / 30))
        if lte_snr_percent < 0 then lte_snr_percent = 0 elseif lte_snr_percent > 100 then lte_snr_percent = 100 end
    end

    local nr_percent = 0
    local nr_rp_num = tonumber((nr_rsrp:match("%-?%d+%.?%d*")))
    if nr_rp_num and nr_rp_num < 0 then nr_percent = math.floor((nr_rp_num + 125) * (100 / 50)) end
    if nr_percent < 0 then nr_percent = 0 elseif nr_percent > 100 then nr_percent = 100 end

    local tx_power = qmi_txrx:match("TX:.-Power: '([^']+)'") or "Обновите страницу и/или начните передачу данных для отображения"
    local rx_chains = {}
    for ch, chunk in qmi_txrx:gmatch("RX Chain (%d+):(.-)Phase:") do
        local pwr = chunk:match("Power: '([^']+)'") or "-"
        local ec = chunk:match("ECIO: '([^']+)'") or "-"
        local rp = chunk:match("RSRP: '([^']+)'") or "-"
        table.insert(rx_chains, {chain=ch, pwr=pwr, ec=ec, rp=rp})
    end

    local ca_info = {}
    for chunk in qmi_ca:gmatch("Secondary Cell %d+ Info(.-)Cell index:") do
        local pci = chunk:match("Physical Cell ID: '([^']+)'")
        local rx = chunk:match("RX Channel: '([^']+)'") or "-"
        local bw = chunk:match("DL Bandwidth: '([^']+)'") or "-"
        local bnd = chunk:match("LTE Band: 'eutran%-([^']+)'") or "-"
        local st = chunk:match("State: '([^']+)'") or "-"
        if pci then table.insert(ca_info, {band=bnd, earfcn=rx, bw=bw, pci=pci, state=st}) end
    end

    local neighbours = {}
    local intra_earfcn = qmi_loc:match("Intrafrequency LTE Info.-EUTRA Absolute RF Channel Number: '(%d+)'") or "0"
    local intra_info = qmi_loc:match("Intrafrequency LTE Info(.-)Interfrequency") or qmi_loc:match("Intrafrequency LTE Info(.*)") or ""
    
    for p, rq, rp, ri in intra_info:gmatch("Physical Cell ID: '(%d+)'.-RSRQ: '([^']+)'.-RSRP: '([^']+)'.-RSSI: '([^']+)'") do
        if p ~= serv_pci then table.insert(neighbours, {e=intra_earfcn, pci=p, rq=rq, rp=rp, ri=ri}) end
    end

    local inter_info = qmi_loc:match("Interfrequency LTE Info(.-)LTE Info") or qmi_loc:match("Interfrequency LTE Info(.*)") or ""
    local freqs = {}
    local s = 1
    while true do
        local start_f, end_f = inter_info:find("Frequency %[%d+%]:", s)
        if not start_f then table.insert(freqs, inter_info:sub(s)); break end
        if s < start_f then table.insert(freqs, inter_info:sub(s, start_f - 1)) end
        s = start_f
        local next_start = inter_info:find("Frequency %[%d+%]:", end_f)
        if next_start then table.insert(freqs, inter_info:sub(start_f, next_start - 1)); s = next_start
        else table.insert(freqs, inter_info:sub(start_f)); break end
    end

    for _, f_chunk in ipairs(freqs) do
        local e_freq = f_chunk:match("EUTRA Absolute RF Channel Number: '(%d+)'") or "0"
        for p, rq, rp, ri in f_chunk:gmatch("Physical Cell ID: '(%d+)'.-RSRQ: '([^']+)'.-RSRP: '([^']+)'.-RSSI: '([^']+)'") do
            table.insert(neighbours, {e=e_freq, pci=p, rq=rq, rp=rp, ri=ri})
        end
    end
    table.sort(neighbours, function(a,b)
        local ea, eb = tonumber(a.e) or 0, tonumber(b.e) or 0
        local ra = tonumber(a.ri:match("%-?%d+%.?%d*")) or -999
        local rb = tonumber(b.ri:match("%-?%d+%.?%d*")) or -999
        if ea == eb then return ra > rb else return ea < eb end
    end)

    -- Match aggregated sectors with neighboring cells to extract RSRP, RSRQ, and RSSI/SINR
    for _, ca in ipairs(ca_info) do
        local matched_rsrp = "-"
        local matched_rsrq = "-"
        local matched_rssi = "-"
        local ca_earfcn = ca.earfcn:gsub("%s+", "")
        local ca_pci = ca.pci:gsub("%s+", "")
        
        for _, nb in ipairs(neighbours) do
            local nb_earfcn = nb.e:gsub("%s+", "")
            local nb_pci = nb.pci:gsub("%s+", "")
            if nb_earfcn == ca_earfcn and nb_pci == ca_pci then
                matched_rsrp = nb.rp or "-"
                matched_rsrq = nb.rq or "-"
                matched_rssi = nb.ri or "-"
                break
            end
        end
        ca.rsrp = matched_rsrp
        ca.rsrq = matched_rsrq
        ca.rssi = matched_rssi
    end

    -- Read CPU & WiFi temperatures
    local function get_cmd_output(cmd)
        local f = io.popen(cmd)
        if f then
            local res = f:read("*a")
            f:close()
            if res then
                res = res:gsub("^%s*", ""):gsub("%s*$", ""):gsub("[\r\n]", " ")
                if res ~= "" then return res end
            end
        end
        return "-"
    end

    local router_cpu_temp = get_cmd_output("awk '{print $1/1000 \" °C\"}' /sys/class/thermal/thermal_zone*/temp 2>/dev/null")
    if router_cpu_temp == "-" then
        router_cpu_temp = get_cmd_output("cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null")
        if router_cpu_temp ~= "-" then
            local val = tonumber(router_cpu_temp)
            if val then router_cpu_temp = string.format("%.1f °C", val / 1000) end
        end
    end

    local router_wifi_temp = get_cmd_output("awk '{print $1/1000 \" °C\"}' /sys/class/ieee80211/phy*/hwmon*/temp1_input 2>/dev/null")

    -- Read speed history
    local speed_data = {rx_speed = 0, tx_speed = 0, history = {}, loadavg = 0, load_history = {}}
    local s_f = io.open("/tmp/modem_speed.json", "r")
    if s_f then
        local content = s_f:read("*a")
        s_f:close()
        local success, parsed = pcall(json.parse, content)
        if success and type(parsed) == "table" then
            speed_data = parsed
        end
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true,
        has_modem = true,
        recovery_metrics = recovery_metrics,
        recovery_daemon_running = is_recovery_running(),
        recovery_daemon_enabled = is_recovery_enabled(),
        wdm_devs = wdm_devs,
        qmi_dev = qmi_dev,
        mmcli_idx = mmcli_idx,
        active_sim_current = active_sim_current,
        uptime_str = uptime_str,
        state_str = state_str,
        rx_mb = rx_mb,
        tx_mb = tx_mb,
        total_mb = total_mb,
        ip_addr = ip_addr,
        plmn_display = plmn_display,
        is_umts = is_umts,
        tac_str = tac_str,
        gcid_dec = gcid_dec,
        gcid_hex = gcid_hex,
        enb_dec = enb_dec,
        enb_hex = enb_hex,
        cid_dec = cid_dec,
        cid_hex = cid_hex,
        serv_pci = serv_pci,
        ta_text = ta_text,
        lte_rsrp = lte_rsrp,
        lte_rsrq = lte_rsrq,
        lte_snr = lte_snr,
        lte_percent = lte_percent,
        lte_snr_percent = lte_snr_percent,
        fourcells_url = fourcells_url,
        nr_rsrp = nr_rsrp,
        nr_rsrq = nr_rsrq,
        nr_snr = nr_snr,
        nr_percent = nr_percent,
        nsa_display_init = nsa_display_init,
        serv_band = serv_band,
        serv_earfcn = serv_earfcn,
        serv_bw = serv_bw,
        nr_band = nr_band,
        nr_arfcn = nr_arfcn,
        nr_bw = nr_bw,
        tx_power = tx_power,
        rx_chains = rx_chains,
        ca_info = ca_info,
        neighbours = neighbours,
        speed = speed_data,
        hw_manuf = hw_manuf,
        hw_model = hw_model,
        hw_rev = hw_rev,
        hw_fw = hw_fw,
        hw_imei = hw_imei,
        hw_imsi = hw_imsi,
        hw_phone = hw_phone,
        router_cpu_temp = router_cpu_temp,
        router_wifi_temp = router_wifi_temp
    })
end

function speedtest_start()
    local url = luci.http.formvalue("url")
    if not url or url == "" then
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, error = "URL is missing"})
        return
    end

    -- Sanitize URL to protect against command injection
    url = url:gsub("[^%w%./%:%?%=%&%-%_%%]", "")

    if not url:match("^https?://") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = false, error = "Invalid URL protocol"})
        return
    end

    -- Terminate any running speedtest first
    os.execute("kill $(cat /var/run/speedtest_wget.pid) 2>/dev/null; pkill -f 'wget -O /dev/null'; rm -f /var/run/speedtest_wget.pid")

    -- Start wget in the background and write PID
    local cmd = string.format("wget -O /dev/null '%s' >/dev/null 2>&1 & echo $! > /var/run/speedtest_wget.pid", url)
    os.execute(cmd)

    luci.http.prepare_content("application/json")
    luci.http.write_json({success = true})
end

function speedtest_stop()
    os.execute("kill $(cat /var/run/speedtest_wget.pid) 2>/dev/null; pkill -f 'wget -O /dev/null'; rm -f /var/run/speedtest_wget.pid")
    luci.http.prepare_content("application/json")
    luci.http.write_json({success = true})
end

function speedtest_status()
    local sys = require "luci.sys"
    local pids = sys.exec("pgrep -lf 'wget -O /dev/null' | grep -v -E 'pgrep|sh|bash'") or ""
    local running = (pids ~= "")
    luci.http.prepare_content("application/json")
    luci.http.write_json({success = true, running = running})
end

function log_manual_repair()
    os.execute("echo REPAIRED_MANUALLY >> system_history.log")
    os.execute("echo REPAIRED_MANUALLY >> system_history.log")
    os.execute("echo REPAIRED_MANUALLY >> system_history.log")
    luci.http.prepare_content("application/json")
    luci.http.write_json({success = true})
end

function get_logread()
    local sys = require "luci.sys"
    local data = sys.exec("logread") or ""
    local datetime = os.date("%Y-%m-%d_%H-%M-%S")
    local filename = string.format("logread_loss_inet_%s.txt", datetime)
    
    local f = io.open("/tmp/" .. filename, "w")
    if f then
        f:write(data)
        f:close()
    end
    
    luci.http.header("Content-Disposition", "attachment; filename=\"" .. filename .. "\"")
    luci.http.prepare_content("text/plain; charset=utf-8")
    luci.http.write(data)
end

function get_dmesg()
    local sys = require "luci.sys"
    local data = sys.exec("dmesg") or ""
    local datetime = os.date("%Y-%m-%d_%H-%M-%S")
    local filename = string.format("dmesg_loss_inet_%s.txt", datetime)
    
    local f = io.open("/tmp/" .. filename, "w")
    if f then
        f:write(data)
        f:close()
    end
    
    luci.http.header("Content-Disposition", "attachment; filename=\"" .. filename .. "\"")
    luci.http.prepare_content("text/plain; charset=utf-8")
    luci.http.write(data)
end

function reset_usb_port()
    -- Dynamic discovery of target USB device for cellular modem
    local dev_dir = nil
    local p = io.popen("grep -l -E 'VOS_5G|Tri Cascade' /sys/bus/usb/devices/*/product 2>/dev/null")
    if p then
        local filepath = p:read("*l")
        p:close()
        if filepath then
            dev_dir = filepath:match("(/sys/bus/usb/devices/[a-zA-Z0-9%.%-]+)/product")
        end
    end

    if not dev_dir then
        -- Fallback to physical hardware port
        local f_test = io.open("/sys/bus/usb/devices/2-1.4/authorized")
        if f_test then
            f_test:close()
            dev_dir = "/sys/bus/usb/devices/2-1.4"
        end
    end

    local success = false
    if dev_dir then
        os.execute("logger -t luci 'Cellular Modem USB hardware reset triggered via Web UI on port: " .. dev_dir .. "'")
        
        -- Stop services and kill active port locks cleanly!
        os.execute("killall -9 qmicli mbimcli mbim-proxy qmi-proxy 2>/dev/null")
        os.execute("/etc/init.d/modemmanager stop")
        os.execute("sleep 1")
        
        -- Perform physical USB power-down
        os.execute("echo 0 > " .. dev_dir .. "/authorized")
        os.execute("sleep 6")
        os.execute("echo 1 > " .. dev_dir .. "/authorized")
        
        -- Restart ModemManager
        os.execute("/etc/init.d/modemmanager start")
        success = true
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({success = success, dev_dir = dev_dir})
end

function get_combined_logs()
    local sys = require "luci.sys"
    local dmesg_data = sys.exec("dmesg") or ""
    local logread_data = sys.exec("logread") or ""
    
    local divider = "\n\n=================================================================\n"
                 .. "=== SYSTEM LOGREAD OUTPUT =======================================\n"
                 .. "=================================================================\n\n"
                 
    local data = "=================================================================\n"
              .. "=== KERNEL DMESG OUTPUT =========================================\n"
              .. "=================================================================\n\n"
              .. dmesg_data .. divider .. logread_data
              
    local datetime = os.date("%Y-%m-%d_%H-%M-%S")
    local filename = string.format("logread_loss_inet_%s.txt", datetime)
    
    local f = io.open("/tmp/" .. filename, "w")
    if f then
        f:write(data)
        f:close()
    end
    
    luci.http.header("Content-Disposition", "attachment; filename=\"" .. filename .. "\"")
    luci.http.prepare_content("text/plain; charset=utf-8")
    luci.http.write(data)
end

function get_pingcheck_data()
    local log_data = {}
    local last_check_time = nil
    local f = io.open("/tmp/pingcheck.log", "r")
    if f then
        local prev_state = nil
        local first_line = nil
        local last_line = nil
        
        for line in f:lines() do
            local ts, msg = line:match("^([^|]+)%s*|%s*(.*)$")
            if ts and msg then
                ts = ts:gsub("%s*$", "")
                local state, rest = msg:match("^([^|]+)%s*|%s*(.*)$")
                if not state then
                    state = msg
                    rest = ""
                else
                    state = state:gsub("%s*$", "")
                end
                
                -- Normalize state to detect transitions
                local state_lower = state:lower()
                local norm_state = "UP"
                if state_lower:find("down") or state_lower:find("offline") then
                    norm_state = "DOWN"
                end
                
                local entry = { timestamp = ts, state = state, details = rest }
                
                if not first_line then
                    first_line = entry
                    table.insert(log_data, entry)
                    prev_state = norm_state
                elseif norm_state ~= prev_state then
                    table.insert(log_data, entry)
                    prev_state = norm_state
                end
                last_line = entry
            end
        end
        f:close()
        
        -- Store the last check timestamp separately
        if last_line then
            last_check_time = last_line.timestamp
        end
    end

    local bugreports = {}
    local p = io.popen("ls -l /root/bugreports/ 2>/dev/null")
    if p then
        for line in p:lines() do
            local size, month, day, time_year, name = line:match("%s+(%d+)%s+([A-Z][a-z][a-z])%s+(%d+)%s+([%d:]+)%s+([a-zA-Z0-9%-_%.]+)")
            if name and name:match("%.log$") then
                local disp_size = string.format("%.1f KB", tonumber(size) / 1024)
                table.insert(bugreports, { filename = name, size = disp_size, date = month .. " " .. day .. " " .. time_year })
            elseif not name then
                -- Fallback for busybox or different locales
                local name_fallback = line:match("%s+([a-zA-Z0-9%-_%.]+%.log)$")
                if name_fallback then
                    table.insert(bugreports, { filename = name_fallback, size = "N/A", date = "N/A" })
                end
            end
        end
        p:close()
    end

    -- Process health-check for merged telemetry/recovery daemon
    local daemon_running = false
    local pd = io.popen("pgrep -f '[m]odem_recovery_daemon.lua'")
    if pd then
        local pid = pd:read("*l")
        if pid and pid ~= "" then
            daemon_running = true
        end
        pd:close()
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true,
        logs = log_data,
        bugreports = bugreports,
        daemon_running = daemon_running,
        last_check = last_check_time,
        router_time = os.time() * 1000
    })
end

function download_bugreport()
    local file = luci.http.formvalue("file")
    if not file or file:match("%.%.") or file:match("/") or not file:match("%.log$") then
        luci.http.status(400, "Bad Request")
        return
    end
    local path = "/root/bugreports/" .. file
    local f = io.open(path, "r")
    if not f then
        luci.http.status(404, "Not Found")
        return
    end
    local data = f:read("*a")
    f:close()
    luci.http.header("Content-Disposition", "attachment; filename=\"" .. file .. "\"")
    luci.http.prepare_content("text/plain; charset=utf-8")
    luci.http.write(data)
end

function delete_bugreport()
    local file = luci.http.formvalue("file")
    if not file or file:match("%.%.") or file:match("/") or not file:match("%.log$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({ success = false, error = "Invalid filename" })
        return
    end
    local path = "/root/bugreports/" .. file
    local success = os.remove(path)
    luci.http.prepare_content("application/json")
    luci.http.write_json({ success = success })
end

function clear_pingcheck_log()
    local f = io.open("/tmp/pingcheck.log", "w")
    local success = false
    if f then
        f:close()
        success = true
    end
    local pf = io.open("/root/pingcheck_history.log", "w")
    if pf then
        pf:close()
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ success = success })
end

EOF

echo "Deploying /usr/lib/lua/luci/view/modem/modeminfo.htm..."
cat << \EOF > /usr/lib/lua/luci/view/modem/modeminfo.htm
<%+header%>
<%
    local http = require "luci.http"

    local act = http.formvalue("action")
    if act == "restart_mm" then
        os.execute("/etc/init.d/modemmanager restart")
        os.execute("sleep 6")
        http.redirect(http.getenv("REQUEST_URI"):gsub("%?.*$", ""))
        return
    elseif act == "restart_iface" then
        os.execute("ifdown MODEM && sleep 3 && ifup MODEM")
        os.execute("sleep 6")
        http.redirect(http.getenv("REQUEST_URI"):gsub("%?.*$", ""))
        return
    elseif act == "restart_rf" then
        os.execute("mmcli -m any --disable")
        os.execute("sleep 2")
        os.execute("mmcli -m any --enable")
        os.execute("sleep 4")
        http.redirect(http.getenv("REQUEST_URI"):gsub("%?.*$", ""))
        return
    elseif act == "reset_modem" then
        local q_dev = http.formvalue("qmi_dev")
        if not q_dev or q_dev == "" then
            local ls_h = io.popen("ls /dev/cdc-wdm* 2>/dev/null")
            local wdm_devs = {}
            if ls_h then
                for line in ls_h:lines() do table.insert(wdm_devs, line) end
                ls_h:close()
            end
            q_dev = wdm_devs[1] or "/dev/cdc-wdm0"
        end
        os.execute(string.format("qmicli -p -d %s --dms-set-operating-mode=reset", q_dev))
        os.execute("sleep 6")
        http.redirect(http.getenv("REQUEST_URI"):gsub("%?.*$", ""))
        return
    end

    local function exec(cmd)
        local safe_cmd = cmd
        if not cmd:match("^timeout%s") and not cmd:match("^[%s]*local%s") then
            safe_cmd = "timeout 3 " .. cmd
        end
        local h = io.popen(safe_cmd .. " 2>/dev/null")
        if h then
            local res = h:read("*a")
            h:close()
            if res then
                res = res:gsub("\27%[[%d;]*m", "")
                return res
            end
        end
        return ""
    end

    local function exec_with_recovery(cmd)
        local out = exec(cmd)
        local err_lower = out:lower()
        if err_lower:match("error") or err_lower:match("timeout") or err_lower:match("not supported") or err_lower:match("operation not supported") then
            os.execute("ifdown MODEM && /etc/init.d/modemmanager restart && sleep 5 && ifup MODEM && sleep 5")
            out = exec(cmd)
        end
        return out
    end

    local function toHex(n)
        local num = tonumber(n)
        if not num then return "-" end
        num = math.floor(num)
        if num == 0 then return "0" end
        local hexchars = "0123456789ABCDEF"
        local res = ""
        while num > 0 do
            local rem = math.floor(num % 16)
            res = string.sub(hexchars, rem + 1, rem + 1) .. res
            num = math.floor(num / 16)
        end
        return res
    end

    local function msleep()
        os.execute("usleep 200000 2>/dev/null || sleep 0.2")
    end


    local function r_row(lbl, val, h_cls, h_color, row_id)
        lbl = tostring(lbl or "")
        val = tostring(val or "")
        local cls = "sim-row" .. (h_cls and (" " .. h_cls) or "")
        local sty = h_color and (' style="color: ' .. h_color .. ';"') or ""
        local id_attr = row_id and (' id="' .. row_id .. '"') or ""
        return string.format('<div class="%s"%s%s><strong>%s:</strong> %s</div>', cls, sty, id_attr, lbl, val)
    end

    local wdm_devs = {}
    local ls_h = io.popen("ls /dev/cdc-wdm* 2>/dev/null")
    if ls_h then
        for line in ls_h:lines() do table.insert(wdm_devs, line) end
        ls_h:close()
    end
    if #wdm_devs == 0 then table.insert(wdm_devs, "/dev/cdc-wdm0") end

    local qmi_dev = http.formvalue("qmi_dev") or wdm_devs[1]
    local qmi_cmd = "timeout 3 qmicli -d " .. qmi_dev .. " -p "

    local mmcli_idx = "any"
    local port_match = qmi_dev:match("cdc%-wdm%d+")
    local mm_mappings = {}
    local mm_ids = {}
    local m_list = exec("mmcli -L") or ""
    local has_modem = (m_list:match("ModemManager1/Modem/(%d+)") ~= nil)
    
    if has_modem then
        for id in m_list:gmatch("ModemManager1/Modem/(%d+)") do
            table.insert(mm_ids, id)
            local chk_m = exec("mmcli -m " .. id) or ""
            local matched_port = chk_m:match("(cdc%-wdm%d+)")
            if matched_port then
                table.insert(mm_mappings, "/dev/" .. matched_port .. " &harr; mmcli " .. id)
                if port_match and matched_port == port_match then
                    mmcli_idx = id
                end
            end
        end
    end
    
    if mmcli_idx == "any" and #mm_ids > 0 then
        mmcli_idx = mm_ids[1]
    end
    
    local form_mmcli_idx = http.formvalue("mmcli_idx")
    if form_mmcli_idx and form_mmcli_idx ~= "" then
        mmcli_idx = form_mmcli_idx
    end

    local mm_cmd = "mmcli -m " .. mmcli_idx
    local mmcli_out = exec(mm_cmd) or ""

    local active_sim_current = "1"
    local uim_out = exec(qmi_cmd .. "--uim-get-card-status") or ""
    local active_slot = uim_out:match("Primary GW:%s*slot%s*'([1-9]%d*)'")
    if active_slot then
        active_sim_current = active_slot
    else
        active_sim_current = mmcli_out:match("slot (%d+):[^\n]*%(active%)") or "1"
    end
    
    local modes_full = mmcli_out:match("Modes.-|%s*(.-)\n%s*%-%-%-%-%-") or mmcli_out:match("Modes.-|%s*(.*)") or ""
    local current_rat_str = "Auto"
    local curr_a, curr_p = nil, nil
    local curr_val_current = "any"
    
    local modes_block = ""
    if modes_full ~= "" then
        modes_block = modes_full:match("supported:%s*(.-)current:") or modes_full
        current_rat_str = modes_full:match("current:%s*([^\n\r]+)") or "Auto"
        curr_a = current_rat_str:match("allowed:%s*([^;]+)")
        curr_p = current_rat_str:match("preferred:%s*([a-z0-9]+)")
        if curr_a and curr_p then
            curr_val_current = curr_a:gsub(",%s*", "|"):gsub("%s+", "") .. ":" .. curr_p
        end
    end

    local uptime_str = "-"
    local uptime_sec = exec("ubus call network.interface dump | jsonfilter -e '@.interface[@.interface=\"MODEM\"].uptime' 2>/dev/null") or ""
    uptime_sec = uptime_sec:gsub("%s+", "")
    if uptime_sec ~= "" and tonumber(uptime_sec) then
        local s = tonumber(uptime_sec)
        local d = math.floor(s / 86400)
        local h = math.floor((s % 86400) / 3600)
        local m = math.floor((s % 3600) / 60)
        local r_s = s % 60
        if d > 0 then
            uptime_str = string.format("%dd %dh %dm %ds", d, h, m, r_s)
        elseif h > 0 then
            uptime_str = string.format("%dh %dm %ds", h, m, r_s)
        else
            uptime_str = string.format("%dm %ds", m, r_s)
        end
    end

    local function read_ttl(p) local f=io.open(p,"r"); if f then local c=f:read("*a") or ""; f:close(); return c:match("ttl set (%d+)") or "64" end; return "64" end
    local cur_ttl_in = read_ttl("/usr/share/nftables.d/chain-pre/mangle_prerouting/02-ttl-modem-in.nft")
    local cur_ttl_out = read_ttl("/usr/share/nftables.d/chain-pre/mangle_postrouting/01-ttl-modem-out.nft")

    if http.formvalue("apply_all") then
        local req_rat = http.formvalue("set_rat")
        if req_rat and req_rat ~= curr_val_current then
            local cmd = ""
            if req_rat == "any" then cmd = mm_cmd .. " --set-allowed-modes='any'"
            else
                local a, p = req_rat:match("([^:]+):([^:]+)")
                if a and p then
                    if p == "none" then cmd = mm_cmd .. " --set-allowed-modes='" .. a .. "'"
                    else cmd = mm_cmd .. " --set-allowed-modes='" .. a .. "' --set-preferred-mode='" .. p .. "'" end
                end
            end
            if cmd ~= "" then exec_with_recovery(cmd) end
        end

        local req_bands = http.formvalue("cb_band")
        local b_str = "any"
        if req_bands then
            if type(req_bands) == "string" then req_bands = {req_bands} end
            if #req_bands > 0 then b_str = table.concat(req_bands, "|") end
        end
        exec_with_recovery(mm_cmd .. " --set-current-bands='" .. b_str .. "'")

        local req_ttl_in = tonumber(http.formvalue("ttl_in"))
        local req_ttl_out = tonumber(http.formvalue("ttl_out"))
        local ttl_changed = false
        if req_ttl_in and req_ttl_in >= 1 and req_ttl_in <= 255 and tostring(req_ttl_in) ~= cur_ttl_in then
            local f = io.open("/usr/share/nftables.d/chain-pre/mangle_prerouting/02-ttl-modem-in.nft", "w")
            if f then
                f:write("iifname \"wwan0\" ip ttl set " .. req_ttl_in .. "\n")
                f:write("iifname \"wwan0\" ip6 hoplimit set " .. req_ttl_in .. "\n")
                f:close()
                ttl_changed = true
            end
        end
        if req_ttl_out and req_ttl_out >= 1 and req_ttl_out <= 255 and tostring(req_ttl_out) ~= cur_ttl_out then
            local f = io.open("/usr/share/nftables.d/chain-pre/mangle_postrouting/01-ttl-modem-out.nft", "w")
            if f then
                f:write("oifname \"wwan0\" ip ttl set " .. req_ttl_out .. "\n")
                f:write("oifname \"wwan0\" ip6 hoplimit set " .. req_ttl_out .. "\n")
                f:close()
                ttl_changed = true
            end
        end
        if ttl_changed then exec("/etc/init.d/firewall restart && sleep 2 && ifdown MODEM && sleep 3 && ifup MODEM") end

        local req_sim = http.formvalue("switch_sim")
        local sim_changed = false
        if req_sim and req_sim ~= active_sim_current then
            sim_changed = true
            exec("ifdown MODEM")
            os.execute("sleep 2")
            
            local sim_switch_cmd = string.format("qmicli -p -d %s --uim-switch-slot=%s", qmi_dev, req_sim)
            exec_with_recovery(sim_switch_cmd)
            
            os.execute("sleep 2")
            exec("ifup MODEM")
        end

        os.execute("sleep 2")

        local redirect_url = luci.dispatcher.build_url("admin/modem/modeminfo") .. "?qmi_dev=" .. qmi_dev
        if sim_changed then
            redirect_url = redirect_url .. "&sim_switch=1"
        end
        http.redirect(redirect_url)
        return
    end

    local qmi_sig_info = ""
    local qmi_band = ""
    local qmi_loc = ""
    local qmi_ca = ""
    local qmi_sys = ""
    local qmi_txrx = ""

    local net_iface = mmcli_out:match("net.-ports:%s*([a-zA-Z0-9%-_]+)") or "wwan0"
    local ifconfig_out = exec("ifconfig " .. net_iface) or ""
    
    local rx_mb_str = ifconfig_out:match("RX:%s*(%d+%.%d+)%s*MB") or ifconfig_out:match("RX bytes:%s*.-%((%d+%.%d+)%s*MB%)")
    local tx_mb_str = ifconfig_out:match("TX:%s*(%d+%.%d+)%s*MB") or ifconfig_out:match("TX bytes:%s*.-%((%d+%.%d+)%s*MB%)")
    
    local rx_mb, tx_mb, total_mb = "0.0", "0.0", "0.0"
    if rx_mb_str and tx_mb_str then
        rx_mb = string.format("%.1f", tonumber(rx_mb_str))
        tx_mb = string.format("%.1f", tonumber(tx_mb_str))
        total_mb = string.format("%.1f", tonumber(rx_mb_str) + tonumber(tx_mb_str))
    else
        local rx_bytes = ifconfig_out:match("RX bytes:(%d+)") or ifconfig_out:match("RX packets.-bytes%s+(%d+)") or "0"
        local tx_bytes = ifconfig_out:match("TX bytes:(%d+)") or ifconfig_out:match("TX packets.-bytes%s+(%d+)") or "0"
        rx_mb = string.format("%.1f", tonumber(rx_bytes) / 1048576)
        tx_mb = string.format("%.1f", tonumber(tx_bytes) / 1048576)
        total_mb = string.format("%.1f", (tonumber(rx_bytes) + tonumber(tx_bytes)) / 1048576)
    end
    
    local ip_addr = ifconfig_out:match("inet addr:([0-9%.]+)") or ifconfig_out:match("inet%s+([0-9%.]+)") or "-"
    local state_str = mmcli_out:match("state:%s*([^\n]+)") or "-"
    local failed_reason = mmcli_out:match("failed reason:%s*([^\n]+)")
    if failed_reason then
        state_str = state_str .. " (Failed: " .. failed_reason .. ")"
    end
    local access_tech = mmcli_out:match("access tech:%s*([^%c]+)")
    if access_tech then state_str = state_str .. " (" .. access_tech .. ")" end

    local state_color = "#4ade80"
    if state_str:lower():match("failed") then
        state_color = "#f87171"
    elseif state_str:lower():match("searching") or state_str:lower():match("registering") then
        state_color = "#fb923c"
    end

    local sim_path = mmcli_out:match("SIM.-path:%s*([^\n]+)") or ""
    local sim_idx = sim_path:match("SIM/(%d+)")
    local sim_out = exec("mmcli -i " .. (sim_idx or "any")) or ""
    local hw_imsi = sim_out:match("imsi:%s*(%d+)") or "-"
    
    local hw_phone = mmcli_out:match("Numbers.-own:%s*([^\n]+)") or "-"
    local op_id = mmcli_out:match("operator id:%s*(%d+)") or ""
    local op_name = mmcli_out:match("operator name:%s*([^\n]+)") or ""
    local plmn_display = "-"
    if op_id ~= "" and op_name ~= "" then
        plmn_display = op_id .. " (" .. op_name .. ")"
    elseif op_id ~= "" then
        plmn_display = op_id
    else
        plmn_display = qmi_loc:match("PLMN: '([^']+)'") or "-"
    end

    local hw_manuf = mmcli_out:match("manufacturer:%s*([^\n]+)") or "-"
    local hw_model = mmcli_out:match("model:%s*([^\n]+)") or "-"
    local hw_rev = mmcli_out:match("h/w revision:%s*([^\n]+)") or "-"
    local hw_imei = mmcli_out:match("equipment id:%s*([a-zA-Z0-9]+)") or "-"
    local hw_fw = mmcli_out:match("firmware revision:%s*(.-)\n%s*|%s*[a-z]")
    if hw_fw then hw_fw = hw_fw:gsub("\n%s*|%s*", " "):gsub("%s+", " ") else hw_fw = mmcli_out:match("firmware revision:%s*([^\n]+)") or "-" end
    
    local nsa_avail_init = qmi_sys:lower():match("5g nsa available:%s*'?([%w%+%-]+)'?") or "-"
    local nsa_display_init = "Нет"
    if nsa_avail_init:lower() == "yes" then nsa_display_init = "Yes" end

    local supported_modes_list = {}
    if type(modes_block) == "string" and modes_block ~= "" then
        for allowed, pref in modes_block:gmatch("allowed:%s*([^;]+);%s*preferred:%s*([a-z0-9]+)") do
            if pref:lower() ~= "2g" and pref:lower() ~= "3g" then
                local a_clean = allowed:gsub(",%s*", "|"):gsub("%s+", "")
                local label = string.upper(allowed:gsub("g", "G"):gsub(",%s*", " + "))
                if pref ~= "none" then label = label .. " (Pref " .. string.upper(pref) .. ")" else label = label .. " Only" end
                table.insert(supported_modes_list, {val = a_clean .. ":" .. pref, label = label})
            end
        end
    end

    local bands_full = mmcli_out:match("Bands.-|%s*(.-)\n%s*%-%-%-%-%-") or mmcli_out:match("Bands.-|%s*(.*)") or ""
    local supported_bands_block = bands_full:match("supported:%s*(.-)current:") or bands_full
    local current_bands_block = bands_full:match("current:%s*(.*)") or ""
    
    local supported_lte, supported_5g = {}, {}
    local other_set = {}
    if type(supported_bands_block) == "string" then
        local sbb = " " .. supported_bands_block
        for b in sbb:gmatch("[^%a]eutran%-(%d+)") do supported_lte[tonumber(b)] = true end
        for b in sbb:gmatch("[^%a]ngran%-(%d+)") do supported_5g[tonumber(b)] = true end
        for b in sbb:gmatch("[^%a]utran%-([a-z0-9]+)") do other_set["utran-"..b] = true end
        for b in sbb:gmatch("[^%a]cdma%-([a-z0-9]+)") do other_set["cdma-"..b] = true end
        for b in sbb:gmatch("[^%a]geran%-([a-z0-9]+)") do other_set["geran-"..b] = true end
        for b in sbb:gmatch("[^%a]gsm%-([a-z0-9]+)") do other_set["gsm-"..b] = true end
    end
    local lte_list, nr_list, other_list = {}, {}, {}
    for k in pairs(supported_lte) do table.insert(lte_list, k) end
    for k in pairs(supported_5g) do table.insert(nr_list, k) end
    for k in pairs(other_set) do table.insert(other_list, k) end
    table.sort(lte_list) table.sort(nr_list)
    table.sort(other_list, function(a, b)
        local p_a, n_a = a:match("^([a-z]+)%-([0-9]+)$")
        local p_b, n_b = b:match("^([a-z]+)%-([0-9]+)$")
        if p_a and p_b then
            if p_a == p_b then return tonumber(n_a) < tonumber(n_b) end
            return p_a < p_b
        end
        return a < b
    end)

    local current_bands_map = {}
    if type(current_bands_block) == "string" then
        for b in current_bands_block:gmatch("([a-z0-9%-]+)") do current_bands_map[b] = true end
    end

    local is_umts = false
    local umts_cid = qmi_loc:match("UMTS Cell ID: '(%d+)'")
    if umts_cid or (access_tech and (access_tech:match("umts") or access_tech:match("hspa") or access_tech:match("hsdpa") or access_tech:match("hsupa"))) then is_umts = true end

    local tac_dec = qmi_loc:match("Tracking Area Code: '(%d+)'") or qmi_loc:match("Location Area Code: '(%d+)'")
    local tac_str = "-"
    if tac_dec then tac_str = tac_dec .. " (" .. toHex(tac_dec) .. ")" end

    local gcid_dec = qmi_loc:match("Global Cell ID: '(%d+)'")
    local gcid_hex, enb_dec, enb_hex, cid_dec, cid_hex = "-", "-", "-", "-", "-"
    
    if gcid_dec then
        local dec = tonumber(gcid_dec)
        gcid_hex = toHex(dec)
        enb_dec = tostring(math.floor(dec / 256))
        enb_hex = toHex(math.floor(dec / 256))
        cid_dec = tostring(math.floor(dec % 256))
        cid_hex = toHex(math.floor(dec % 256))
    elseif umts_cid then
        gcid_dec = umts_cid
        gcid_hex = toHex(tonumber(umts_cid))
        local cell_id = qmi_loc:match("Cell ID: '(%d+)'")
        if cell_id then
            cid_dec = cell_id
            cid_hex = toHex(tonumber(cell_id))
        end
    else
        gcid_dec = "-"
    end

    local serv_pci = qmi_loc:match("Serving Cell ID: '(%d+)'") or qmi_loc:match("Primary Scrambling Code: '(%d+)'") or "-"
    
    local ta_match = qmi_loc:match("LTE Timing Advance: '(%d+)'")
    local ta_text = "-"
    if ta_match then
        local ta_dist = math.floor(tonumber(ta_match) * 78.12)
        ta_text = ta_match .. " (~" .. ta_dist .. " m)"
    elseif qmi_loc:match("unavailable") then
        ta_text = "Обновите страницу и/или начните передачу данных для отображения"
    end

    local lte_rssi = qmi_sig_info:match("LTE:.-RSSI:%s*'([^']+)'") or "-"
    local lte_rsrq = qmi_sig_info:match("LTE:.-RSRQ:%s*'([^']+)'") or "-"
    local lte_rsrp = qmi_sig_info:match("LTE:.-RSRP:%s*'([^']+)'") or "-"
    local lte_snr  = qmi_sig_info:match("LTE:.-SNR:%s*'([^']+)'") or "-"

    local umts_rscp = qmi_sig_info:match("UMTS:.-RSCP:%s*'([^']+)'") or qmi_loc:match("RSCP: '(%-?%d+)'")
    local umts_ecio = qmi_sig_info:match("UMTS:.-ECIO:%s*'([^']+)'") or qmi_loc:match("ECIO: '(%-?%d+)'")

    if is_umts and umts_rscp then
        lte_rsrp = umts_rscp
        lte_rsrq = umts_rscp
        if umts_ecio then lte_snr = umts_ecio else lte_snr = "-" end
    end

    local nr_rsrp = qmi_sig_info:match("5G:.-RSRP:%s*'?([^'\r\n]+)'?") or "-"
    local nr_snr  = qmi_sig_info:match("5G:.-S[IN]*R:%s*'?([^'\r\n]+)'?") or "-"
    local nr_rsrq = qmi_sig_info:match("5G:.-RSRQ:%s*'?([^'\r\n]+)'?") or "-"
    
    if nr_rsrp == "-" then nr_rsrp = "n/a" end
    if nr_rsrq == "-" then nr_rsrq = "n/a" end
    if nr_snr == "-" then nr_snr = "n/a" end

    local serv_band = qmi_ca:match("Primary Cell Info.-LTE Band: 'eutran%-([^']+)'") or qmi_band:match("Active Band Class:%s*'eutran%-([^']+)'") or "-"
    local serv_earfcn = qmi_ca:match("Primary Cell Info.-RX Channel: '([^']+)'") or qmi_band:match("Active Band Class:%s*'eutran%-[^']+'[%s\r\n]+Active Channel:%s*'([^']+)'") or "-"
    local serv_bw = qmi_ca:match("Primary Cell Info.-DL Bandwidth: '([^']+)'") or qmi_band:match("Radio Interface:%s*'lte'[%s\r\n]+Bandwidth:%s*'([^']+)'") or "-"
    
    if serv_band == "-" and is_umts then
        serv_earfcn = qmi_loc:match("UTRA Absolute RF Channel Number: '(%d+)'") or "-"
        serv_bw = "5"
        
        local wb = qmi_band:match("Active Band Class:%s*'wcdma%-([^']+)'")
        if wb then
            if wb == "2100" then serv_band = "1"
            elseif wb == "900" then serv_band = "8"
            elseif wb == "850" then serv_band = "5"
            elseif wb == "1900" then serv_band = "2"
            elseif wb == "1800" then serv_band = "3"
            else serv_band = wb end
        else
            serv_band = qmi_band:match("Active Band Class:%s*'utran%-([^']+)'") or "-"
        end
    end
    if serv_bw:match("null") then serv_bw = "Unknown" end

    local nr_band = qmi_band:match("Active Band Class:%s*'nr5g%-([^']+)'") or "-"
    local nr_arfcn = qmi_band:match("Active Band Class:%s*'nr5g%-[^']+'[%s\r\n]+Active Channel:%s*'([^']+)'") or "-"
    local nr_bw = qmi_band:match("Radio Interface:%s*'5gnr'[%s\r\n]+Bandwidth:%s*'([^']+)'") or "-"
    if nr_bw:match("null") then nr_bw = "Unknown" end

    local lte_percent = 0
    local lte_rp_num = tonumber((lte_rsrp:match("%-?%d+%.?%d*")))
    if lte_rp_num and lte_rp_num < 0 then lte_percent = math.floor((lte_rp_num + 125) * (100 / 50)) end
    if lte_percent < 0 then lte_percent = 0 elseif lte_percent > 100 then lte_percent = 100 end

    local lte_snr_percent = 0
    local lte_snr_num = tonumber((lte_snr:match("%-?%d+%.?%d*")))
    if lte_snr_num then
        lte_snr_percent = math.floor((lte_snr_num + 5) * (100 / 30))
        if lte_snr_percent < 0 then lte_snr_percent = 0 elseif lte_snr_percent > 100 then lte_snr_percent = 100 end
    end

    local function get_sinr_color(val)
        if not val then return '#ef4444' end
        if val <= 0 then
            return '#ef4444'
        elseif val <= 10 then
            return '#fbbf24'
        elseif val <= 20 then
            return '#4ade80'
        else
            return '#3b82f6'
        end
    end

    local nr_percent = 0
    local nr_rp_num = tonumber((nr_rsrp:match("%-?%d+%.?%d*")))
    if nr_rp_num and nr_rp_num < 0 then nr_percent = math.floor((nr_rp_num + 125) * (100 / 50)) end
    if nr_percent < 0 then nr_percent = 0 elseif nr_percent > 100 then nr_percent = 100 end

    local plmn_num = op_id
    if not plmn_num or plmn_num == "" then
        local qmi_plmn = qmi_loc:match("PLMN: '([^']+)'")
        if qmi_plmn then
            plmn_num = qmi_plmn:gsub("%D", "")
        end
    end
    if plmn_num == "" or plmn_num == "-" then plmn_num = nil end

    if plmn_num then
        if #plmn_num < 6 then
            local mcc = plmn_num:sub(1, 3)
            local mnc = plmn_num:sub(4)
            while #mnc < 3 do
                mnc = "0" .. mnc
            end
            plmn_num = mcc .. mnc
        end
        local plmn_replacements = {
            ["250011"] = "250002"
        }
        if plmn_replacements[plmn_num] then
            plmn_num = plmn_replacements[plmn_num]
        end
    end

    local tech_num = nil
    local num_val = nil
    local include_lac = false
    local a_tech = access_tech and access_tech:lower() or ""
    local is_nsa = false
    if nsa_display_init == "Yes" or nsa_display_init == "yes" then
        is_nsa = true
    end

    if (a_tech:match("5g") or a_tech:match("nr")) and not is_nsa then
        tech_num = 4
        local nr_cid_dec = qmi_loc:match("NR5G Cell ID: '(%d+)'")
        if not nr_cid_dec then
            local nr_block = qmi_loc:match("NR5G Cell Info(.-)%-") or qmi_loc:match("NR5G Cell Info(.*)")
            if nr_block then
                nr_cid_dec = nr_block:match("Cell ID: '(%d+)'")
            end
        end
        if nr_cid_dec then
            local dec = tonumber(nr_cid_dec)
            if dec then
                num_val = tostring(math.floor(dec / 4096))
            end
        end
    elseif a_tech:match("lte") or is_nsa then
        tech_num = 3
        if enb_dec and enb_dec ~= "-" and enb_dec ~= "" then
            num_val = enb_dec
        end
    elseif a_tech:match("umts") or a_tech:match("hsp") or a_tech:match("wcdma") or is_umts then
        tech_num = 2
        if cid_dec and cid_dec ~= "-" and cid_dec ~= "" then
            num_val = cid_dec
        end
        include_lac = true
    elseif a_tech:match("gsm") or a_tech:match("gprs") or a_tech:match("edge") then
        tech_num = 1
        if cid_dec and cid_dec ~= "-" and cid_dec ~= "" then
            num_val = cid_dec
        end
        include_lac = true
    else
        if is_umts then
            tech_num = 2
            num_val = cid_dec
            include_lac = true
        elseif enb_dec and enb_dec ~= "-" and enb_dec ~= "" then
            tech_num = 3
            num_val = enb_dec
        end
    end

    local fourcells_url = ""
    if plmn_num and tech_num and num_val and num_val ~= "-" and num_val ~= "" then
        fourcells_url = "https://4cells.ru/?plmn=" .. plmn_num .. "&tech=" .. tech_num .. "&num=" .. num_val
        if include_lac and tac_dec and tac_dec ~= "" and tac_dec ~= "-" then
            fourcells_url = fourcells_url .. "&lac=" .. tac_dec
        end
    end

    local tx_power = qmi_txrx:match("TX:.-Power: '([^']+)'") or "Обновите страницу и/или начните передачу данных для отображения"
    local rx_chains = {}
	for ch, chunk in qmi_txrx:gmatch("RX Chain (%d+):(.-)Phase:") do
        local pwr = chunk:match("Power: '([^']+)'") or "-"
        local ec = chunk:match("ECIO: '([^']+)'") or "-"
        local rp = chunk:match("RSRP: '([^']+)'") or "-"
        table.insert(rx_chains, {chain=ch, pwr=pwr, ec=ec, rp=rp})
    end

    local ca_info = {}
    for chunk in qmi_ca:gmatch("Secondary Cell %d+ Info(.-)Cell index:") do
        local pci = chunk:match("Physical Cell ID: '([^']+)'")
        local rx = chunk:match("RX Channel: '([^']+)'") or "-"
        local bw = chunk:match("DL Bandwidth: '([^']+)'") or "-"
        local bnd = chunk:match("LTE Band: 'eutran%-([^']+)'") or "-"
        local st = chunk:match("State: '([^']+)'") or "-"
        if pci then table.insert(ca_info, {band=bnd, earfcn=rx, bw=bw, pci=pci, state=st}) end
    end

    local neighbours = {}
    local intra_earfcn = qmi_loc:match("Intrafrequency LTE Info.-EUTRA Absolute RF Channel Number: '(%d+)'") or "0"
    local intra_info = qmi_loc:match("Intrafrequency LTE Info(.-)Interfrequency") or qmi_loc:match("Intrafrequency LTE Info(.*)") or ""
    
    for p, rq, rp, ri in intra_info:gmatch("Physical Cell ID: '(%d+)'.-RSRQ: '([^']+)'.-RSRP: '([^']+)'.-RSSI: '([^']+)'") do
        if p ~= serv_pci then table.insert(neighbours, {e=intra_earfcn, pci=p, rq=rq, rp=rp, ri=ri}) end
    end

    local inter_info = qmi_loc:match("Interfrequency LTE Info(.-)LTE Info") or qmi_loc:match("Interfrequency LTE Info(.*)") or ""
    local freqs = {}
    local s = 1
    while true do
        local start_f, end_f = inter_info:find("Frequency %[%d+%]:", s)
        if not start_f then table.insert(freqs, inter_info:sub(s)); break end
        if s < start_f then table.insert(freqs, inter_info:sub(s, start_f - 1)) end
        s = start_f
        local next_start = inter_info:find("Frequency %[%d+%]:", end_f)
        if next_start then table.insert(freqs, inter_info:sub(start_f, next_start - 1)); s = next_start
        else table.insert(freqs, inter_info:sub(start_f)); break end
    end

    for _, f_chunk in ipairs(freqs) do
        local e_freq = f_chunk:match("EUTRA Absolute RF Channel Number: '(%d+)'") or "0"
        for p, rq, rp, ri in f_chunk:gmatch("Physical Cell ID: '(%d+)'.-RSRQ: '([^']+)'.-RSRP: '([^']+)'.-RSSI: '([^']+)'") do
            table.insert(neighbours, {e=e_freq, pci=p, rq=rq, rp=rp, ri=ri})
        end
    end
    table.sort(neighbours, function(a,b)
        local ea, eb = tonumber(a.e) or 0, tonumber(b.e) or 0
        local ra = tonumber(a.ri:match("%-?%d+%.?%d*")) or -999
        local rb = tonumber(b.ri:match("%-?%d+%.?%d*")) or -999
        if ea == eb then return ra > rb else return ea < eb end
    end)

    -- Match aggregated sectors with neighboring cells to extract RSRP, RSRQ, and RSSI/SINR
    for _, ca in ipairs(ca_info) do
        local matched_rsrp = "-"
        local matched_rsrq = "-"
        local matched_rssi = "-"
        local ca_earfcn = ca.earfcn:gsub("%s+", "")
        local ca_pci = ca.pci:gsub("%s+", "")
        
        for _, nb in ipairs(neighbours) do
            local nb_earfcn = nb.e:gsub("%s+", "")
            local nb_pci = nb.pci:gsub("%s+", "")
            if nb_earfcn == ca_earfcn and nb_pci == ca_pci then
                matched_rsrp = nb.rp or "-"
                matched_rsrq = nb.rq or "-"
                matched_rssi = nb.ri or "-"
                break
            end
        end
        ca.rsrp = matched_rsrp
        ca.rsrq = matched_rsrq
        ca.rssi = matched_rssi
    end

    -- Read recovery metrics server-side
    local json = require "luci.jsonc"
    recovery_metrics = {}
    local mf = io.open("/tmp/modem_recovery_metrics.json", "r")
    if mf then
        local content = mf:read("*a")
        mf:close()
        if content then
            local success, parsed = pcall(json.parse, content)
            if success and type(parsed) == "table" then
                recovery_metrics = parsed
            end
        end
    end

    local lang = http.getcookie("modem_lang") or "ru"
    function format_sec(s)
        s = tonumber(s)
        if not s or s < 0 then return "0" .. (lang == "en" and "s" or "с") end
        if s < 60 then return s .. (lang == "en" and "s" or "с") end
        local m = math.floor(s / 60)
        local r = s % 60
        if m < 60 then return m .. (lang == "en" and "m " or "м ") .. r .. (lang == "en" and "s" or "с") end
        local h = math.floor(m / 60)
        local rm = m % 60
        return h .. (lang == "en" and "h " or "ч ") .. rm .. (lang == "en" and "m " or "м ") .. r .. (lang == "en" and "s" or "с")
    end

    state_color = "#3b82f6"
    rec_state = recovery_metrics.current_state or "Starting"
    if rec_state == "Connected" then
        state_color = "#10b981"
    elseif rec_state == "Missing" or rec_state == "Denied" or rec_state:find("Failed") then
        state_color = "#ef4444"
    else
        state_color = "#fb923c"
    end

    mm_status_color = (recovery_metrics.modemmanager_status == "Running") and "#10b981" or "#ef4444"

    is_daemon_running = false
    local f_run = io.popen("pgrep -lf modem_recovery_daemon.lua | grep -v -E 'pgrep|sh|bash' >/dev/null && echo 'yes' || echo 'no'")
    if f_run then
        local r_val = f_run:read("*a")
        f_run:close()
        is_daemon_running = (r_val and r_val:match("yes") ~= nil)
    end

    is_daemon_enabled = false
    local f_enb = io.popen("/etc/init.d/modem_recovery enabled && echo 'yes' || echo 'no'")
    if f_enb then
        local e_val = f_enb:read("*a")
        f_enb:close()
        is_daemon_enabled = (e_val and e_val:match("yes") ~= nil)
    end
%>

<div class="cbi-section">
    <div class="cbi-section-node" style="padding: 10px 0; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px;">
        <div>
            <h3 style="margin-bottom: 5px; color: #ffffff;">Расширенная панель модема</h3>
        </div>
        <div style="display: flex; align-items: center; gap: 6px; background: rgba(30, 41, 59, 0.7); backdrop-filter: blur(8px); padding: 4px 8px; border-radius: 6px; border: 1px solid rgba(255, 255, 255, 0.08); height: fit-content; margin-right: 15px;">
            <span style="font-size: 12px; color: #94a3b8;">🌐 Language:</span>
            <select id="lang_select" onchange="changeLanguage(this.value)" style="background: transparent; color: #f8fafc; border: none; font-size: 12px; cursor: pointer; outline: none; padding: 0 4px; font-weight: 500;">
                <option value="ru" style="background: #1e293b; color: #f8fafc;">RU</option>
                <option value="en" style="background: #1e293b; color: #f8fafc;">EN</option>
            </select>
        </div>
    </div>
</div>

<style>
.sim-dash{ font-family:monospace;font-size:14px;line-height:1.6;background-color:#1a1a1a;color:#d1d5db;padding:20px;border-radius:6px;margin-bottom:15px;}
.sim-dash h4{ color:#ffffff;margin-top:0;margin-bottom:15px;font-weight:normal;border-bottom:1px solid #374151;padding-bottom:8px;}
.sim-dash strong{ color:#ffffff;display:inline-block;min-width:210px;font-weight:normal;}
.sim-row{ padding:1px 0;}
.sim-row.highlight{ color:#60a5fa;}
.signal-bg{ background:#374151;height:10px;width:100px;display:inline-block;border-radius:5px;overflow:hidden;vertical-align:middle;margin-left:10px;}
.signal-fg{ height:100%;transition:width 0.3s ease;}
.ca-block{ margin-left:20px;color:#9ca3af;}
.ca-state-active{ color:#4ade80;}
.ca-state-deact{ color:#f87171;}
.grid-table{ display:grid;grid-template-columns:repeat(5,1fr);gap:5px;text-align:center;}
.grid-header{ font-weight:bold;color:#ffffff;border-bottom:1px solid #374151;padding-bottom:5px;margin-bottom:5px;}
.grid-row{ border-bottom:1px solid #262626;}
.band-checkbox{ display:inline-flex;align-items:center;background:#262626;border:1px solid #374151;border-radius:4px;padding:4px 10px;margin:2px;cursor:pointer;user-select:none;color:#d1d5db;font-size:13px;transition:all 0.15s ease;}
.band-checkbox input{ display:none;}
.band-checkbox:hover{ border-color:#3b82f6;color:#ffffff;}
.active-band{ background:#1e3a8a;border-color:#3b82f6;color:#ffffff;font-weight:bold;}
.input-ttl{ background:#262626;color:#ffffff;border:1px solid #374151;padding:4px 8px;border-radius:4px;width:80px;text-align:center;outline:none;}
.input-ttl:focus{ border-color:#3b82f6;}
.validation-err{ color:#ef4444;font-size:13px;margin-top:5px;font-weight:bold;}
</style>

<div id="no_modem_banner" style="background: #1e293b; border-left: 4px solid #ef4444; border-radius: 8px; padding: 24px; text-align: center; box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1); margin-bottom: 20px; <%= has_modem and 'display: none;' or '' %>">
    <h3 style="color: #ef4444; margin-top: 0; font-size: 20px;">⚠️ Модемный интерфейс не обнаружен</h3>
    <p style="color: #94a3b8; margin: 0; font-size: 14px; margin-bottom: 20px;">Пожалуйста, подключите модем, проверьте питание и убедитесь, что служба ModemManager активна.</p>
    
    <div style="display: flex; justify-content: center; gap: 15px; flex-wrap: wrap;">
        <a href="?action=restart_mm" style="display: inline-block; padding: 8px 16px; background-color: #3b82f6; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезапуск службы ModemManager...')">Перезапустить ModemManager</a>
        <a href="?action=restart_iface" style="display: inline-block; padding: 8px 16px; background-color: #f59e0b; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезапуск интерфейса MODEM...')">Перезапустить интерфейс MODEM</a>
        <a href="?action=restart_rf" style="display: inline-block; padding: 8px 16px; background-color: #10b981; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезапуск радиомодуля (RF)...')">Перезапустить RF</a>
        <a href="javascript:void(0)" onclick="resetUsbPort();" style="display: inline-block; padding: 8px 16px; background-color: #8b5cf6; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;">Сбросить USB порт модема</a>
        <a href="?action=reset_modem&qmi_dev=<%=qmi_dev%>" style="display: inline-block; padding: 8px 16px; background-color: #ef4444; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезагрузка модема (QMI)...')">Перезагрузить модем</a>
    </div>
    
    <div style="margin-top: 20px; border-top: 1px solid #334155; padding-top: 15px;">
        <button type="button" id="save_logs_btn" onclick="saveLossLogs();" style="display: inline-block; padding: 8px 20px; background-color: #8b5cf6; color: #ffffff; border: 1px solid #7c3aed; border-radius: 4px; font-weight: bold; cursor: pointer; font-size: 13px; font-family: sans-serif; transition: all 0.2s ease;" onmouseover="this.style.background='#7c3aed'" onmouseout="this.style.background='#8b5cf6'">Сохранить логи</button>
    </div>
</div>

<div id="modem_data_container" style="<%= not has_modem and 'display: none;' or '' %>">

<div class="sim-dash" style="background-color: #1e293b;">
    <div style="display: flex; gap: 15px; align-items: center; flex-wrap: wrap;">
        <label style="color: #ffffff; font-weight: bold; font-family: sans-serif;">Выберите интерфейс модема:</label>
        <select id="modem_interface_select" onchange="window.location.href='<%=luci.dispatcher.build_url('admin/modem/modeminfo')%>?qmi_dev=' + this.value" style="background: #0f172a; color: #d1d5db; border: 1px solid #3b82f6; padding: 6px 12px; border-radius: 4px; outline: none; cursor: pointer; font-size: 14px;">
            <% for _, dev in ipairs(wdm_devs) do %>
                <option value="<%=dev%>" <%= (dev == qmi_dev) and 'selected' or '' %>><%=dev%></option>
            <% end %>
        </select>
        
        <label style="color: #ffffff; font-weight: bold; margin-left: 15px; font-family: sans-serif;">Связан с индексом MM:</label>
        <select id="mmcli_idx_select" onchange="window.location.href='<%=luci.dispatcher.build_url('admin/modem/modeminfo')%>?qmi_dev=<%=qmi_dev%>&mmcli_idx=' + this.value" style="background: #0f172a; color: #d1d5db; border: 1px solid #3b82f6; padding: 6px 12px; border-radius: 4px; outline: none; cursor: pointer; font-size: 14px;">
            <% for _, id in ipairs(mm_ids) do %>
                <option value="<%=id%>" <%= (id == mmcli_idx) and 'selected' or '' %>><%=id%></option>
            <% end %>
            <% if #mm_ids == 0 then %>
                <option value="any">any</option>
            <% end %>
        </select>
    </div>
    <% if #mm_mappings > 0 then %>
    <div style="margin-top: 10px; font-size: 12px; color: #94a3b8; border-top: 1px dashed #334155; padding-top: 8px;">
        <strong>Обнаруженные привязки:</strong> &nbsp;&nbsp;
        <% for _, map in ipairs(mm_mappings) do %>
            <span style="display: inline-block; margin-right: 20px; background: #0f172a; padding: 2px 8px; border-radius: 3px; border: 1px solid #1e293b;"><%=map%></span>
        <% end %>
    </div>
    <% end %>
</div>

<div id="apply_overlay" style="display:none; position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(15,23,42,0.95); z-index:99999; justify-content:center; align-items:center; flex-direction:column; color:#fff; font-family:sans-serif; backdrop-filter:blur(5px);">
    <div class="spinning" style="width:60px; height:60px; border:4px solid #334155; border-top-color:#3b82f6; border-radius:50%; animation:spin 1s linear infinite; margin-bottom:20px;"></div>
    <div id="overlay_title" style="font-size:20px; font-weight:bold; color:#f8fafc;">Применение настроек...</div>
    <div id="overlay_subtitle" style="font-size:14px; color:#94a3b8; margin-top:8px; text-align:center; max-width:400px; padding:0 20px; line-height:1.5;">Настройки отправлены в ModemManager. Выполняется реконнект интерфейсов. Пожалуйста, подождите.</div>
</div>

<div id="sim_switch_overlay" style="display:none; position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(15,23,42,0.95); z-index:99999; justify-content:center; align-items:center; flex-direction:column; color:#fff; font-family:sans-serif; backdrop-filter:blur(5px);">
    <div class="spinning" style="width:60px; height:60px; border:4px solid #334155; border-top-color:#c084fc; border-radius:50%; animation:spin 1s linear infinite; margin-bottom:20px;"></div>
    <div style="font-size:20px; font-weight:bold; color:#f8fafc;">Переключение SIM-карты...</div>
    <div style="font-size:14px; color:#94a3b8; margin-top:8px; text-align:center; max-width:400px; padding:0 20px; line-height:1.5;">Модем переключает слот SIM и перезагружается. Пожалуйста, подождите <span id="sim_switch_timer" style="font-weight:bold; color:#c084fc; font-size:16px;">10</span> секунд, пока соединение восстановится.</div>
</div>
<style>
@keyframes spin { to { transform: rotate(360deg); } }
</style>

<form method="post" action="<%=luci.dispatcher.build_url('admin/modem/modeminfo')%>" onsubmit="return validateForm()">
    <input type="hidden" name="qmi_dev" value="<%=qmi_dev%>">
    <input type="hidden" name="mmcli_idx" value="<%=mmcli_idx%>">

    <div class="sim-dash">
        <h4>Управление SIM-картами и TTL</h4>
        <div style="display: flex; gap: 20px; flex-wrap: wrap;">
            <div>
                <label style="display:block; margin-bottom:8px; color: #ffffff; font-weight: bold;">Выбрать SIM-слот:</label>
                <div style="display: flex; gap: 8px;">
                    <label class="band-checkbox <%= (active_sim_current == '1') and 'active-band' or '' %>">
                        <input type="radio" name="switch_sim" value="1" <%= (active_sim_current == '1') and 'checked' or '' %> onchange="isSimInteracted = true; updateRadioStyles(this.name)"> SIM 1
                    </label>
                    <label class="band-checkbox <%= (active_sim_current == '2') and 'active-band' or '' %>">
                        <input type="radio" name="switch_sim" value="2" <%= (active_sim_current == '2') and 'checked' or '' %> onchange="isSimInteracted = true; updateRadioStyles(this.name)"> SIM 2
                    </label>
                </div>
            </div>
            <div>
                <label style="display:block; margin-bottom:8px; color: #ffffff; font-weight: bold;">Входящий TTL:</label>
                <input type="text" name="ttl_in" value="<%=cur_ttl_in%>" class="input-ttl" style="padding: 6px 10px;" oninput="this.value=this.value.replace(/[^0-9]/g,'')">
            </div>
            <div>
                <label style="display:block; margin-bottom:8px; color: #ffffff; font-weight: bold;">Исходящий TTL:</label>
                <input type="text" name="ttl_out" value="<%=cur_ttl_out%>" class="input-ttl" style="padding: 6px 10px;" oninput="this.value=this.value.replace(/[^0-9]/g,'')">
            </div>
        </div>
        <div id="ttl_err" class="validation-err"></div>
		<br>
        <h4>Выбор режима(RAT) и частот(band)</h4>
        <div style="margin-bottom: 15px; color: #4ade80;"><strong>Текущий режим:</strong> <%= (curr_a and curr_p) and (string.upper(curr_a:gsub("g", "G"):gsub(",%s*", " + ")) .. (curr_p ~= "none" and " (Pref " .. string.upper(curr_p) .. ")" or " Only")) or "Auto" %></div>
        <span style="font-size: 13px; color: #fbbf24; margin-right: auto;">⚠️ Некоторые режимы RAT могут работать с ошибками из-за специфики ModemManager. </span>
        <div style="margin-bottom: 10px; color: #ffffff;">Выбрать режим работы (RAT):</div>
        <div style="margin-bottom: 25px; border-bottom: 1px dashed #374151; padding-bottom: 20px;">
            <select name="set_rat" style="background:#262626; color:#ffffff; border:1px solid #374151; padding:8px 12px; border-radius:4px; min-width:300px; max-width:100%; outline:none; cursor:pointer;" onchange="this.style.borderColor = '#3b82f6'" onblur="this.style.borderColor = '#374151'">
                <option value="any" <%= (curr_val_current == 'any' or curr_val_current == '') and 'selected' or '' %>>AUTO (ALL)</option>
                <% for _, m in ipairs(supported_modes_list) do %>
                    <option value="<%=m.val%>" <%= (m.val == curr_val_current) and 'selected' or '' %>><%=m.label%></option>
                <% end %>
            </select>
        </div>

        <div style="margin-bottom: 10px; color: #ffffff;">LTE частоты:</div>
        <div style="display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 15px;">
            <% for _, b in ipairs(lte_list) do 
                local b_name = "eutran-" .. b
                local checked = current_bands_map[b_name] and "checked" or ""
                local active_cls = current_bands_map[b_name] and "active-band" or ""
            %>
                <label class="band-checkbox <%=active_cls%>">
                    <input type="checkbox" name="cb_band" value="<%=b_name%>" <%=checked%> onchange="this.parentNode.classList.toggle('active-band', this.checked)"> B<%=b%>
                </label>
            <% end %>
        </div>

        <div style="margin-bottom: 10px; color: #ffffff;">5G частоты:</div>
        <div style="display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 15px;">
            <% for _, b in ipairs(nr_list) do 
                local b_name = "ngran-" .. b
                local checked = current_bands_map[b_name] and "checked" or ""
                local active_cls = current_bands_map[b_name] and "active-band" or ""
            %>
                <label class="band-checkbox <%=active_cls%>">
                    <input type="checkbox" name="cb_band" value="<%=b_name%>" <%=checked%> onchange="this.parentNode.classList.toggle('active-band', this.checked)"> n<%=b%>
                </label>
            <% end %>
        </div>

        <% if #other_list > 0 then %>
        <div style="margin-bottom: 10px; color: #ffffff;">3G/2G частоты (UMTS/CDMA/GSM):</div>
        <div style="display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 15px;">
            <% for _, b_name in ipairs(other_list) do 
                local disp_name = string.upper(b_name:gsub("%-", " "))
                if b_name:match("^utran%-(%d+)") then
                    disp_name = "3G B" .. b_name:match("^utran%-(%d+)")
                elseif b_name:match("^geran%-(%w+)") or b_name:match("^gsm%-(%w+)") then
                    disp_name = "2G GSM " .. string.upper(b_name:match("%-(%w+)"))
                elseif b_name:match("^cdma%-(%w+)") then
                    disp_name = "CDMA " .. string.upper(b_name:match("%-(%w+)"))
                end
                local checked = current_bands_map[b_name] and "checked" or ""
                local active_cls = current_bands_map[b_name] and "active-band" or ""
            %>
                <label class="band-checkbox <%=active_cls%>">
                    <input type="checkbox" name="cb_band" value="<%=b_name%>" <%=checked%> onchange="this.parentNode.classList.toggle('active-band', this.checked)"> <%=disp_name%>
                </label>
            <% end %>
        </div>
        <% end %>

        <div style="margin-top: 20px; display: flex; gap: 10px;">
            <button type="button" class="cbi-button cbi-button-action" onclick="selectAllBands()">Включить все частоты</button>
            <button type="button" class="cbi-button cbi-button-reset" onclick="clearBands()">Выключить все частоты</button>
        </div>
    </div>
    <div class="cbi-page-actions" style="margin-top: 15px; margin-bottom: 10px; text-align: right; border-top: 1px dashed #374151; padding-top: 10px; display: flex; justify-content: flex-end; align-items: center;">
        <span style="font-size: 12px; color: #fbbf24; margin-right: auto;">⚠️ Изменения применяются мгновенно. Возможен кратковременный обрыв связи.</span>
        <button type="submit" name="apply_all" value="1" class="cbi-button cbi-button-apply" style="padding: 6px 15px; font-weight: bold; font-size: 13px;">Сохранить и применить</button>
    </div>
</form>

<div class="sim-dash" style="margin-top: 30px;">
    <h4>Сеть и подключение</h4>
    <%=r_row("Сеть (PLMN)", plmn_display, nil, nil, "plmn_display_row")%>
    <%=r_row("Статус (технология)", '<span style="font-weight:bold; color:'..state_color..';">'..state_str..'</span>', nil, nil, "state_str_row")%>
    <%=r_row("Время сессии", '<span style="color:#f59e0b; font-weight:bold;">'..uptime_str..'</span>', nil, nil, "uptime_str_row")%>
    <%=r_row("IP-адрес (WWAN)", '<span style="color:#10b981; font-weight:bold;">'..ip_addr..'</span>', nil, nil, "ip_addr_row")%>
    <%=r_row("Трафик (Прием / Отдача)", '<span style="color:#3b82f6;">'..rx_mb..'</span> MB / <span style="color:#ec4899;">'..tx_mb..'</span> MB', nil, nil, "traffic_row")%>
    <%=r_row("Общий трафик", '<span style="font-weight:bold;">'..total_mb..'</span> MB', nil, nil, "total_mb_row")%>
    <%=r_row("Доступность сети 5G NSA", nsa_display_init, nil, nil, "nsa_display_row")%>
    <div id="fourcells_row" class="sim-row" style="display: <%= (fourcells_url and fourcells_url ~= "") and "block" or "none" %>;">
        <strong>Ссылка на 4cells:</strong> <span id="fourcells_link"><% if fourcells_url and fourcells_url ~= "" then %><a href="<%=fourcells_url%>" target="_blank" style="color: #60a5fa; text-decoration: underline;">ссылка на 4cells (доступно не всегда)</a><% else %>-<% end %></span>
    </div>
    <br>
    
    <div id="umts_block" style="display: <%= is_umts and 'block' or 'none' %>;">
        <%=r_row("UMTS Cell ID", gcid_dec.." ("..gcid_hex..")", nil, nil, "umts_gcid_row")%>
        <%=r_row("ID соты (Cell ID)", cid_dec.." ("..cid_hex..")", nil, nil, "umts_cid_row")%>
        <%=r_row("Код зоны (LAC)", tac_str, nil, nil, "umts_tac_row")%>
        <%=r_row("Primary Scrambling Code (PSC)", serv_pci, nil, nil, "umts_pci_row")%>
        <br>
        <%=r_row("Ведущий диапазон UMTS", "B"..serv_band.." (FCN: "..serv_earfcn..") | BW: "..serv_bw.." MHz", "highlight", nil, "umts_band_row")%>
        <div class="sim-row">
            <strong>Сила сигнала UMTS (RSCP):</strong> <span id="umts_signal_percent"><%=lte_percent%></span>% 
            <div class="signal-bg">
                <div id="umts_signal_bar" class="signal-fg" style="width: <%=lte_percent%>%; background: <%= lte_percent > 65 and '#4ade80' or (lte_percent > 35 and '#fbbf24' or '#ef4444') %>;"></div>
            </div>
        </div>
        <%=r_row("UMTS RSCP", lte_rsrp, nil, nil, "umts_rsrp_row")%>
        <%=r_row("UMTS ECIO", lte_snr, nil, nil, "umts_ecio_row")%>
        <br>
    </div>

    <div id="lte_block" style="display: <%= is_umts and 'none' or 'block' %>;">
        <%=r_row("Global Cell ID", gcid_dec.." ("..gcid_hex..")", nil, nil, "lte_gcid_row")%>
        <%=r_row("ID базовой станции (eNB)", enb_dec.." ("..enb_hex..")", nil, nil, "lte_enb_row")%>
        <%=r_row("ID соты (Сектор)", cid_dec.." ("..cid_hex..")", nil, nil, "lte_cid_row")%>
        <%=r_row("Код зоны (TAC)", tac_str, nil, nil, "lte_tac_row")%>
        <%=r_row("PCI", serv_pci, nil, nil, "lte_pci_row")%>
        <%=r_row("Timing Advance", ta_text, nil, nil, "lte_ta_row")%>
        <br>
        <%=r_row("Ведущий диапазон LTE", "B"..serv_band.." (EARFCN: "..serv_earfcn..") | BW: "..serv_bw.." MHz", "highlight", nil, "lte_band_row")%>
        <div class="sim-row">
            <strong>Сила сигнала LTE (RSRP):</strong> <span id="lte_signal_percent"><%=lte_percent%></span>% 
            <div class="signal-bg">
                <div id="lte_signal_bar" class="signal-fg" style="width: <%=lte_percent%>%; background: <%= lte_percent > 65 and '#4ade80' or (lte_percent > 35 and '#fbbf24' or '#ef4444') %>;"></div>
            </div>
        </div>
        <div class="sim-row">
            <strong>Качество сигнала LTE (SINR):</strong> <span id="lte_sinr_percent"><%=lte_snr_percent%></span>% 
            <div class="signal-bg">
                <div id="lte_sinr_bar" class="signal-fg" style="width: <%=lte_snr_percent%>%; background: <%= get_sinr_color(lte_snr_num) %>;"></div>
            </div>
        </div>
        <%=r_row("LTE RSRP / RSRQ", lte_rsrp.." / "..lte_rsrq, nil, nil, "lte_sig_row")%>
        <%=r_row("LTE SINR / SNR", lte_snr, nil, nil, "lte_snr_row")%>
        <br>
    </div>

    <%=r_row("Мощность передатчика", tx_power, nil, nil, "tx_power_row")%>
    <div id="rx_chains_container">
        <% for _, rx in ipairs(rx_chains) do %>
            <div class="sim-row ca-block">Антенна <%=rx.chain%>: RSSI <%=rx.pwr%> | RSRP <%=rx.rp%> | RSRQ <%=rx.ec or "n/a"%> </div>
        <% end %>
    </div>
    <br>
    
    <div id="ca_container">
        <% if not is_umts then %>
        <div class="sim-row"><strong>Агрегация частот (CA):</strong> <% if #ca_info == 0 then %>Не активна (нет SCC)<% end %></div>
        <% for i, ca in ipairs(ca_info) do %>
            <div class="sim-row ca-block" style="display: grid; grid-template-columns: 280px 1fr; gap: 2px 10px; padding: 6px 0; border-bottom: 1px solid #374151;">
                <div>SCC <%=i%>: <strong>B<%=ca.band%></strong> (EARFCN: <%=ca.earfcn%>, <%=ca.bw%> MHz)</div>
                <div>PCI: <%=ca.pci%> | RSSI: <%=ca.rssi or '-'%></div>
                <div>State: <span class="<%= ca.state == 'activated' and 'ca-state-active' or 'ca-state-deact' %>"><%=ca.state%></span></div>
                <div>RSRP: <%=ca.rsrp or '-'%> | RSRQ: <%=ca.rsrq or '-'%></div>
            </div>
        <% end %>
        <% end %>
    </div>
</div>

<%
    local is_nr_active = (nr_band ~= "-" or (nr_rsrp ~= "n/a" and nr_rsrp ~= "-"))
    local nr_badge_text = is_nr_active and "Активно" or "Не активно"
    local nr_badge_style = is_nr_active 
        and "background: #c084fc; color: #1e1b4b;" 
        or "background: #374151; color: #9ca3af;"
%>

<div class="sim-dash" id="nr_block">
    <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #374151; padding-bottom: 8px; margin-bottom: 15px; cursor: pointer; user-select: none;" onclick="toggleSpoiler('nr_content', 'nr_arrow')">
        <h4 style="margin: 0; border: none; padding: 0; display: flex; align-items: center; gap: 8px;">
            <svg id="nr_arrow" style="width: 16px; height: 16px; transition: transform 0.3s ease; transform: rotate(90deg);" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M9 5l7 7-7 7"></path>
            </svg>
            Сигналы 5G NSA / NR
        </h4>
        <span id="nr_status_badge" data-active="<%= is_nr_active and 'true' or 'false' %>" style="font-size: 12px; font-weight: bold; padding: 2px 8px; border-radius: 4px; <%= nr_badge_style %> transition: all 0.3s ease;"><%= nr_badge_text %></span>
    </div>
    
    <div id="nr_content" style="transition: max-height 0.3s ease-in-out, opacity 0.3s ease-in-out; overflow: hidden;">
        <%=r_row("Ведущий диапазон 5G NSA", "n"..nr_band.." (ARFCN: "..nr_arfcn..") | BW: "..nr_bw.." MHz", "highlight", "#c084fc", "nr_band_row")%>
        <div class="sim-row">
            <strong>Сила сигнала 5G (RSRP):</strong> <span id="nr_signal_percent"><%=nr_percent%></span>% 
            <div class="signal-bg">
                <div id="nr_signal_bar" class="signal-fg" style="width: <%=nr_percent%>%; background: <%= nr_percent > 65 and '#4ade80' or (nr_percent > 35 and '#fbbf24' or '#ef4444') %>;"></div>
            </div>
        </div>
        <%=r_row("5G RSRP / RSRQ", nr_rsrp.." / "..nr_rsrq, nil, nil, "nr_sig_row")%>
        <%=r_row("5G SINR / SNR", nr_snr, nil, nil, "nr_snr_row")%>
    </div>
</div>

<!-- Speed Graph Section -->
<div class="sim-dash">
    <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #374151; padding-bottom: 8px; margin-bottom: 15px; cursor: pointer; user-select: none;" onclick="toggleSpoiler('speed_graph_content', 'speed_graph_arrow')">
        <h4 style="margin: 0; border: none; padding: 0; display: flex; align-items: center; gap: 8px;">
            <svg id="speed_graph_arrow" style="width: 16px; height: 16px; transition: transform 0.3s ease; transform: rotate(90deg);" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M9 5l7 7-7 7"></path>
            </svg>
            Скорость передачи данных
        </h4>
        <div style="display: flex; align-items: center; gap: 10px;" onclick="event.stopPropagation();">
            <label for="graph_range" style="color: #9ca3af; font-size: 13px;">Диапазон:</label>
            <select id="graph_range" onchange="updateGraphRange()" style="background: #262626; color: #d1d5db; border: 1px solid #374151; padding: 2px 6px; border-radius: 4px; outline: none; cursor: pointer; font-size: 12px;">
                <option value="30">30 сек</option>
                <option value="60" selected>1 мин</option>
                <option value="300">5 мин</option>
            </select>
        </div>
    </div>
    
    <div id="speed_graph_content" style="transition: max-height 0.3s ease-in-out, opacity 0.3s ease-in-out; overflow: hidden;">
        <div style="display: flex; justify-content: space-around; margin-bottom: 15px; font-size: 15px;">
            <div><strong>Входящая (Downlink):</strong> <span id="speed_rx" style="color: #4ade80; font-weight: bold; font-size: 16px;">0.00</span> Mbit/s</div>
            <div><strong>Исходящая (Uplink):</strong> <span id="speed_tx" style="color: #60a5fa; font-weight: bold; font-size: 16px;">0.00</span> Mbit/s</div>
        </div>
        <div style="position: relative; width: 100%; height: 200px; margin-bottom: 15px;">
            <canvas id="speed_chart" style="width: 100%; height: 100%; display: block;"></canvas>
        </div>
        
        <!-- Average and Peak Speeds -->
        <div style="display: flex; justify-content: space-around; background: #0f172a; padding: 10px; border-radius: 6px; border: 1px solid #1e293b; font-family: monospace; font-size: 13px; flex-wrap: wrap; gap: 10px;">
            <div style="min-width: 180px; text-align: center;">
                <span style="color: #94a3b8;">Средняя (за выборку):</span><br>
                ⬇️ <span id="avg_speed_rx" style="color: #4ade80; font-weight: bold;">0.00</span> Mbit/s | ⬆️ <span id="avg_speed_tx" style="color: #60a5fa; font-weight: bold;">0.00</span> Mbit/s
            </div>
            <div style="border-left: 1px dashed #334155; padding-left: 20px; min-width: 180px; text-align: center;">
                <span style="color: #94a3b8;">Пиковая (за сессию):</span><br>
                🔥 <span id="peak_speed_rx" style="color: #4ade80; font-weight: bold;">0.00</span> Mbit/s | 🔥 <span id="peak_speed_tx" style="color: #60a5fa; font-weight: bold;">0.00</span> Mbit/s
            </div>
        </div>
    </div>
</div>

<!-- Neighbors Section -->
<div class="sim-dash">
    <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #374151; padding-bottom: 8px; margin-bottom: 15px; cursor: pointer; user-select: none;" onclick="toggleSpoiler('neighbors_content', 'neighbors_arrow')">
        <h4 style="margin: 0; border: none; padding: 0; display: flex; align-items: center; gap: 8px;">
            <svg id="neighbors_arrow" style="width: 16px; height: 16px; transition: transform 0.3s ease; transform: rotate(90deg);" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M9 5l7 7-7 7"></path>
            </svg>
            Соседние сектора
        </h4>
    </div>
    
    <div id="neighbors_content" style="transition: max-height 0.3s ease-in-out, opacity 0.3s ease-in-out; overflow: hidden;">
        <div id="neighbors_container">
            <% if #neighbours == 0 then %>
                <div class="sim-row" style="color: #9ca3af;">No neighbouring cells detected.</div>
            <% else %>
                <div class="grid-table grid-header">
                    <div>EARFCN</div><div>PCI</div><div>RSSI</div><div>RSRP</div><div>RSRQ</div>
                </div>
                <div class="grid-table">
                    <% for _, nb in ipairs(neighbours) do %>
                        <div class="grid-row" style="display: contents;">
                            <div style="padding: 2px 0; color: #60a5fa;"><%=nb.e%></div>
                            <div style="padding: 2px 0;"><%=nb.pci%></div>
                            <div style="padding: 2px 0;"><%=nb.ri%></div>
                            <div style="padding: 2px 0;"><%=nb.rp%></div>
                            <div style="padding: 2px 0;"><%=nb.rq%></div>
                        </div>
                    <% end %>
                </div>
            <% end %>
        </div>
    </div>
</div>

<div class="sim-dash">
    <h4 style="border-bottom: 1px solid #374151; padding-bottom: 8px;">
        <span style="display: inline-flex; align-items: center; gap: 8px;">
            Информация об устройстве
            <button type="button" id="toggle_mask_btn" onclick="toggleSensitiveMasks()" style="background: none; border: 1px solid #374151; border-radius: 4px; color: #fff; font-size: 12px; cursor: pointer; padding: 2px 6px; line-height: 1;" title="Отобразить">Показать</button>
        </span>
    </h4>
    <%=r_row("Производитель", hw_manuf)%>
    <%=r_row("Модель", hw_model)%>
    <%=r_row("Аппаратная ревизия", hw_rev)%>
    <%=r_row("Версия прошивки", hw_fw)%>
    
    <div class="sim-row"><strong>ID оборудования (IMEI):</strong> <span id="field_imei" data-raw="<%=hw_imei%>"><%= string.rep("*", #hw_imei) %></span></div>
    <div class="sim-row"><strong>SIM IMSI:</strong> <span id="field_imsi" data-raw="<%=hw_imsi%>"><%= string.rep("*", #hw_imsi) %></span></div>
    <div class="sim-row"><strong>Номер телефона:</strong> <span id="field_phone" data-raw="<%=hw_phone%>"><%= string.rep("*", #hw_phone) %></span></div>
</div>

<div class="sim-dash">
    <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #374151; padding-bottom: 8px; margin-bottom: 15px;">
        <h4 style="margin: 0; border: none; padding: 0;">Информация о роутере</h4>
    </div>
    <div class="sim-row"><strong>Температура CPU:</strong> <span id="router_cpu_temp">-</span></div>
    <div class="sim-row"><strong>Температура WiFi:</strong> <span id="router_wifi_temp">-</span></div>
    <div class="sim-row"><strong>Load Average (1м / 5м / 15м):</strong> <span id="router_loadavg">-</span></div>
    
    <!-- Temperature Chart Spoiler -->
    <div style="margin-top: 15px; border-top: 1px solid #262626; padding-top: 10px;">
        <div style="display: flex; justify-content: space-between; align-items: center; cursor: pointer; user-select: none;" onclick="toggleSpoiler('temp_graph_content', 'temp_graph_arrow')">
            <h5 style="margin: 0; display: flex; align-items: center; gap: 8px; color: #e5e7eb; font-weight: normal; font-size: 13px;">
                <svg id="temp_graph_arrow" style="width: 14px; height: 14px; transition: transform 0.3s ease; transform: rotate(0deg);" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M9 5l7 7-7 7"></path>
                </svg>
                График температуры (Temperature)
            </h5>
            <div style="display: flex; align-items: center; gap: 8px;" onclick="event.stopPropagation();">
                <label for="temp_graph_range" style="color: #9ca3af; font-size: 11px;">Диапазон:</label>
                <select id="temp_graph_range" onchange="updateTempGraphRange()" style="background: #171717; color: #d1d5db; border: 1px solid #374151; padding: 1px 4px; border-radius: 4px; outline: none; cursor: pointer; font-size: 11px;">
                    <option value="30">30 сек</option>
                    <option value="60" selected>1 мин</option>
                    <option value="300">5 мин</option>
                </select>
            </div>
        </div>
        
        <div id="temp_graph_content" style="max-height: 0px; opacity: 0; overflow: hidden; transition: max-height 0.3s ease-in-out, opacity 0.3s ease-in-out;">
            <div style="height: 120px; position: relative; background: #171717; border: 1px solid #374151; border-radius: 6px; padding: 10px 10px 0 10px; box-sizing: border-box; overflow: hidden; margin-top: 10px;">
                <canvas id="temp_chart" style="width: 100%; height: 100%; display: block;"></canvas>
            </div>
        </div>
    </div>

    <!-- Load Average Chart Spoiler -->
    <div style="margin-top: 15px; border-top: 1px solid #262626; padding-top: 10px;">
        <div style="display: flex; justify-content: space-between; align-items: center; cursor: pointer; user-select: none;" onclick="toggleSpoiler('load_graph_content', 'load_graph_arrow')">
            <h5 style="margin: 0; display: flex; align-items: center; gap: 8px; color: #e5e7eb; font-weight: normal; font-size: 13px;">
                <svg id="load_graph_arrow" style="width: 14px; height: 14px; transition: transform 0.3s ease; transform: rotate(0deg);" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M9 5l7 7-7 7"></path>
                </svg>
                График нагрузки процессора (Load Average)
            </h5>
            <div style="display: flex; align-items: center; gap: 8px;" onclick="event.stopPropagation();">
                <label for="load_graph_range" style="color: #9ca3af; font-size: 11px;">Диапазон:</label>
                <select id="load_graph_range" onchange="updateLoadGraphRange()" style="background: #171717; color: #d1d5db; border: 1px solid #374151; padding: 1px 4px; border-radius: 4px; outline: none; cursor: pointer; font-size: 11px;">
                    <option value="30">30 сек</option>
                    <option value="60" selected>1 мин</option>
                    <option value="300">5 мин</option>
                </select>
            </div>
        </div>
        
        <div id="load_graph_content" style="max-height: 0px; opacity: 0; overflow: hidden; transition: max-height 0.3s ease-in-out, opacity 0.3s ease-in-out;">
            <div style="height: 120px; position: relative; background: #171717; border: 1px solid #374151; border-radius: 6px; padding: 10px 10px 0 10px; box-sizing: border-box; overflow: hidden; margin-top: 10px;">
                <canvas id="load_chart" style="width: 100%; height: 100%; display: block;"></canvas>
            </div>
        </div>
    </div>
</div> <!-- end of modem_data_container -->

<div class="sim-dash" style="background-color: #0f172a; border-left: 4px solid #3b82f6; padding: 20px; margin-top: 30px;">
    <h4 style="margin: 0 0 15px 0; color: #ffffff;">⚙️ Автоматическое восстановление модема</h4>
    
    <!-- Recovery Service Controls -->
    <div style="display: flex; gap: 20px; align-items: center; background: #1e293b; padding: 12px 16px; border-radius: 6px; margin-bottom: 20px; flex-wrap: wrap; border: 1px solid #334155;">
        <div style="display: flex; align-items: center; gap: 10px;">
            <span style="color: #94a3b8; font-size: 13px; font-weight: 500;">Служба демона:</span>
            <% if is_daemon_running then %>
                <span id="daemon_run_badge" style="padding: 3px 8px; border-radius: 4px; font-weight: bold; font-size: 11px; background: #065f46; color: #34d399; border: 1px solid #047857; text-transform: uppercase; letter-spacing: 0.5px;">Запущена</span>
                <button id="daemon_run_btn" onclick="toggleDaemonRunning(true)" class="btn cbi-button-action" style="padding: 4px 12px; border-radius: 4px; font-size: 12px; font-weight: 600; cursor: pointer; background: #7f1d1d; color: #fca5a5; border: 1px solid #991b1b; transition: all 0.2s;">Стоп</button>
            <% else %>
                <span id="daemon_run_badge" style="padding: 3px 8px; border-radius: 4px; font-weight: bold; font-size: 11px; background: #7f1d1d; color: #fca5a5; border: 1px solid #991b1b; text-transform: uppercase; letter-spacing: 0.5px;">Остановлена</span>
                <button id="daemon_run_btn" onclick="toggleDaemonRunning(false)" class="btn cbi-button-action" style="padding: 4px 12px; border-radius: 4px; font-size: 12px; font-weight: 600; cursor: pointer; background: #1e3a8a; color: #93c5fd; border: 1px solid #1d4ed8; transition: all 0.2s;">Старт</button>
            <% end %>
        </div>
        <div style="height: 20px; width: 1px; background: #334155;"></div>
        <div style="display: flex; align-items: center; gap: 10px;">
            <span style="color: #94a3b8; font-size: 13px; font-weight: 500;">Автозапуск:</span>
            <% if is_daemon_enabled then %>
                <span id="daemon_enable_badge" style="padding: 3px 8px; border-radius: 4px; font-weight: bold; font-size: 11px; background: #065f46; color: #34d399; border: 1px solid #047857; text-transform: uppercase; letter-spacing: 0.5px;">Включен</span>
                <button id="daemon_enable_btn" onclick="toggleDaemonEnabled(true)" class="btn cbi-button-action" style="padding: 4px 12px; border-radius: 4px; font-size: 12px; font-weight: 600; cursor: pointer; background: #374151; color: #d1d5db; border: 1px solid #4b5563; transition: all 0.2s;">Выключить</button>
            <% else %>
                <span id="daemon_enable_badge" style="padding: 3px 8px; border-radius: 4px; font-weight: bold; font-size: 11px; background: #374151; color: #9ca3af; border: 1px solid #4b5563; text-transform: uppercase; letter-spacing: 0.5px;">Отключен</span>
                <button id="daemon_enable_btn" onclick="toggleDaemonEnabled(false)" class="btn cbi-button-action" style="padding: 4px 12px; border-radius: 4px; font-size: 12px; font-weight: 600; cursor: pointer; background: #065f46; color: #34d399; border: 1px solid #047857; transition: all 0.2s;">Включить</button>
            <% end %>
        </div>
    </div>
    
    <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 15px; margin-bottom: 15px;">
        <div>
            <div style="color: #94a3b8; font-size: 12px; margin-bottom: 4px;">Текущее состояние демона</div>
            <div id="rec_current_state" style="font-size: 15px; font-weight: bold; color: <%=state_color%>;"><%=rec_state%></div>
        </div>
        <div>
            <div style="color: #94a3b8; font-size: 12px; margin-bottom: 4px;">Длительность состояния</div>
            <div id="rec_state_duration" style="font-size: 15px; font-weight: bold; color: #ffffff;"><%=format_sec(recovery_metrics.current_state_duration)%></div>
        </div>
        <div>
            <div style="color: #94a3b8; font-size: 12px; margin-bottom: 4px;">Статус службы ModemManager</div>
            <div id="rec_mm_status" style="font-size: 15px; font-weight: bold; color: <%=mm_status_color%>;"><%=recovery_metrics.modemmanager_status or 'Starting'%></div>
        </div>
        <div>
            <div style="color: #94a3b8; font-size: 12px; margin-bottom: 4px;">Количество попыток восстановления подряд</div>
            <div id="rec_consec_count" style="font-size: 15px; font-weight: bold; color: #f59e0b;"><%=recovery_metrics.current_consecutive_recovery_count or '-'%></div>
        </div>
    </div>

    <div style="border-top: 1px solid #334155; padding-top: 15px; margin-bottom: 15px;">
        <h5 style="margin: 0 0 10px 0; color: #f8fafc; font-size: 14px; font-weight: normal;">Статистика запусков восстановления</h5>
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 10px;">
            <div style="background: #1e293b; padding: 10px; border-radius: 4px;">
                <div style="color: #94a3b8; font-size: 11px;">Всего запусков</div>
                <div id="rec_total_count" style="font-size: 18px; font-weight: bold; color: #ffffff;"><%=recovery_metrics.total_recovery_count or 0%></div>
            </div>
            <div style="background: #1e293b; padding: 10px; border-radius: 4px;">
                <div style="color: #94a3b8; font-size: 11px;">1. Рестарт интерфейса</div>
                <div id="rec_iface_count" style="font-size: 18px; font-weight: bold; color: #60a5fa;"><%=recovery_metrics.interface_recovery_count or 0%></div>
            </div>
            <div style="background: #1e293b; padding: 10px; border-radius: 4px;">
                <div style="color: #94a3b8; font-size: 11px;">2. Сброс радио (AT+CFUN)</div>
                <div id="rec_rf_count" style="font-size: 18px; font-weight: bold; color: #a78bfa;"><%=recovery_metrics.rf_recovery_count or 0%></div>
            </div>
            <div style="background: #1e293b; padding: 10px; border-radius: 4px;">
                <div style="color: #94a3b8; font-size: 11px;">2b. Рестарт ModemManager</div>
                <div id="rec_mm_count" style="font-size: 18px; font-weight: bold; color: #fb7185;"><%=recovery_metrics.mm_recovery_count or 0%></div>
            </div>
            <div style="background: #1e293b; padding: 10px; border-radius: 4px;">
                <div style="color: #94a3b8; font-size: 11px;">3. Аппаратный сброс USB</div>
                <div id="rec_usb_count" style="font-size: 18px; font-weight: bold; color: #f59e0b;"><%=recovery_metrics.usb_recovery_count or 0%></div>
            </div>
        </div>
    </div>

    <div style="border-top: 1px solid #334155; padding-top: 15px; margin-bottom: 15px;">
        <h5 style="margin: 0 0 10px 0; color: #f8fafc; font-size: 14px; font-weight: normal;">Накопленное время по состоянию</h5>
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 10px;">
            <div style="background: #1e293b; padding: 10px; border-radius: 4px;">
                <div style="color: #94a3b8; font-size: 11px;">Модем подключен (connected)</div>
                <div id="rec_connected_time" style="font-size: 14px; font-weight: bold; color: #10b981;"><%=format_sec(recovery_metrics.total_connected_duration)%></div>
            </div>
            <div style="background: #1e293b; padding: 10px; border-radius: 4px;">
                <div style="color: #94a3b8; font-size: 11px;">Модем отключен (disabled)</div>
                <div id="rec_disabled_time" style="font-size: 14px; font-weight: bold; color: #fb7185;"><%=format_sec(recovery_metrics.total_disabled_duration)%></div>
            </div>
            <div style="background: #1e293b; padding: 10px; border-radius: 4px;">
                <div style="color: #94a3b8; font-size: 11px;">Отказ сети (denied)</div>
                <div id="rec_denied_time" style="font-size: 14px; font-weight: bold; color: #ef4444;"><%=format_sec(recovery_metrics.total_denied_duration)%></div>
            </div>
            <div style="background: #1e293b; padding: 10px; border-radius: 4px;">
                <div style="color: #94a3b8; font-size: 11px;">Модем отсутствует (missing)</div>
                <div id="rec_missing_time" style="font-size: 14px; font-weight: bold; color: #f87171;"><%=format_sec(recovery_metrics.total_missing_duration)%></div>
            </div>
            <div style="background: #1e293b; padding: 10px; border-radius: 4px;">
                <div style="color: #94a3b8; font-size: 11px;">Нет регистрации (searching/enabled)</div>
                <div id="rec_unreg_time" style="font-size: 14px; font-weight: bold; color: #fb923c;"><%=format_sec(recovery_metrics.total_unregistered_duration)%></div>
            </div>
            <div style="background: #1e293b; padding: 10px; border-radius: 4px;">
                <div style="color: #94a3b8; font-size: 11px;">Нет IP адреса (registered)</div>
                <div id="rec_no_ip_time" style="font-size: 14px; font-weight: bold; color: #facc15;"><%=format_sec(recovery_metrics.total_no_ip_duration)%></div>
            </div>
            <div style="background: #1e293b; padding: 10px; border-radius: 4px;">
                <div style="color: #94a3b8; font-size: 11px;">Не проходит пинг (registered)</div>
                <div id="rec_no_ping_time" style="font-size: 14px; font-weight: bold; color: #f87171;"><%=format_sec(recovery_metrics.total_no_ping_duration)%></div>
            </div>
        </div>
    </div>

    <div style="border-top: 1px solid #334155; padding-top: 15px; font-size: 13px; color: #94a3b8; line-height: 1.6;">
        <div style="margin-bottom: 6px;"><strong style="color: #ffffff; min-width: 160px; display: inline-block;">Последнее действие:</strong> <span id="rec_last_type" style="color: #f59e0b; font-weight: bold;"><%=recovery_metrics.last_recovery_type or '-'%></span></div>
        <div style="margin-bottom: 6px;"><strong style="color: #ffffff; min-width: 160px; display: inline-block;">Время действия:</strong> <span id="rec_last_time" style="color: #ffffff;"><%=recovery_metrics.last_recovery_time or '-'%></span></div>
        <div><strong style="color: #ffffff; min-width: 160px; display: inline-block;">Причина:</strong> <span id="rec_last_reason" style="color: #94a3b8; font-family: monospace; font-size: 12px; word-break: break-all;"><%=recovery_metrics.last_recovery_reason or '-'%></span></div>
    </div>
</div>

<div class="sim-dash" style="background-color: #1e293b; border-left: 4px solid #f59e0b; padding: 20px; margin-top: 30px;">
    <h4 style="margin: 0 0 15px 0; color: #ffffff;">⚠️ Устранение неполадок и диагностика</h4>
    <p style="color: #94a3b8; font-size: 13px; margin: 0 0 15px 0;">Если соединение с интернетом нестабильно, вы можете принудительно перезапустить службы или выгрузить логи.</p>
    <div style="display: flex; gap: 15px; flex-wrap: wrap;">
        <a href="?action=restart_mm" style="display: inline-block; padding: 8px 16px; background-color: #3b82f6; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезапуск службы ModemManager...')">Перезапустить ModemManager</a>
        <a href="?action=restart_iface" style="display: inline-block; padding: 8px 16px; background-color: #f59e0b; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезапуск интерфейса MODEM...')">Перезапустить интерфейс MODEM</a>
        <a href="?action=restart_rf" style="display: inline-block; padding: 8px 16px; background-color: #10b981; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезапуск радиомодуля (RF)...')">Перезапустить RF</a>
        <a href="javascript:void(0)" onclick="resetUsbPort();" style="display: inline-block; padding: 8px 16px; background-color: #8b5cf6; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;">Сбросить USB порт модема</a>
        <a href="?action=reset_modem&qmi_dev=<%=qmi_dev%>" style="display: inline-block; padding: 8px 16px; background-color: #ef4444; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезагрузка модема (QMI)...')">Перезагрузить модем</a>
    </div>
</div>

<div class="sim-dash" style="display: flex; align-items: center; gap: 15px; flex-wrap: wrap;">
    <button type="button" class="cbi-button cbi-button-action" onclick="fetchModemData();">Обновить информацию</button>
    <button type="button" class="cbi-button" id="log_repair_btn" onclick="logManualRepair();" style="background: #ea580c; color: #fff; border: 1px solid #c2410c; padding: 6px 12px; border-radius: 4px; font-weight: bold; cursor: pointer; transition: all 0.2s ease;" onmouseover="this.style.background='#d97706'" onmouseout="this.style.background='#ea580c'">Записать в лог ручное поднятие инета</button>
    <button type="button" id="save_logs_btn" onclick="saveLossLogs();" style="background: #8b5cf6; color: #fff; border: 1px solid #7c3aed; padding: 6px 12px; border-radius: 4px; font-weight: bold; cursor: pointer; transition: all 0.2s ease;" onmouseover="this.style.background='#7c3aed'" onmouseout="this.style.background='#8b5cf6'">Сохранить логи</button>
    <div style="display: flex; align-items: center; gap: 10px; color: #9ca3af; border-left: 1px solid #374151; padding-left: 15px;">
        <label for="auto_refresh">Автообновление:</label>
        <select id="auto_refresh" onchange="setAutoRefresh()" style="background: #262626; color: #d1d5db; border: 1px solid #374151; padding: 4px 8px; border-radius: 4px; outline: none; cursor: pointer;">
            <option value="0">Выкл</option>
            <option value="1">1 сек</option>
            <option value="3">3 сек</option>
            <option value="5">5 сек</option>
            <option value="10">10 сек</option>
        </select>
    </div>
    <div id="refresh_timer" style="color: #60a5fa; font-family: monospace; font-size: 13px;"></div>
</div>

<script>
const qs=s=>document.querySelectorAll(s);
window.g=i=>document.getElementById(i);
let mAct=false,cDown=parseInt(localStorage.getItem('m_re') === null ? '5' : localStorage.getItem('m_re')),tId,isFetching=false;
let chartData = [];
let graphRange = 60;
let sessionMaxRx = 0;
let sessionMaxTx = 0;
let loadChartData = [];
let loadGraphRange = 60;
let tempChartData = [];
let tempGraphRange = 60;
let isSimInteracted = false;
let isActionPending = false;

function toggleSpoiler(contentId, arrowId) {
    const content = g(contentId);
    const arrow = g(arrowId);
    if (!content || !arrow) return;
    
    const isCollapsed = content.style.maxHeight === '0px' || content.classList.contains('collapsed');
    if (isCollapsed) {
        content.style.maxHeight = '1000px';
        content.style.opacity = '1';
        arrow.style.transform = 'rotate(90deg)';
        content.classList.remove('collapsed');
        localStorage.setItem(contentId, 'expanded');
        if (contentId === 'load_graph_content') setTimeout(drawLoadChart, 10);
        if (contentId === 'temp_graph_content') setTimeout(drawTempChart, 10);
    } else {
        content.style.maxHeight = '0px';
        content.style.opacity = '0';
        arrow.style.transform = 'rotate(0deg)';
        content.classList.add('collapsed');
        localStorage.setItem(contentId, 'collapsed');
    }
}

function initSpoilers() {
    ['speed_graph_content', 'neighbors_content', 'nr_content', 'load_graph_content', 'temp_graph_content'].forEach(contentId => {
        let arrowId, defaultState;
        if (contentId === 'speed_graph_content') {
            arrowId = 'speed_graph_arrow';
            defaultState = 'expanded';
        } else if (contentId === 'neighbors_content') {
            arrowId = 'neighbors_arrow';
            defaultState = 'collapsed';
        } else if (contentId === 'nr_content') {
            arrowId = 'nr_arrow';
            const badge = g('nr_status_badge');
            defaultState = (badge && badge.getAttribute('data-active') === 'true') ? 'expanded' : 'collapsed';
        } else if (contentId === 'load_graph_content') {
            arrowId = 'load_graph_arrow';
            defaultState = 'collapsed';
        } else if (contentId === 'temp_graph_content') {
            arrowId = 'temp_graph_arrow';
            defaultState = 'collapsed';
        }
        
        const state = localStorage.getItem(contentId) || defaultState;
        const content = g(contentId);
        const arrow = g(arrowId);
        if (content && arrow) {
            if (state === 'collapsed') {
                content.style.maxHeight = '0px';
                content.style.opacity = '0';
                arrow.style.transform = 'rotate(0deg)';
                content.classList.add('collapsed');
            } else {
                content.style.maxHeight = '1000px';
                content.style.opacity = '1';
                arrow.style.transform = 'rotate(90deg)';
                content.classList.remove('collapsed');
                if (contentId === 'load_graph_content') setTimeout(drawLoadChart, 150);
                if (contentId === 'temp_graph_content') setTimeout(drawTempChart, 150);
            }
        }
    });
}

function toggleSensitiveMasks(){
    let b=g('toggle_mask_btn');
    mAct=!mAct;
    ['imei','imsi','phone'].forEach(k=>{
        let n=g('field_'+k),r=n.getAttribute('data-raw');
        n.innerText=mAct?r:('*'.repeat(r.length))}
    );
    b.innerText=mAct?"Скрыть":"Показать";
    b.title=mAct?"Скрыть":"Показать"
}

function logManualRepair() {
    const btn = g('log_repair_btn');
    if (!btn) return;
    const originalText = btn.innerText;
    const url = '<%=luci.dispatcher.build_url("admin/modem/log_manual_repair")%>';
    
    btn.disabled = true;
    btn.innerText = 'Запись...';
    
    fetch(url)
        .then(res => res.json())
        .then(data => {
            if (data.success) {
                btn.innerText = '✔️ Успешно записано!';
                btn.style.background = '#16a34a';
                btn.style.borderColor = '#15803d';
            } else {
                btn.innerText = '❌ Ошибка записи';
                btn.style.background = '#dc2626';
            }
            setTimeout(() => {
                btn.disabled = false;
                btn.innerText = originalText;
                btn.style.background = '#ea580c';
                btn.style.borderColor = '#c2410c';
            }, 2000);
        })
        .catch(err => {
            console.error('Logging failed:', err);
            btn.innerText = '❌ Ошибка сети';
            setTimeout(() => {
                btn.disabled = false;
                btn.innerText = originalText;
                btn.style.background = '#ea580c';
                btn.style.borderColor = '#c2410c';
            }, 2000);
        });
}

function validateForm(){
    let i=parseInt(document.getElementsByName('ttl_in')[0].value),o=parseInt(document.getElementsByName('ttl_out')[0].value),e=g('ttl_err');
    e.innerText="";
    if(isNaN(i)||i<1||i>255||isNaN(o)||o<1||o>255){
        e.innerText="Ошибка: Значения TTL должны быть целыми числами строго в диапазоне от 1 до 255!";
        return !1
    }
    
    // Stop all auto-refresh calls immediately to avoid clashing with the apply POST command!
    clearTimeout(tId);
    cDown = 99999;
    
    g('apply_overlay').style.display = 'flex';
    return !0
}

function clearBands(){
    qs('input[name="cb_band"]').forEach(c=>{
        c.checked=!1;
        c.parentNode.classList.remove('active-band')}
    )
}

function selectAllBands(){
    qs('input[name="cb_band"]').forEach(c=>{
        c.checked=!0;
        c.parentNode.classList.add('active-band')}
    )
}

function updateRadioStyles(n){
    qs('input[name="'+n+'"]').forEach(r=>r.parentNode.classList.toggle('active-band',r.checked))
}

function drawChart() {
    const canvas = g('speed_chart');
    if (!canvas) return;
    const rect = canvas.parentNode.getBoundingClientRect();
    canvas.width = rect.width * window.devicePixelRatio;
    canvas.height = rect.height * window.devicePixelRatio;
    const ctx = canvas.getContext('2d');
    ctx.scale(window.devicePixelRatio, window.devicePixelRatio);

    const w = rect.width;
    const h = rect.height;

    ctx.clearRect(0, 0, w, h);

    const now = Math.floor(Date.now() / 1000);
    const filtered = chartData.filter(d => (now - d.time) <= graphRange);

    if (filtered.length === 0) {
        ctx.strokeStyle = '#262626';
        ctx.lineWidth = 1;
        ctx.beginPath();
        for(let i=1; i<4; i++) {
            let y = ((h - 25) / 4) * i;
            ctx.moveTo(0, y); ctx.lineTo(w, y);
        }
        ctx.stroke();
        ctx.fillStyle = '#6b7280';
        ctx.font = '12px monospace';
        ctx.textAlign = 'center';
        ctx.fillText('Ожидание данных скорости...', w/2, (h - 25)/2);
        return;
    }

    let maxVal = 0.5;
    let sumRx = 0, sumTx = 0, count = filtered.length;
    filtered.forEach(d => {
        if (d.rx > maxVal) maxVal = d.rx;
        if (d.tx > maxVal) maxVal = d.tx;
        
        sumRx += d.rx;
        sumTx += d.tx;
        
        if (d.rx > sessionMaxRx) sessionMaxRx = d.rx;
        if (d.tx > sessionMaxTx) sessionMaxTx = d.tx;
    });
    
    let avgRx = count > 0 ? (sumRx / count) : 0;
    let avgTx = count > 0 ? (sumTx / count) : 0;
    
    // Update Avg / Peak UI elements
    if (g('avg_speed_rx')) g('avg_speed_rx').innerText = avgRx.toFixed(2);
    if (g('avg_speed_tx')) g('avg_speed_tx').innerText = avgTx.toFixed(2);
    if (g('peak_speed_rx')) g('peak_speed_rx').innerText = sessionMaxRx.toFixed(2);
    if (g('peak_speed_tx')) g('peak_speed_tx').innerText = sessionMaxTx.toFixed(2);

    maxVal = Math.ceil(maxVal * 1.15);

    // Draw horizontal grid lines
    ctx.strokeStyle = '#262626';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for(let i=1; i<4; i++) {
        let y = ((h - 25) / 4) * i;
        ctx.moveTo(0, y); ctx.lineTo(w, y);
    }
    ctx.stroke();

    // Draw speed labels
    ctx.fillStyle = '#6b7280';
    ctx.font = '10px monospace';
    ctx.textAlign = 'left';
    ctx.fillText(maxVal.toFixed(1) + ' Mbit/s', 5, 12);
    ctx.fillText((maxVal / 2).toFixed(1) + ' Mbit/s', 5, (h - 25)/2 + 4);

    // Draw timeline ticks and labels at the bottom
    ctx.fillStyle = '#6b7280';
    ctx.font = '9px monospace';
    ctx.textAlign = 'center';
    
    const ticksCount = 5;
    for (let i = 0; i <= ticksCount; i++) {
        const x = w - (i / ticksCount) * w;
        const timeOffset = (i / ticksCount) * graphRange;
        let timeLabel = '';
        if (timeOffset === 0) {
            timeLabel = 'Сейчас';
        } else if (timeOffset >= 60) {
            timeLabel = '-' + (timeOffset / 60).toFixed(0) + 'м';
        } else {
            timeLabel = '-' + timeOffset.toFixed(0) + 'с';
        }
        
        ctx.strokeStyle = '#374151';
        ctx.beginPath();
        ctx.moveTo(x, h - 22);
        ctx.lineTo(x, h - 26);
        ctx.stroke();
        
        ctx.fillText(timeLabel, x, h - 8);
    }

    const drawLine = (key, strokeColor, fillColor) => {
        ctx.beginPath();
        const points = [];
        const timeWindow = graphRange;
        
        for (let i = 0; i < filtered.length; i++) {
            const d = filtered[i];
            const age = now - d.time;
            if (age > timeWindow) continue;
            
            const x = w - (age / timeWindow) * w;
            const y = h - 25 - (d[key] / maxVal) * (h - 45); // padded
            points.push({x, y});
        }

        if (points.length < 2) return;

        ctx.beginPath();
        ctx.moveTo(points[0].x, points[0].y);
        for (let i = 1; i < points.length; i++) {
            ctx.lineTo(points[i].x, points[i].y);
        }
        ctx.strokeStyle = strokeColor;
        ctx.lineWidth = 2;
        ctx.stroke();

        ctx.lineTo(points[points.length - 1].x, h - 22);
        ctx.lineTo(points[0].x, h - 22);
        ctx.closePath();
        ctx.fillStyle = fillColor;
        ctx.fill();
    };

    drawLine('rx', '#4ade80', 'rgba(74, 222, 128, 0.1)');
    drawLine('tx', '#60a5fa', 'rgba(96, 165, 250, 0.1)');
}

function updateLoadGraphRange() {
    loadGraphRange = parseInt(g('load_graph_range').value);
    drawLoadChart();
}

function drawLoadChart() {
    const canvas = g('load_chart');
    if (!canvas) return;
    const rect = canvas.parentNode.getBoundingClientRect();
    canvas.width = rect.width * window.devicePixelRatio;
    canvas.height = rect.height * window.devicePixelRatio;
    const ctx = canvas.getContext('2d');
    ctx.scale(window.devicePixelRatio, window.devicePixelRatio);

    const w = rect.width;
    const h = rect.height;

    ctx.clearRect(0, 0, w, h);

    const now = Math.floor(Date.now() / 1000);
    const filtered = loadChartData.filter(d => (now - d.time) <= loadGraphRange);

    if (filtered.length === 0) {
        ctx.strokeStyle = '#262626';
        ctx.lineWidth = 1;
        ctx.beginPath();
        for(let i=1; i<4; i++) {
            let y = ((h - 25) / 4) * i;
            ctx.moveTo(0, y); ctx.lineTo(w, y);
        }
        ctx.stroke();
        ctx.fillStyle = '#6b7280';
        ctx.font = '12px monospace';
        ctx.textAlign = 'center';
        ctx.fillText('Ожидание данных нагрузки...', w/2, (h - 25)/2);
        return;
    }

    let maxVal = 1.0;
    filtered.forEach(d => {
        if (d.val > maxVal) maxVal = d.val;
    });

    maxVal = Math.ceil(maxVal * 1.15 * 10) / 10;

    // Draw horizontal grid lines
    ctx.strokeStyle = '#262626';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for(let i=1; i<4; i++) {
        let y = ((h - 25) / 4) * i;
        ctx.moveTo(0, y); ctx.lineTo(w, y);
    }
    ctx.stroke();

    // Draw labels
    ctx.fillStyle = '#6b7280';
    ctx.font = '10px monospace';
    ctx.textAlign = 'left';
    ctx.fillText(maxVal.toFixed(2) + ' Load', 5, 12);
    ctx.fillText((maxVal / 2).toFixed(2) + ' Load', 5, (h - 25)/2 + 4);

    // Draw timeline ticks and labels at the bottom
    ctx.fillStyle = '#6b7280';
    ctx.font = '9px monospace';
    ctx.textAlign = 'center';
    
    const ticksCount = 5;
    for (let i = 0; i <= ticksCount; i++) {
        const x = w - (i / ticksCount) * w;
        const timeOffset = (i / ticksCount) * loadGraphRange;
        let timeLabel = '';
        if (timeOffset === 0) {
            timeLabel = 'Сейчас';
        } else if (timeOffset >= 60) {
            timeLabel = '-' + (timeOffset / 60).toFixed(0) + 'м';
        } else {
            timeLabel = '-' + timeOffset.toFixed(0) + 'с';
        }
        
        ctx.strokeStyle = '#374151';
        ctx.beginPath();
        ctx.moveTo(x, h - 22);
        ctx.lineTo(x, h - 26);
        ctx.stroke();
        
        ctx.fillText(timeLabel, x, h - 8);
    }

    ctx.beginPath();
    const points = [];
    const timeWindow = loadGraphRange;
    
    for (let i = 0; i < filtered.length; i++) {
        const d = filtered[i];
        const age = now - d.time;
        if (age > timeWindow) continue;
        
        const x = w - (age / timeWindow) * w;
        const y = h - 25 - (d.val / maxVal) * (h - 45); // padded
        points.push({x, y});
    }

    if (points.length < 2) return;

    ctx.beginPath();
    ctx.moveTo(points[0].x, points[0].y);
    for (let i = 1; i < points.length; i++) {
        ctx.lineTo(points[i].x, points[i].y);
    }
    ctx.strokeStyle = '#f59e0b';
    ctx.lineWidth = 2;
    ctx.stroke();

    ctx.lineTo(points[points.length - 1].x, h - 22);
    ctx.lineTo(points[0].x, h - 22);
    ctx.closePath();
    ctx.fillStyle = 'rgba(245, 158, 11, 0.1)';
    ctx.fill();
}

function updateTempGraphRange() {
    tempGraphRange = parseInt(g('temp_graph_range').value);
    drawTempChart();
}

function drawTempChart() {
    const canvas = g('temp_chart');
    if (!canvas) return;
    const rect = canvas.parentNode.getBoundingClientRect();
    canvas.width = rect.width * window.devicePixelRatio;
    canvas.height = rect.height * window.devicePixelRatio;
    const ctx = canvas.getContext('2d');
    ctx.scale(window.devicePixelRatio, window.devicePixelRatio);

    const w = rect.width;
    const h = rect.height;

    ctx.clearRect(0, 0, w, h);

    const now = Math.floor(Date.now() / 1000);
    const filtered = tempChartData.filter(d => (now - d.time) <= tempGraphRange);

    if (filtered.length === 0) {
        ctx.strokeStyle = '#262626';
        ctx.lineWidth = 1;
        ctx.beginPath();
        for(let i=1; i<4; i++) {
            let y = ((h - 25) / 4) * i;
            ctx.moveTo(0, y); ctx.lineTo(w, y);
        }
        ctx.stroke();
        ctx.fillStyle = '#6b7280';
        ctx.font = '12px monospace';
        ctx.textAlign = 'center';
        ctx.fillText(_t('Ожидание данных температуры...'), w/2, (h - 25)/2);
        return;
    }

    let minVal = 30.0;
    let maxVal = 85.0;
    
    filtered.forEach(d => {
        if (d.cpu > maxVal) maxVal = d.cpu;
        if (d.cpu < minVal) minVal = d.cpu;
        if (d.wifi !== null) {
            if (d.wifi > maxVal) maxVal = d.wifi;
            if (d.wifi < minVal) minVal = d.wifi;
        }
    });

    minVal = Math.floor(Math.max(0, minVal - 5));
    maxVal = Math.ceil(maxVal + 5);

    ctx.strokeStyle = '#262626';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for(let i=1; i<4; i++) {
        let y = ((h - 25) / 4) * i;
        ctx.moveTo(0, y); ctx.lineTo(w, y);
    }
    ctx.stroke();

    ctx.fillStyle = '#6b7280';
    ctx.font = '10px monospace';
    ctx.textAlign = 'left';
    ctx.fillText(maxVal.toFixed(0) + ' °C', 5, 12);
    ctx.fillText(((maxVal + minVal) / 2).toFixed(0) + ' °C', 5, (h - 25)/2 + 4);
    ctx.fillText(minVal.toFixed(0) + ' °C', 5, h - 30);

    ctx.textAlign = 'right';
    ctx.fillStyle = '#f87171';
    ctx.fillText('CPU', w - 45, 12);
    ctx.fillStyle = '#60a5fa';
    ctx.fillText('WiFi', w - 10, 12);

    ctx.fillStyle = '#6b7280';
    ctx.font = '9px monospace';
    ctx.textAlign = 'center';
    
    const ticksCount = 5;
    for (let i = 0; i <= ticksCount; i++) {
        const x = w - (i / ticksCount) * w;
        const timeOffset = (i / ticksCount) * tempGraphRange;
        let timeLabel = '';
        if (timeOffset === 0) {
            timeLabel = _t('Сейчас');
        } else if (timeOffset >= 60) {
            timeLabel = '-' + (timeOffset / 60).toFixed(0) + _t('м');
        } else {
            timeLabel = '-' + timeOffset.toFixed(0) + _t('с');
        }
        
        ctx.strokeStyle = '#374151';
        ctx.beginPath();
        ctx.moveTo(x, h - 22);
        ctx.lineTo(x, h - 26);
        ctx.stroke();
        
        ctx.fillText(timeLabel, x, h - 8);
    }

    const drawLine = (key, color) => {
        const points = [];
        const timeWindow = tempGraphRange;
        
        for (let i = 0; i < filtered.length; i++) {
            const d = filtered[i];
            if (d[key] === null) continue;
            const age = now - d.time;
            if (age > timeWindow) continue;
            
            const x = w - (age / timeWindow) * w;
            const y = h - 25 - ((d[key] - minVal) / (maxVal - minVal)) * (h - 45);
            points.push({x, y});
        }

        if (points.length < 2) return;

        ctx.beginPath();
        ctx.moveTo(points[0].x, points[0].y);
        for (let i = 1; i < points.length; i++) {
            ctx.lineTo(points[i].x, points[i].y);
        }
        ctx.strokeStyle = color;
        ctx.lineWidth = 2;
        ctx.stroke();

        ctx.lineTo(points[points.length - 1].x, h - 22);
        ctx.lineTo(points[0].x, h - 22);
        ctx.closePath();
        ctx.fillStyle = color === '#f87171' ? 'rgba(248, 113, 113, 0.05)' : 'rgba(96, 165, 250, 0.05)';
        ctx.fill();
    };

    drawLine('cpu', '#f87171');
    drawLine('wifi', '#60a5fa');
}


function updateGraphRange() {
    graphRange = parseInt(g('graph_range').value);
    drawChart();
}

function updateDaemonUI(running, enabled) {
    const runBadge = g('daemon_run_badge');
    const runBtn = g('daemon_run_btn');
    if (runBadge && runBtn) {
        if (running) {
            runBadge.innerText = _t('Запущена');
            runBadge.style.background = '#065f46';
            runBadge.style.color = '#34d399';
            runBadge.style.borderColor = '#047857';
            runBtn.innerText = _t('Стоп');
            runBtn.style.background = '#7f1d1d';
            runBtn.style.color = '#fca5a5';
            runBtn.style.borderColor = '#991b1b';
            runBtn.setAttribute('onclick', 'toggleDaemonRunning(true)');
        } else {
            runBadge.innerText = _t('Остановлена');
            runBadge.style.background = '#7f1d1d';
            runBadge.style.color = '#fca5a5';
            runBadge.style.borderColor = '#991b1b';
            runBtn.innerText = _t('Старт');
            runBtn.style.background = '#1e3a8a';
            runBtn.style.color = '#93c5fd';
            runBtn.style.borderColor = '#1d4ed8';
            runBtn.setAttribute('onclick', 'toggleDaemonRunning(false)');
        }
    }

    const enBadge = g('daemon_enable_badge');
    const enBtn = g('daemon_enable_btn');
    if (enBadge && enBtn) {
        if (enabled) {
            enBadge.innerText = _t('Включен');
            enBadge.style.background = '#065f46';
            enBadge.style.color = '#34d399';
            enBadge.style.borderColor = '#047857';
            enBtn.innerText = _t('Выключить');
            enBtn.style.background = '#374151';
            enBtn.style.color = '#d1d5db';
            enBtn.style.borderColor = '#4b5563';
            enBtn.setAttribute('onclick', 'toggleDaemonEnabled(true)');
        } else {
            enBadge.innerText = _t('Отключен');
            enBadge.style.background = '#374151';
            enBadge.style.color = '#9ca3af';
            enBadge.style.borderColor = '#4b5563';
            enBtn.innerText = _t('Включить');
            enBtn.style.background = '#065f46';
            enBtn.style.color = '#34d399';
            enBtn.style.borderColor = '#047857';
            enBtn.setAttribute('onclick', 'toggleDaemonEnabled(false)');
        }
    }
}

function toggleDaemonRunning(currentRunning) {
    if (isActionPending) return;
    isActionPending = true;
    
    const runBtn = g('daemon_run_btn');
    if (runBtn) {
        runBtn.disabled = true;
        runBtn.innerText = '⏳...';
    }
    
    const action = currentRunning ? 'stop' : 'start';
    const url = '<%=luci.dispatcher.build_url("admin/modem/recovery_action")%>?action=' + action;
    
    fetch(url)
        .then(res => res.json())
        .then(data => {
            isActionPending = false;
            if (runBtn) runBtn.disabled = false;
            if (data && data.success) {
                fetchModemData();
            } else {
                alert('Ошибка при управлении службой.');
                fetchModemData();
            }
        })
        .catch(err => {
            isActionPending = false;
            if (runBtn) runBtn.disabled = false;
            alert('Ошибка сети: ' + err);
            fetchModemData();
        });
}

function toggleDaemonEnabled(currentEnabled) {
    if (isActionPending) return;
    isActionPending = true;
    
    const enBtn = g('daemon_enable_btn');
    if (enBtn) {
        enBtn.disabled = true;
        enBtn.innerText = '⏳...';
    }
    
    const action = currentEnabled ? 'disable' : 'enable';
    const url = '<%=luci.dispatcher.build_url("admin/modem/recovery_action")%>?action=' + action;
    
    fetch(url)
        .then(res => res.json())
        .then(data => {
            isActionPending = false;
            if (enBtn) enBtn.disabled = false;
            if (data && data.success) {
                fetchModemData();
            } else {
                alert('Ошибка при изменении автозапуска.');
                fetchModemData();
            }
        })
        .catch(err => {
            isActionPending = false;
            if (enBtn) enBtn.disabled = false;
            alert('Ошибка сети: ' + err);
            fetchModemData();
        });
}

function fetchModemData() {
    if (isFetching) {
        console.log('Skipping poll tick - previous fetch is still pending');
        return;
    }
    isFetching = true;
    
    const dev = g('modem_interface_select').value;
    const url = '<%=luci.dispatcher.build_url("admin/modem/data")%>?qmi_dev=' + encodeURIComponent(dev);
    
    fetch(url)
        .then(res => res.json())
        .then(data => {
            if (data.success) {
                if (!isActionPending) {
                    updateDaemonUI(data.recovery_daemon_running, data.recovery_daemon_enabled);
                }
                // Update visibility of wrappers
                if (data.has_modem) {
                    g('modem_data_container').style.display = 'block';
                    g('no_modem_banner').style.display = 'none';
                } else {
                    g('modem_data_container').style.display = 'none';
                    g('no_modem_banner').style.display = 'block';
                }

                // Update Recovery Metrics (visible in both states)
                const metrics = data.recovery_metrics || {};
                const formatSec = (s) => {
                    if (s === undefined || s === null || isNaN(s)) return '0с';
                    if (s < 60) return s + 'с';
                    let m = Math.floor(s / 60);
                    let r = s % 60;
                    if (m < 60) return m + 'м ' + r + 'с';
                    let h = Math.floor(m / 60);
                    let rm = m % 60;
                    return h + 'ч ' + rm + 'м ' + r + 'с';
                };

                const recState = metrics.current_state || 'Starting';
                const recStateEl = g('rec_current_state');
                if (recStateEl) {
                    recStateEl.innerText = recState;
                    if (recState === 'Connected') {
                        recStateEl.style.color = '#10b981';
                    } else if (recState === 'Missing' || recState === 'Denied' || recState.includes('Failed')) {
                        recStateEl.style.color = '#ef4444';
                    } else {
                        recStateEl.style.color = '#fb923c';
                    }
                }

                const recDurEl = g('rec_state_duration');
                if (recDurEl) recDurEl.innerText = formatSec(metrics.current_state_duration);

                const mmStatus = metrics.modemmanager_status || 'Starting';
                const mmStatusEl = g('rec_mm_status');
                if (mmStatusEl) {
                    mmStatusEl.innerText = mmStatus;
                    mmStatusEl.style.color = mmStatus === 'Running' ? '#10b981' : '#ef4444';
                }

                const consecEl = g('rec_consec_count');
                if (consecEl) consecEl.innerText = metrics.current_consecutive_recovery_count !== undefined ? metrics.current_consecutive_recovery_count : '-';
                
                const totEl = g('rec_total_count');
                if (totEl) totEl.innerText = metrics.total_recovery_count || '0';
                
                const ifaceEl = g('rec_iface_count');
                if (ifaceEl) ifaceEl.innerText = metrics.interface_recovery_count || '0';
                
                const rfEl = g('rec_rf_count');
                if (rfEl) rfEl.innerText = metrics.rf_recovery_count || '0';
                
                const mmRecEl = g('rec_mm_count');
                if (mmRecEl) mmRecEl.innerText = metrics.mm_recovery_count || '0';
                
                const usbEl = g('rec_usb_count');
                if (usbEl) usbEl.innerText = metrics.usb_recovery_count || '0';

                const connEl = g('rec_connected_time');
                if (connEl) connEl.innerText = formatSec(metrics.total_connected_duration);

                const disEl = g('rec_disabled_time');
                if (disEl) disEl.innerText = formatSec(metrics.total_disabled_duration);

                const denEl = g('rec_denied_time');
                if (denEl) denEl.innerText = formatSec(metrics.total_denied_duration);

                const misEl = g('rec_missing_time');
                if (misEl) misEl.innerText = formatSec(metrics.total_missing_duration);
                
                const unregEl = g('rec_unreg_time');
                if (unregEl) unregEl.innerText = formatSec(metrics.total_unregistered_duration);
                
                const noipEl = g('rec_no_ip_time');
                if (noipEl) noipEl.innerText = formatSec(metrics.total_no_ip_duration);
                
                const nopingEl = g('rec_no_ping_time');
                if (nopingEl) nopingEl.innerText = formatSec(metrics.total_no_ping_duration);

                const lastTypeEl = g('rec_last_type');
                if (lastTypeEl) lastTypeEl.innerText = metrics.last_recovery_type || '-';
                
                const lastTimeEl = g('rec_last_time');
                if (lastTimeEl) lastTimeEl.innerText = metrics.last_recovery_time || '-';
                
                const lastReasonEl = g('rec_last_reason');
                if (lastReasonEl) lastReasonEl.innerText = metrics.last_recovery_reason || '-';

                if (data.has_modem) {
                    // Update basic metrics
                if (!isSimInteracted) {
                    const activeSim = data.active_sim_current;
                    const activeRadio = document.querySelector(`input[name="switch_sim"][value="${activeSim}"]`);
                    if (activeRadio) {
                        activeRadio.checked = true;
                        updateRadioStyles("switch_sim");
                    }
                }
                g('plmn_display_row').innerHTML = `<strong>${_t('Сеть (PLMN):')}</strong> ${_t(data.plmn_display)}`;
                let stateColor = '#4ade80';
                if (data.state_str.toLowerCase().includes('failed')) {
                    stateColor = '#f87171';
                } else if (data.state_str.toLowerCase().includes('searching') || data.state_str.toLowerCase().includes('registering')) {
                    stateColor = '#fb923c';
                }
                g('state_str_row').innerHTML = `<strong>${_t('Статус (технология):')}</strong> <span style="font-weight:bold; color:${stateColor};">${_t(data.state_str)}</span>`;
                g('uptime_str_row').innerHTML = `<strong>${_t('Время сессии:')}</strong> <span style="color:#f59e0b; font-weight:bold;">${data.uptime_str}</span>`;
                g('ip_addr_row').innerHTML = `<strong>${_t('IP-адрес (WWAN):')}</strong> <span style="color:#10b981; font-weight:bold;">${data.ip_addr}</span>`;
                g('traffic_row').innerHTML = `<strong>${_t('Трафик (Прием / Отдача):')}</strong> <span style="color:#3b82f6;">${data.rx_mb}</span> MB / <span style="color:#ec4899;">${data.tx_mb}</span> MB`;
                g('total_mb_row').innerHTML = `<strong>${_t('Общий трафик:')}</strong> <span style="font-weight:bold;">${data.total_mb}</span> MB`;
                g('nsa_display_row').innerHTML = `<strong>${_t('Доступность сети 5G NSA:')}</strong> ${_t(data.nsa_display_init)}`;
                if (data.fourcells_url && data.fourcells_url !== '') {
                    g('fourcells_row').style.display = 'block';
                    g('fourcells_link').innerHTML = `<a href="${data.fourcells_url}" target="_blank" style="color: #60a5fa; text-decoration: underline;">${_t('ссылка на 4cells (доступно не всегда)')}</a>`;
                } else {
                    g('fourcells_row').style.display = 'none';
                }
                g('tx_power_row').innerHTML = `<strong>${_t('Мощность передатчика:')}</strong> ${data.tx_power}`;

                // Toggle Blocks
                g('umts_block').style.display = data.is_umts ? 'block' : 'none';
                g('lte_block').style.display = data.is_umts ? 'none' : 'block';
                
                // Calculate 5G activity
                const isNrActive = (data.nr_band && data.nr_band !== '-') || 
                                   (data.nr_rsrp && data.nr_rsrp !== 'n/a' && data.nr_rsrp !== '-');
                
                // Update badge state & styles
                const badge = g('nr_status_badge');
                if (badge) {
                    badge.setAttribute('data-active', isNrActive ? 'true' : 'false');
                    badge.innerText = isNrActive ? _t('Активно') : _t('Не активно');
                    badge.style.cssText = isNrActive 
                        ? 'font-size: 12px; font-weight: bold; padding: 2px 8px; border-radius: 4px; background: #c084fc; color: #1e1b4b; transition: all 0.3s ease;' 
                        : 'font-size: 12px; font-weight: bold; padding: 2px 8px; border-radius: 4px; background: #374151; color: #9ca3af; transition: all 0.3s ease;';
                }

                if (data.is_umts) {
                    g('umts_gcid_row').innerHTML = `<strong>UMTS Cell ID:</strong> ${data.gcid_dec} (${data.gcid_hex})`;
                    g('umts_cid_row').innerHTML = `<strong>${_t('ID соты (Cell ID):')}</strong> ${data.cid_dec} (${data.cid_hex})`;
                    g('umts_tac_row').innerHTML = `<strong>${_t('Код зоны (LAC):')}</strong> ${data.tac_str}`;
                    g('umts_pci_row').innerHTML = `<strong>Primary Scrambling Code (PSC):</strong> ${data.serv_pci}`;
                    g('umts_band_row').innerHTML = `<strong>${_t('Ведущий диапазон UMTS:')}</strong> B${data.serv_band} (FCN: ${data.serv_earfcn}) | BW: ${data.serv_bw} MHz`;
                    
                    g('umts_signal_percent').innerText = data.lte_percent;
                    const bar = g('umts_signal_bar');
                    bar.style.width = data.lte_percent + '%';
                    bar.style.background = data.lte_percent > 65 ? '#4ade80' : (data.lte_percent > 35 ? '#fbbf24' : '#ef4444');
                    
                    g('umts_rsrp_row').innerHTML = `<strong>${_t('UMTS RSCP:')}</strong> ${data.lte_rsrp}`;
                    g('umts_ecio_row').innerHTML = `<strong>${_t('UMTS ECIO:')}</strong> ${data.lte_snr}`;
                } else {
                    g('lte_gcid_row').innerHTML = `<strong>Global Cell ID:</strong> ${data.gcid_dec} (${data.gcid_hex})`;
                    g('lte_enb_row').innerHTML = `<strong>${_t('ID базовой станции (eNB):')}</strong> ${data.enb_dec} (${data.enb_hex})`;
                    g('lte_cid_row').innerHTML = `<strong>${_t('ID соты (Сектор):')}</strong> ${data.cid_dec} (${data.cid_hex})`;
                    g('lte_tac_row').innerHTML = `<strong>${_t('Код зоны (TAC):')}</strong> ${data.tac_str}`;
                    g('lte_pci_row').innerHTML = `<strong>${_t('PCI:')}</strong> ${data.serv_pci}`;
                    g('lte_ta_row').innerHTML = `<strong>${_t('Timing Advance:')}</strong> ${data.ta_text}`;
                    g('lte_band_row').innerHTML = `<strong>${_t('Ведущий диапазон LTE:')}</strong> B${data.serv_band} (EARFCN: ${data.serv_earfcn}) | BW: ${data.serv_bw} MHz`;

                    g('lte_signal_percent').innerText = data.lte_percent;
                    const bar = g('lte_signal_bar');
                    bar.style.width = data.lte_percent + '%';
                    bar.style.background = data.lte_percent > 65 ? '#4ade80' : (data.lte_percent > 35 ? '#fbbf24' : '#ef4444');

                    g('lte_sinr_percent').innerText = data.lte_snr_percent;
                    const sinrBar = g('lte_sinr_bar');
                    if (sinrBar) {
                        sinrBar.style.width = data.lte_snr_percent + '%';
                        const snrNum = parseFloat(data.lte_snr);
                        if (isNaN(snrNum)) {
                            sinrBar.style.background = '#ef4444';
                        } else if (snrNum <= 0) {
                            sinrBar.style.background = '#ef4444';
                        } else if (snrNum <= 10) {
                            sinrBar.style.background = '#fbbf24';
                        } else if (snrNum <= 20) {
                            sinrBar.style.background = '#4ade80';
                        } else {
                            sinrBar.style.background = '#3b82f6';
                        }
                    }

                    g('lte_sig_row').innerHTML = `<strong>${_t('LTE RSRP / RSRQ:')}</strong> ${data.lte_rsrp} / ${data.lte_rsrq}`;
                    g('lte_snr_row').innerHTML = `<strong>${_t('LTE SINR / SNR:')}</strong> ${data.lte_snr}`;
                }

                // Always update signals UI data
                g('nr_band_row').innerHTML = `<strong>${_t('Ведущий диапазон 5G NSA:')}</strong> n${data.nr_band} (ARFCN: ${data.nr_arfcn}) | BW: ${data.nr_bw} MHz`;
                g('nr_signal_percent').innerText = data.nr_percent;
                const nrBar = g('nr_signal_bar');
                if (nrBar) {
                    nrBar.style.width = data.nr_percent + '%';
                    nrBar.style.background = data.nr_percent > 65 ? '#4ade80' : (data.nr_percent > 35 ? '#fbbf24' : '#ef4444');
                }
                g('nr_sig_row').innerHTML = `<strong>${_t('5G RSRP / RSRQ:')}</strong> ${data.nr_rsrp} / ${data.nr_rsrq}`;
                g('nr_snr_row').innerHTML = `<strong>${_t('5G SINR / SNR:')}</strong> ${data.nr_snr}`;

                // Auto collapse or expand if no user overrides exist
                const content = g('nr_content');
                const arrow = g('nr_arrow');
                if (content && arrow && !localStorage.getItem('nr_content')) {
                    if (isNrActive) {
                        content.style.maxHeight = '1000px';
                        content.style.opacity = '1';
                        arrow.style.transform = 'rotate(90deg)';
                        content.classList.remove('collapsed');
                    } else {
                        content.style.maxHeight = '0px';
                        content.style.opacity = '0';
                        arrow.style.transform = 'rotate(0deg)';
                        content.classList.add('collapsed');
                    }
                }

                // Update RX Chains
                let rxHtml = '';
                if (data.rx_chains && Array.isArray(data.rx_chains)) {
                    data.rx_chains.forEach(rx => {
                        rxHtml += `<div class="sim-row ca-block">Антенна ${rx.chain}: RSSI ${rx.pwr} | RSRP ${rx.rp} | RSRQ ${rx.ec || 'n/a'}</div>`;
                    });
                }
                g('rx_chains_container').innerHTML = rxHtml;

                // Update CA (Carrier Aggregation)
                let caHtml = '';
                if (!data.is_umts) {
                    if (data.ca_info && Array.isArray(data.ca_info) && data.ca_info.length > 0) {
                        caHtml = '<div class="sim-row"><strong>Агрегация частот (CA):</strong></div>';
                        data.ca_info.forEach((ca, idx) => {
                            const cls = ca.state === 'activated' ? 'ca-state-active' : 'ca-state-deact';
                            caHtml += `<div class="sim-row ca-block" style="display: grid; grid-template-columns: 280px 1fr; gap: 2px 10px; padding: 6px 0; border-bottom: 1px solid #374151;">
                                <div>SCC ${idx+1}: <strong>B${ca.band}</strong> (EARFCN: ${ca.earfcn}, ${ca.bw} MHz)</div>
                                <div>PCI: ${ca.pci} | RSSI: ${ca.rssi || '-'}</div>
                                <div>State: <span class="${cls}">${ca.state}</span></div>
                                <div>RSRP: ${ca.rsrp || '-'} | RSRQ: ${ca.rsrq || '-'}</div>
                            </div>`;
                        });
                    } else {
                        caHtml = '<div class="sim-row"><strong>Агрегация частот (CA):</strong> Не активна (нет SCC)</div>';
                    }
                }
                g('ca_container').innerHTML = caHtml;

                // Update Neighbors
                let nHtml = '';
                if (data.neighbours && Array.isArray(data.neighbours) && data.neighbours.length > 0) {
                    nHtml = `<div class="grid-table grid-header"><div>EARFCN</div><div>PCI</div><div>RSSI</div><div>RSRP</div><div>RSRQ</div></div><div class="grid-table">`;
                    data.neighbours.forEach(nb => {
                        nHtml += `<div class="grid-row" style="display: contents;">
                            <div style="padding: 2px 0; color: #60a5fa;">${nb.e}</div>
                            <div style="padding: 2px 0;">${nb.pci}</div>
                            <div style="padding: 2px 0;">${nb.ri}</div>
                            <div style="padding: 2px 0;">${nb.rp}</div>
                            <div style="padding: 2px 0;">${nb.rq}</div>
                        </div>`;
                    });
                    nHtml += '</div>';
                } else {
                    nHtml = '<div class="sim-row" style="color: #9ca3af;">No neighbouring cells detected.</div>';
                }
                g('neighbors_container').innerHTML = nHtml;

                // Update Sensitive Info Data Attributes
                g('field_imei').setAttribute('data-raw', data.hw_imei);
                g('field_imsi').setAttribute('data-raw', data.hw_imsi);
                g('field_phone').setAttribute('data-raw', data.hw_phone);
                if (mAct) {
                    g('field_imei').innerText = data.hw_imei;
                    g('field_imsi').innerText = data.hw_imsi;
                    g('field_phone').innerText = data.hw_phone;
                } else {
                    g('field_imei').innerText = '*'.repeat(data.hw_imei.length);
                    g('field_imsi').innerText = '*'.repeat(data.hw_imsi.length);
                    g('field_phone').innerText = '*'.repeat(data.hw_phone.length);
                }
                }

                // Update Router & Speed Metrics
                g('router_cpu_temp').innerText = data.router_cpu_temp || '-';
                g('router_wifi_temp').innerText = data.router_wifi_temp || '-';
                
                const cpuVal = parseFloat(data.router_cpu_temp);
                const wifiVal = parseFloat(data.router_wifi_temp);
                const nowSec = Math.floor(Date.now() / 1000);
                if (!isNaN(cpuVal)) {
                    tempChartData.push({
                        time: nowSec,
                        cpu: cpuVal,
                        wifi: !isNaN(wifiVal) ? wifiVal : null
                    });
                    tempChartData = tempChartData.filter(d => (nowSec - d.time) <= 300);
                    drawTempChart();
                }
                
                if (data.speed) {
                    g('router_loadavg').innerText = data.speed.loadavg !== undefined ? data.speed.loadavg.toFixed(2) : '-';
                    g('speed_rx').innerText = data.speed.rx_speed.toFixed(2);
                    g('speed_tx').innerText = data.speed.tx_speed.toFixed(2);
                    if (data.speed.history) {
                        chartData = data.speed.history;
                        drawChart();
                    }
                    if (data.speed.load_history) {
                        loadChartData = data.speed.load_history;
                        drawLoadChart();
                    }
                } else {
                    g('router_loadavg').innerText = '-';
                }
            }
            isFetching = false;
        })
        .catch(err => {
            isFetching = false;
            console.error('Data sync failed:', err);
        });
}

function resetUsbPort() {
    showRecoveryOverlay('Физический сброс USB порта модема...');
    
    let sec = 15;
    const subtitle = window.g ? window.g('overlay_subtitle') : document.getElementById('overlay_subtitle');
    if (subtitle) {
        subtitle.innerText = 'Переподключение модема, секунд осталось: ' + sec;
    }
    
    const interval = setInterval(() => {
        sec--;
        if (subtitle) {
            subtitle.innerText = 'Переподключение модема, секунд осталось: ' + sec;
        }
        if (sec <= 0) {
            clearInterval(interval);
            window.location.reload();
        }
    }, 1000);

    const url = '<%=luci.dispatcher.build_url("admin/modem/reset_usb_port")%>';
    fetch(url)
        .then(res => res.json())
        .catch(err => {
            console.error('USB reset failed:', err);
        });
}

function tick(){
    if(cDown<=0){
        g('refresh_timer').innerText = _t("Обновление...");
        fetchModemData();
        // Reset countdown to select value
        cDown = parseInt(g('auto_refresh').value);
    }
    g('refresh_timer').innerText = _t("Обновление через ") + cDown + "s...";
    cDown--;
    tId = setTimeout(tick, 1000);
}

function setAutoRefresh(){
    clearTimeout(tId);
    let v = g('auto_refresh').value;
    localStorage.setItem('m_re', v);
    cDown = parseInt(v);
    if (cDown > 0) {
        tick();
    } else {
        g('refresh_timer').innerText = "";
    }
}

// Initial draw of chart and trigger initial data load
window.addEventListener('resize', () => { drawChart(); drawLoadChart(); drawTempChart(); });

const urlParams = new URLSearchParams(window.location.search);
const isSimSwitch = urlParams.get('sim_switch') === '1';

if (isSimSwitch) {
    const overlay = g('sim_switch_overlay');
    if (overlay) overlay.style.display = 'flex';
    
    let secondsLeft = 10;
    const timerSpan = g('sim_switch_timer');
    
    const countdown = setInterval(() => {
        secondsLeft--;
        if (timerSpan) timerSpan.innerText = secondsLeft;
        
        if (secondsLeft <= 0) {
            clearInterval(countdown);
            if (overlay) overlay.style.display = 'none';
            const cleanUrl = window.location.protocol + "//" + window.location.host + window.location.pathname + "?qmi_dev=" + encodeURIComponent(g('modem_interface_select').value);
            window.location.href = cleanUrl;
        }
    }, 1000);
} else {
    setTimeout(() => {
        initSpoilers();
        fetchModemData();
        g('auto_refresh').value = cDown;
        if(cDown > 0) {
            tick();
        }
    }, 500);
}
</script>

<div id="apply_overlay" style="display:none; position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(15,23,42,0.95); z-index:99999; justify-content:center; align-items:center; flex-direction:column; color:#fff; font-family:sans-serif; backdrop-filter:blur(5px);">
    <div class="spinning" style="width:60px; height:60px; border:4px solid #334155; border-top-color:#3b82f6; border-radius:50%; animation:spin 1s linear infinite; margin-bottom:20px;"></div>
    <div id="overlay_title" style="font-size:20px; font-weight:bold; color:#f8fafc;">Применение настроек...</div>
    <div id="overlay_subtitle" style="font-size:14px; color:#94a3b8; margin-top:8px; text-align:center; max-width:400px; padding:0 20px; line-height:1.5;">Пожалуйста, подождите, выполняется операция перезапуска...</div>
</div>
<style>
@keyframes spin { to { transform: rotate(360deg); } }
</style>

<script>
window.g = window.g || (i => document.getElementById(i));

function showRecoveryOverlay(title) {
    const titleEl = g('overlay_title');
    const subEl = g('overlay_subtitle');
    const overlayEl = g('apply_overlay');
    if (titleEl) titleEl.innerText = title;
    if (subEl) subEl.innerText = "Пожалуйста, подождите, выполняется перезапуск (около 6 сек)...";
    if (overlayEl) overlayEl.style.display = 'flex';
}

function saveLossLogs() {
    const btn = document.getElementById('save_logs_btn');
    if (!btn) return;
    const originalText = btn.innerText;
    btn.disabled = true;
    btn.innerText = 'Сохранение...';
    
    const now = new Date();
    const pad = (num) => String(num).padStart(2, '0');
    const dateTimeStr = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}_${pad(now.getHours())}-${pad(now.getMinutes())}-${pad(now.getSeconds())}`;
    
    const url = '<%=luci.dispatcher.build_url("admin/modem/get_combined_logs")%>?t=' + Date.now();
    const defaultName = `logread_loss_inet_${dateTimeStr}.txt`;
    
    try {
        const link = document.createElement('a');
        link.href = url;
        link.download = defaultName;
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        
        btn.innerText = '✔️ Логи сохранены!';
        btn.style.background = '#16a34a';
        btn.style.borderColor = '#15803d';
        
        setTimeout(() => {
            btn.disabled = false;
            btn.innerText = originalText;
            btn.style.background = '#8b5cf6';
            btn.style.borderColor = '#7c3aed';
        }, 2000);
    } catch (e) {
        console.error(e);
        btn.innerText = '❌ Ошибка';
        setTimeout(() => {
            btn.disabled = false;
            btn.innerText = originalText;
            btn.style.background = '#8b5cf6';
            btn.style.borderColor = '#7c3aed';
        }, 2000);
    }
}

// Language Translation Logic
const dict = {
    "График температуры (Temperature)": "Temperature Graph",
    "Ожидание данных температуры...": "Waiting for temperature data...",
    "График нагрузки процессора (Load Average)": "CPU Load Graph (Load Average)",
    "Ожидание данных нагрузки...": "Waiting for load data...",
    "Отсутствует": "Missing",
    "Нет сети": "No network",
    "Запущена": "Running",
    "Остановлена": "Stopped",
    "Включен": "Enabled",
    "Отключен": "Disabled",
    "Не активен": "Inactive",
    "Активно": "Active",
    "Не активно": "Inactive",
    "Выключить": "Disable",
    "Включить": "Enable",
    "Старт": "Start",
    "Стоп": "Stop",
    "Обновление...": "Updating...",
    "перезапуск": "restart",
    "Рестарт интерфейса": "Interface restart",
    "Сброс радио (AT+CFUN)": "Radio reset (AT+CFUN)",
    "Рестарт ModemManager": "ModemManager restart",
    "Аппаратный сброс USB": "Hardware USB reset",
    "Модем подключен": "Modem connected",
    "Модем отключен": "Modem disconnected",
    "Модем отсутствует": "Modem missing",
    "Отказ сети (Denied)": "Network denied (Denied)",
    "Нет регистрации": "No registration",
    "Нет IP адреса": "No IP address",
    "Не проходит пинг": "Ping check fails",
    "Сеть (PLMN):": "Network (PLMN):",
    "Статус (технология):": "Status (tech):",
    "Время сессии:": "Session time:",
    "IP-адрес (WWAN):": "IP-Address (WWAN):",
    "Трафик (Прием / Отдача):": "Traffic (Rx / Tx):",
    "Общий трафик:": "Total Traffic:",
    "Доступность сети 5G NSA:": "5G NSA Availability:",
    "ссылка на 4cells (доступно не всегда)": "link to 4cells (not always available)",
    "Мощность передатчика:": "TX Power:",
    "UMTS Cell ID:": "UMTS Cell ID:",
    "ID соты (Cell ID):": "Cell ID (Cell ID):",
    "Код зоны (LAC):": "Zone Code (LAC):",
    "Primary Scrambling Code (PSC):": "Primary Scrambling Code (PSC):",
    "Ведущий диапазон UMTS:": "Primary UMTS Band:",
    "UMTS RSCP:": "UMTS RSCP:",
    "UMTS ECIO:": "UMTS ECIO:",
    "Global Cell ID:": "Global Cell ID:",
    "ID базовой станции (eNB):": "Base Station ID (eNB):",
    "ID соты (Сектор):": "Cell ID (Sector):",
    "Код зоны (TAC):": "Zone Code (TAC):",
    "PCI:": "PCI:",
    "Timing Advance:": "Timing Advance:",
    "Ведущий диапазон LTE:": "Primary LTE Band:",
    "LTE RSRP / RSRQ:": "LTE RSRP / RSRQ:",
    "LTE SINR / SNR:": "LTE SINR / SNR:",
    "Ведущий диапазон 5G NSA:": "Primary 5G NSA Band:",
    "5G RSRP / RSRQ:": "5G RSRP / RSRQ:",
    "5G SINR / SNR:": "5G SINR / SNR:",
    "Расширенная панель модема": "Advanced Modem Dashboard",
    "⚙️ Автоматическое восстановление модема": "⚙️ Automatic Modem Recovery",
    "Служба демона:": "Daemon service:",
    "Автозапуск:": "Autostart:",
    "Текущее состояние демона": "Current daemon state",
    "Длительность состояния": "State duration",
    "Статус службы ModemManager": "ModemManager service status",
    "Количество попыток восстановления подряд": "Consecutive recovery attempts count",
    "Статистика запусков восстановления": "Recovery launches statistics",
    "Всего запусков": "Total launches",
    "1. Рестарт интерфейса": "1. Interface restart",
    "2. Сброс радио (AT+CFUN)": "2. Radio reset (AT+CFUN)",
    "2b. Рестарт ModemManager": "2b. ModemManager restart",
    "3. Аппаратный сброс USB": "3. Hardware USB reset",
    "Накопленное время по состоянию": "Accumulated time by state",
    "Последнее действие:": "Last action:",
    "Время действия:": "Action time:",
    "Причина:": "Reason:",
    "Мониторинг сигнала": "Signal Monitoring",
    "Интерфейс:": "Interface:",
    "Слот SIM:": "SIM Slot:",
    "SIM-карта не готова или отсутствует": "SIM card is not ready or missing",
    "Управление SIM-слотом": "SIM Slot Management",
    "Активный слот SIM:": "Active SIM Slot:",
    "Слот 1": "Slot 1",
    "Слот 2": "Slot 2",
    "Диапазон:": "Range:",
    "Применение настроек...": "Applying settings...",
    "Пожалуйста, подождите, выполняется операция перезапуска...": "Please wait, restarting operation is running...",
    "Пожалуйста, подождите, выполняется перезапуск (около 6 сек)...": "Please wait, restarting (about 6 sec)...",
    "Модем переключает слот SIM и перезагружается. Пожалуйста, подождите": "Modem switches SIM slot and reboots. Please wait",
    "секунд, пока соединение восстановится.": "seconds until connection recovers.",
    "⚠️ Модемный интерфейс не обнаружен": "⚠️ Modem interface not detected",
    "Пожалуйста, подключите модем, проверьте питание и убедитесь, что служба ModemManager активна.": "Please connect a modem, check power, and verify that ModemManager is running.",
    "Перезапустить ModemManager": "Restart ModemManager",
    "Перезапустить интерфейс MODEM": "Restart MODEM interface",
    
    // Missing entries reported by user
    "Выберите интерфейс модема:": "Select modem interface:",
    "Связан с индексом MM:": "Bound to MM index:",
    "Обнаруженные привязки:": "Detected bindings:",
    "Управление SIM-картами и TTL": "SIM Card & TTL Management",
    "Выбрать SIM-слот:": "Select SIM slot:",
    "Входящий TTL:": "Incoming TTL:",
    "Исходящий TTL:": "Outgoing TTL:",
    "Выбор режима(RAT) и частот(band)": "RAT Mode & Band Selection",
    "Текущий режим:": "Current mode:",
    "⚠️ Некоторые режимы RAT могут работать с ошибками из-за специфики ModemManager. ": "⚠️ Some RAT modes may operate with errors due to ModemManager specifics. ",
    "Выбрать режим работы (RAT):": "Select operating mode (RAT):",
    "LTE частоты:": "LTE Bands:",
    "5G частоты:": "5G Bands:",
    "3G/2G частоты (UMTS/CDMA/GSM):": "3G/2G Bands (UMTS/CDMA/GSM):",
    "Включить все частоты": "Enable all bands",
    "Выключить все частоты": "Disable all bands",
    "Сохранить и применить": "Save & Apply",
    "⚠️ Изменения применяются мгновенно. Возможен кратковременный обрыв связи.": "⚠️ Changes apply instantly. Brief connection drop is possible.",
    "Сеть и подключение": "Network & Connection",
    "Информация об устройстве": "Device Information",
    "Производитель": "Manufacturer",
    "Модель": "Model",
    "Аппаратная ревизия": "Hardware revision",
    "Версия прошивки": "Firmware version",
    "Сбросить USB порт модема": "Reset modem USB port",
    "Перезагрузить модем": "Reboot modem",
    "Сохранить логи": "Save logs",
    "Перезагрузка модема (QMI)...": "Rebooting modem (QMI)...",
    "Перезапуск службы ModemManager...": "Restarting ModemManager service...",
    "Перезапуск интерфейса MODEM...": "Restarting MODEM interface...",
    
    // Raw MM state label translations
    "Модем подключен (connected)": "Modem connected (connected)",
    "Модем отключен (disabled)": "Modem disconnected (disabled)",
    "Отказ сети (denied)": "Network denied (denied)",
    "Модем отсутствует (missing)": "Modem missing (missing)",
    "Нет регистрации (searching/enabled)": "No registration (searching/enabled)",
    "Нет IP адреса (registered)": "No IP address (registered)",
    "Не проходит пинг (registered)": "No ping (registered)",
    
    // Restart RF translations
    "Перезапустить RF": "Restart RF",
    "Перезапуск радиомодуля (RF)...": "Restarting radio module (RF)...",

    // Newly reported translations
    "Сила сигнала LTE (RSRP):": "LTE signal strength (RSRP):",
    "Качество сигнала LTE (SINR):": "LTE signal quality (SINR):",
    "Обновите страницу и/или начните передачу данных для отображения": "Refresh page and/or start data transmission to display",
    "Антенна ": "Antenna ",
    "Агрегация частот (CA):": "Carrier Aggregation (CA):",
    "Не активна (нет SCC)": "Inactive (no SCC)",
    "Сила сигнала 5G (RSRP):": "5G signal strength (RSRP):",
    "1 мин": "1 min",
    "30 сек": "30 sec",
    "5 мин": "5 min",
    "1 сек": "1 sec",
    "Входящая (Downlink):": "Incoming (Downlink):",
    "Исходящая (Uplink):": "Outgoing (Uplink):",
    "Средняя (за выборку):": "Average (sample):",
    "Пиковая (за сессию):": "Peak (session):",
    "Показать": "Show",
    "Скрыть": "Hide",
    "ID оборудования (IMEI):": "Hardware ID (IMEI):",
    "Номер телефона:": "Phone number:",
    "Информация о роутере": "Router Information",
    "Температура CPU:": "CPU Temperature:",
    "Температура WiFi:": "WiFi Temperature:",
    "Load Average (1м / 5м / 15м):": "Load Average (1m / 5m / 15m):",
    "Устранение неполадок и диагностика": "Troubleshooting & Diagnostics",
    "Обновить информацию": "Refresh Information",
    "Записать в лог ручное поднятие инета": "Log manual internet restoration",
    "Автообновление:": "Auto-update:",
    "Обновление через ": "Updating in ",
    "Обновление...": "Updating...",
    "Запущена": "Running",
    "Остановлена": "Stopped",
    "Включен": "Enabled",
    "Отключен": "Disabled",
    "Выключить": "Disable",
    "Включить": "Enable",
    "Старт": "Start",
    "Стоп": "Stop",
    "Отобразить": "Show",
    "Скрыть отображение": "Hide",
    "Запись...": "Logging..."
};

function _t(str) {
    if (!str) return str;
    const lang = localStorage.getItem('modem_lang') || 'ru';
    if (lang === 'ru') return str;
    return dict[str] || str;
}

function changeLanguage(lang) {
    localStorage.setItem('modem_lang', lang);
    document.cookie = "modem_lang=" + lang + "; path=/; max-age=31536000";
    const selects = document.querySelectorAll('#lang_select');
    selects.forEach(s => s.value = lang);
    translatePage(lang);
}

function translatePage(lang) {
    const elements = document.querySelectorAll('h3, h4, h5, p, label, button, span, strong, option, th, td, a, div.sim-row, div.ant-label, small, div, input, select');
    const sortedKeys = Object.keys(dict).sort((a, b) => b.length - a.length);
    elements.forEach(el => {
        // Translate text nodes
        let hasTextChild = false;
        for (let node of el.childNodes) {
            if (node.nodeType === Node.TEXT_NODE && node.nodeValue.trim().length > 0) {
                hasTextChild = true;
                break;
            }
        }
        if (hasTextChild) {
            if (!el.hasAttribute('data-ru')) {
                el.setAttribute('data-ru', el.innerHTML);
            }
            const origRu = el.getAttribute('data-ru');
            if (lang === 'en') {
                let translated = origRu;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.innerHTML = translated;
            } else {
                el.innerHTML = origRu;
            }
        }

        // Translate placeholders
        if (el.placeholder) {
            if (!el.hasAttribute('data-placeholder-ru')) {
                el.setAttribute('data-placeholder-ru', el.placeholder);
            }
            const origPl = el.getAttribute('data-placeholder-ru');
            if (lang === 'en') {
                let translated = origPl;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.placeholder = translated;
            } else {
                el.placeholder = origPl;
            }
        }

        // Translate titles
        if (el.title) {
            if (!el.hasAttribute('data-title-ru')) {
                el.setAttribute('data-title-ru', el.title);
            }
            const origTitle = el.getAttribute('data-title-ru');
            if (lang === 'en') {
                let translated = origTitle;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.title = translated;
            } else {
                el.title = origTitle;
            }
        }
    });
}

// Initial language setup
const currentLang = localStorage.getItem('modem_lang') || 'ru';
document.cookie = "modem_lang=" + currentLang + "; path=/; max-age=31536000";
const select = document.getElementById('lang_select');
if (select) select.value = currentLang;
setTimeout(() => translatePage(currentLang), 100);

// Redefine formatSec to support language
const origFormatSec = formatSec;
formatSec = (s) => {
    const lang = localStorage.getItem('modem_lang') || 'ru';
    if (s === undefined || s === null || isNaN(s)) return '0' + (lang === 'en' ? 's' : 'с');
    if (s < 60) return s + (lang === 'en' ? 's' : 'с');
    let m = Math.floor(s / 60);
    let r = s % 60;
    if (m < 60) return m + (lang === 'en' ? 'm ' : 'м ') + r + (lang === 'en' ? 's' : 'с');
    let h = Math.floor(m / 60);
    let rm = m % 60;
    return h + (lang === 'en' ? 'h ' : 'ч ') + rm + (lang === 'en' ? 'm ' : 'м ') + r + (lang === 'en' ? 's' : 'с');
};
</script>

<%+footer%>

EOF

echo "Deploying /usr/lib/lua/luci/view/modem/antenna.htm..."
cat << \EOF > /usr/lib/lua/luci/view/modem/antenna.htm
<%+header%>
<%
    local http = require "luci.http"

    local act = http.formvalue("action")
    if act == "restart_mm" then
        os.execute("/etc/init.d/modemmanager restart")
        os.execute("sleep 6")
        http.redirect(http.getenv("REQUEST_URI"):gsub("%?.*$", ""))
        return
    elseif act == "restart_iface" then
        os.execute("ifdown MODEM && sleep 3 && ifup MODEM")
        os.execute("sleep 6")
        http.redirect(http.getenv("REQUEST_URI"):gsub("%?.*$", ""))
        return
    end
    
    local function exec(cmd)
        local h = io.popen(cmd .. " 2>/dev/null")
        if h then
            local res = h:read("*a")
            h:close()
            return res or ""
        end
        return ""
    end
    
    local m_list = exec("mmcli -L") or ""
    local has_modem = (m_list:match("ModemManager1/Modem/(%d+)") ~= nil)
    
    -- Check initial device list if modem exists
    local wdm_devs = {}
    local qmi_dev = "-"
    if has_modem then
        local ls_h = io.popen("ls /dev/cdc-wdm* 2>/dev/null")
        if ls_h then
            for line in ls_h:lines() do table.insert(wdm_devs, line) end
            ls_h:close()
        end
        if #wdm_devs == 0 then table.insert(wdm_devs, "/dev/cdc-wdm0") end
        qmi_dev = http.formvalue("qmi_dev") or wdm_devs[1]
    end
%>

<div class="cbi-section">
    <div class="cbi-section-node" style="padding: 10px 0; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px;">
        <div>
            <h3 style="margin-bottom: 5px; color: #ffffff;">Настройка антенны (Setup Antenna)</h3>
            <p style="color: #94a3b8; margin: 0; font-size: 13px;">Крупный формат вывода ключевых радиопоказателей для юстировки уличных антенн в реальном времени.</p>
        </div>
        <div style="display: flex; align-items: center; gap: 6px; background: rgba(30, 41, 59, 0.7); backdrop-filter: blur(8px); padding: 4px 8px; border-radius: 6px; border: 1px solid rgba(255, 255, 255, 0.08); height: fit-content; margin-right: 15px;">
            <span style="font-size: 12px; color: #94a3b8;">🌐 Language:</span>
            <select id="lang_select" onchange="changeLanguage(this.value)" style="background: transparent; color: #f8fafc; border: none; font-size: 12px; cursor: pointer; outline: none; padding: 0 4px; font-weight: 500;">
                <option value="ru" style="background: #1e293b; color: #f8fafc;">RU</option>
                <option value="en" style="background: #1e293b; color: #f8fafc;">EN</option>
            </select>
        </div>
    </div>
</div>

<% if not has_modem then %>
    <div style="background: #1e293b; border-left: 4px solid #ef4444; border-radius: 8px; padding: 24px; text-align: center; box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1);">
        <h3 style="color: #ef4444; margin-top: 0; font-size: 20px;">⚠️ Модемный интерфейс не обнаружен</h3>
        <p style="color: #94a3b8; margin: 0; font-size: 14px; margin-bottom: 20px;">Пожалуйста, подключите модем, проверьте питание и убедитесь, что служба ModemManager активна.</p>
        
        <div style="display: flex; justify-content: center; gap: 15px; flex-wrap: wrap;">
            <a href="?action=restart_mm" style="display: inline-block; padding: 8px 16px; background-color: #3b82f6; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезапуск службы ModemManager...')">Перезапустить ModemManager</a>
            <a href="?action=restart_iface" style="display: inline-block; padding: 8px 16px; background-color: #f59e0b; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезапуск интерфейса MODEM...')">Перезапустить интерфейс MODEM</a>
        </div>
    </div>

    <div id="apply_overlay" style="display:none; position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(15,23,42,0.95); z-index:99999; justify-content:center; align-items:center; flex-direction:column; color:#fff; font-family:sans-serif; backdrop-filter:blur(5px);">
        <div class="spinning" style="width:60px; height:60px; border:4px solid #334155; border-top-color:#3b82f6; border-radius:50%; animation:spin 1s linear infinite; margin-bottom:20px;"></div>
        <div id="overlay_title" style="font-size:20px; font-weight:bold; color:#f8fafc;">Применение настроек...</div>
        <div id="overlay_subtitle" style="font-size:14px; color:#94a3b8; margin-top:8px; text-align:center; max-width:400px; padding:0 20px; line-height:1.5;">Пожалуйста, подождите, выполняется операция перезапуска...</div>
    </div>
    <style>
    @keyframes spin { to { transform: rotate(360deg); } }
    </style>
    <script>
    function showRecoveryOverlay(title) {
        document.getElementById('overlay_title').innerText = title;
        document.getElementById('overlay_subtitle').innerText = "Пожалуйста, подождите, выполняется перезапуск (около 6 сек)...";
        document.getElementById('apply_overlay').style.display = 'flex';
    }
    </script>
<% else %>

<style>
.ant-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 20px;
    margin-bottom: 25px;
}
.ant-card {
    background: #1e293b;
    border: 1px solid #334155;
    border-radius: 8px;
    padding: 24px;
    text-align: center;
    position: relative;
    overflow: hidden;
    box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1);
}
.ant-card::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 4px;
}
.card-rsrp::before { background: #10b981; }
.card-rsrq::before { background: #3b82f6; }
.card-sinr::before { background: #8b5cf6; }

.ant-label {
    font-size: 14px;
    color: #94a3b8;
    text-transform: uppercase;
    font-weight: 600;
    letter-spacing: 0.05em;
    margin-bottom: 8px;
}
.ant-value {
    font-size: 110px; /* Extremely large signal metrics for outdoor tuning */
    font-weight: 800;
    line-height: 1;
    color: #ffffff;
    font-family: 'Outfit', 'Inter', sans-serif;
    margin: 15px 0;
    transition: color 0.3s ease;
}
.ant-value span {
    font-size: 32px;
    font-weight: 500;
    color: #94a3b8;
    margin-left: 4px;
}

/* Cell Info Panel */
.info-panel {
    background: #0f172a;
    border: 1px solid #1e293b;
    border-radius: 8px;
    padding: 20px;
    margin-bottom: 25px;
    font-family: monospace;
    font-size: 14px;
}
.info-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
    gap: 15px;
}
.info-item {
    padding: 10px;
    background: #1e293b;
    border-radius: 6px;
    border: 1px solid #334155;
    color: #d1d5db;
}
.info-item strong {
    color: #ffffff;
    display: block;
    font-size: 12px;
    text-transform: uppercase;
    color: #94a3b8;
    margin-bottom: 4px;
}

/* History Chart container */
.chart-card {
    background: #1e293b;
    border: 1px solid #334155;
    border-radius: 8px;
    padding: 20px;
    margin-bottom: 25px;
}
@keyframes pulse {
    0% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7); }
    70% { transform: scale(1); box-shadow: 0 0 0 6px rgba(16, 185, 129, 0); }
    100% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0); }
}
</style>

<div class="info-panel" style="background-color: #1e293b; margin-bottom: 20px;">
    <div style="display: flex; gap: 15px; align-items: center; flex-wrap: wrap;">
        <label style="color: #ffffff; font-weight: bold;">Порт модема:</label>
        <select id="modem_interface_select" onchange="fetchModemData()" style="background: #0f172a; color: #d1d5db; border: 1px solid #3b82f6; padding: 6px 12px; border-radius: 4px; outline: none; cursor: pointer; font-size: 14px;">
            <% for _, dev in ipairs(wdm_devs) do %>
                <option value="<%=dev%>" <%= (dev == qmi_dev) and 'selected' or '' %>><%=dev%></option>
            <% end %>
        </select>
        
        <label style="color: #ffffff; font-weight: bold; margin-left: 10px;">Обновление:</label>
        <select id="update_interval_select" onchange="changeUpdateInterval()" style="background: #0f172a; color: #d1d5db; border: 1px solid #3b82f6; padding: 6px 12px; border-radius: 4px; outline: none; cursor: pointer; font-size: 14px;">
            <option value="1000" selected>1 сек</option>
            <option value="3000">3 сек</option>
            <option value="5000">5 сек</option>
            <option value="0">выкл</option>
        </select>
        
        <button onclick="fetchModemData()" style="background: #3b82f6; color: #fff; border: none; padding: 6px 12px; border-radius: 4px; cursor: pointer; font-weight: bold; font-size: 13px; outline: none;">Обновить сейчас</button>
        
        <span style="color: #94a3b8; font-size: 13px;">Оператор: <strong id="op_name" style="color: #60a5fa;">-</strong></span>
        <span style="color: #94a3b8; font-size: 13px;">Технология: <strong id="rat_tech" style="color: #4ade80;">-</strong></span>
        <span style="color: #94a3b8; font-size: 13px;">PCI: <strong id="head_pci" style="color: #f59e0b;">-</strong></span>
        <span style="color: #94a3b8; font-size: 13px;">Сигнал: <strong id="head_band" style="color: #a78bfa;">-</strong></span>
        
        <span style="margin-left: auto; color: #4ade80; font-family: monospace; font-weight: bold; font-size: 13px;" id="live_indicator">● LIVE SYNC</span>
    </div>
</div>

<!-- Giant Metrics -->
<div class="ant-grid">
    <div class="ant-card card-rsrp">
        <div class="ant-label">Мощность сигнала (RSRP)</div>
        <div class="ant-value" id="giant_rsrp">--<span>dBm</span></div>
    </div>
    
    <div class="ant-card card-rsrq">
        <div class="ant-label">Качество сигнала (RSRQ)</div>
        <div class="ant-value" id="giant_rsrq">--<span>dB</span></div>
    </div>
    
    <div class="ant-card card-sinr">
        <div class="ant-label">Соотношение сигнал/шум (SINR)</div>
        <div class="ant-value" id="giant_sinr">--<span>dB</span></div>
    </div>
</div>

<!-- Live Speeds row -->
<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 20px; margin-bottom: 25px;">
    <div class="ant-card" style="padding: 15px 24px; border-color: #3b82f6; border-top: 4px solid #3b82f6; position: relative;">
        <div class="ant-label" style="font-size: 12px; margin-bottom: 4px; color: #94a3b8; text-transform: uppercase; font-weight: 600;">Текущий Downlink (Скачивание)</div>
        <div style="font-size: 32px; font-weight: 800; color: #4ade80; font-family: 'Outfit', 'Inter', sans-serif;" id="speed_dl">0.00 <span style="font-size: 16px; color: #94a3b8; font-weight: normal;">Mbps</span></div>
    </div>
    <div class="ant-card" style="padding: 15px 24px; border-color: #8b5cf6; border-top: 4px solid #8b5cf6; position: relative;">
        <div class="ant-label" style="font-size: 12px; margin-bottom: 4px; color: #94a3b8; text-transform: uppercase; font-weight: 600;">Текущий Uplink (Отдача)</div>
        <div style="font-size: 32px; font-weight: 800; color: #60a5fa; font-family: 'Outfit', 'Inter', sans-serif;" id="speed_ul">0.00 <span style="font-size: 16px; color: #94a3b8; font-weight: normal;">Mbps</span></div>
    </div>
</div>

<!-- Speed Chart Card (under spoiler, collapsed by default) -->
<div class="chart-card">
    <div style="display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #334155; padding-bottom: 8px; margin-bottom: 15px; cursor: pointer; user-select: none;" onclick="toggleSpoiler('speed_graph_content', 'speed_graph_arrow')">
        <h4 style="margin: 0; border: none; padding: 0; display: flex; align-items: center; gap: 8px; color: #ffffff; font-weight: normal;">
            <svg id="speed_graph_arrow" style="width: 16px; height: 16px; transition: transform 0.3s ease; transform: rotate(0deg);" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M9 5l7 7-7 7"></path>
            </svg>
            График скорости в реальном времени
        </h4>
        <div style="display: flex; align-items: center; gap: 10px;" onclick="event.stopPropagation();">
            <label for="graph_range" style="color: #94a3b8; font-size: 13px;">Диапазон:</label>
            <select id="graph_range" onchange="updateGraphRange()" style="background: #0f172a; color: #d1d5db; border: 1px solid #334155; padding: 2px 6px; border-radius: 4px; outline: none; cursor: pointer; font-size: 12px;">
                <option value="30">30 сек</option>
                <option value="60" selected>1 мин</option>
                <option value="300">5 мин</option>
            </select>
        </div>
    </div>
    
    <div id="speed_graph_content" style="max-height: 0px; opacity: 0; overflow: hidden; transition: max-height 0.3s ease-in-out, opacity 0.3s ease-in-out;">
        <div style="display: flex; gap: 15px; flex-wrap: wrap; margin-bottom: 15px; font-size: 13px;">
            <div style="background: #0f172a; border: 1px solid #334155; padding: 8px 12px; border-radius: 6px; flex: 1; min-width: 120px;">
                <div style="color: #94a3b8; font-size: 11px; margin-bottom: 3px;">СРЕДНЯЯ (DL / UL)</div>
                <strong style="color: #4ade80;"><span id="avg_speed_rx">0.00</span></strong> / <strong style="color: #60a5fa;"><span id="avg_speed_tx">0.00</span></strong> <span style="color: #64748b; font-size: 10px;">Mbit/s</span>
            </div>
            <div style="background: #0f172a; border: 1px solid #334155; padding: 8px 12px; border-radius: 6px; flex: 1; min-width: 120px;">
                <div style="color: #94a3b8; font-size: 11px; margin-bottom: 3px;">ПИКОВАЯ (DL / UL)</div>
                <strong style="color: #4ade80;"><span id="peak_speed_rx">0.00</span></strong> / <strong style="color: #60a5fa;"><span id="peak_speed_tx">0.00</span></strong> <span style="color: #64748b; font-size: 10px;">Mbit/s</span>
            </div>
        </div>
        
        <div style="height: 180px; position: relative; background: #0f172a; border: 1px solid #334155; border-radius: 6px; padding: 10px 10px 0 10px; box-sizing: border-box; overflow: hidden;">
            <canvas id="speed_chart" style="width: 100%; height: 100%; display: block;"></canvas>
        </div>
    </div>
</div>

<!-- Traffic Generator (Speedtest) Card -->
<div class="chart-card">
    <h4 style="color:#ffffff; margin-top:0; margin-bottom:15px; border-bottom:1px solid #334155; padding-bottom:8px; font-weight: normal; display: flex; align-items: center; gap: 8px;">
        <svg style="width:16px; height:16px; color:#c084fc;" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"></path>
        </svg>
        Генератор входящего трафика для теста скорости
    </h4>
    
    <div style="display: flex; flex-direction: column; gap: 15px;">
        <div>
            <label style="display:block; margin-bottom:8px; color: #94a3b8; font-size: 13px;">Выберите или введите ссылку для скачивания (прямая ссылка на файл):</label>
            <div style="display: flex; gap: 10px; align-items: center; flex-wrap: wrap;">
                <input type="text" id="speedtest_url" value="http://bks4-speedtest-1.tele2.net/10GB.zip" style="flex: 1; min-width: 280px; background: #0f172a; color: #ffffff; border: 1px solid #334155; padding: 8px 12px; border-radius: 6px; outline: none; font-size: 13px; font-family: monospace;">
                
                <button type="button" id="btn_start_speedtest" onclick="startSpeedtest()" style="background: #10b981; color: #ffffff; border: none; padding: 8px 20px; border-radius: 6px; font-weight: bold; font-size: 13px; cursor: pointer; outline: none; transition: all 0.2s ease;">Старт</button>
                <button type="button" id="btn_stop_speedtest" onclick="stopSpeedtest()" style="background: #ef4444; color: #ffffff; border: none; padding: 8px 20px; border-radius: 6px; font-weight: bold; font-size: 13px; cursor: pointer; outline: none; transition: all 0.2s ease;" disabled>Стоп</button>
            </div>
        </div>
        
        <div>
            <label style="display:block; margin-bottom:6px; color: #94a3b8; font-size: 12px;">Тестовые ссылки (могут быть недоступны):</label>
            <div style="display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 10px;">
                <button type="button" onclick="setSpeedtestUrl('http://bks4-speedtest-1.tele2.net/10GB.zip')" style="background: #1e293b; color: #cbd5e1; border: 1px solid #334155; padding: 4px 10px; border-radius: 4px; font-size: 11px; cursor: pointer; font-family: monospace;">T2 Riga, 10GB</button>
                <button type="button" onclick="setSpeedtestUrl('http://ada345-speedtest-1.tele2.net/10GB.zip')" style="background: #1e293b; color: #cbd5e1; border: 1px solid #334155; padding: 4px 10px; border-radius: 4px; font-size: 11px; cursor: pointer; font-family: monospace;">T2 Tallin, 10GB</button>
                <button type="button" onclick="setSpeedtestUrl('http://bck-speedtest-1.tele2.net/10GB.zip')" style="background: #1e293b; color: #cbd5e1; border: 1px solid #334155; padding: 4px 10px; border-radius: 4px; font-size: 11px; cursor: pointer; font-family: monospace;">T2 Sweden Gothenburg, 10GB</button>
                <button type="button" onclick="setSpeedtestUrl('https://speedtest.selectel.ru/10GB')" style="background: #1e293b; color: #cbd5e1; border: 1px solid #334155; padding: 4px 10px; border-radius: 4px; font-size: 11px; cursor: pointer; font-family: monospace;">Selectel 10GB (HTTPS)</button>
                <button type="button" onclick="setSpeedtestUrl('https://lg.hosterby.com/1GB.test')" style="background: #1e293b; color: #cbd5e1; border: 1px solid #334155; padding: 4px 10px; border-radius: 4px; font-size: 11px; cursor: pointer; font-family: monospace;">Hosterby 1GB (HTTPS)</button>
                <button type="button" onclick="setSpeedtestUrl('https://rosintel.ru/files/test_620.rar')" style="background: #1e293b; color: #cbd5e1; border: 1px solid #334155; padding: 4px 10px; border-radius: 4px; font-size: 11px; cursor: pointer; font-family: monospace;">Rosintel 620MB (HTTPS)</button>
            </div>
        </div>
        
        <div style="display: flex; align-items: center; gap: 8px; font-size: 13px; color: #94a3b8;">
            Статус генератора: 
            <span id="speedtest_status_text" style="font-weight: bold; color: #94a3b8; display: flex; align-items: center; gap: 5px;">
                <span style="display:inline-block; width:8px; height:8px; border-radius:50%; background:#94a3b8;"></span> Не активен
            </span>
        </div>
    </div>
</div>

<script>
const g=i=>document.getElementById(i);
const qs=s=>document.querySelectorAll(s);
let tId, retryCount = 0;
let chartData = [];
let graphRange = 60;
let sessionMaxRx = 0;
let sessionMaxTx = 0;

// Signal evaluation thresholds for coloring numbers directly
function getRSRPColor(val) {
    if (val >= -80) return "#a78bfa";  // Violet/purple
    if (val >= -90) return "#4ade80";  // Salad
    if (val >= -100) return "#fbbf24"; // Yellow
    return "#f87171";                  // Red
}

function getRSRQColor(val) {
    if (val >= -10) return "#a78bfa";  // Violet/purple
    if (val >= -15) return "#4ade80";  // Salad
    if (val >= -20) return "#fbbf24";  // Yellow
    return "#f87171";                  // Red
}

function getSINRColor(val) {
    if (val >= 20) return "#a78bfa";   // Violet/purple
    if (val >= 13) return "#4ade80";   // Salad
    if (val >= 3) return "#fbbf24";    // Yellow
    return "#f87171";                  // Red
}

function toggleSpoiler(contentId, arrowId) {
    const content = g(contentId);
    const arrow = g(arrowId);
    if (!content || !arrow) return;
    
    if (content.style.maxHeight === '0px' || content.style.maxHeight === '') {
        content.style.maxHeight = '500px';
        content.style.opacity = '1';
        arrow.style.transform = 'rotate(90deg)';
    } else {
        content.style.maxHeight = '0px';
        content.style.opacity = '0';
        arrow.style.transform = 'rotate(0deg)';
    }
}

function drawChart() {
    const canvas = g('speed_chart');
    if (!canvas) return;
    const rect = canvas.parentNode.getBoundingClientRect();
    canvas.width = rect.width * window.devicePixelRatio;
    canvas.height = rect.height * window.devicePixelRatio;
    const ctx = canvas.getContext('2d');
    ctx.scale(window.devicePixelRatio, window.devicePixelRatio);

    const w = rect.width;
    const h = rect.height;

    ctx.clearRect(0, 0, w, h);

    const now = Math.floor(Date.now() / 1000);
    const filtered = chartData.filter(d => (now - d.time) <= graphRange);

    if (filtered.length === 0) {
        ctx.strokeStyle = '#262626';
        ctx.lineWidth = 1;
        ctx.beginPath();
        for(let i=1; i<4; i++) {
            let y = ((h - 25) / 4) * i;
            ctx.moveTo(0, y); ctx.lineTo(w, y);
        }
        ctx.stroke();
        ctx.fillStyle = '#6b7280';
        ctx.font = '12px monospace';
        ctx.textAlign = 'center';
        ctx.fillText('Ожидание данных скорости...', w/2, (h - 25)/2);
        return;
    }

    let maxVal = 0.5;
    let sumRx = 0, sumTx = 0, count = filtered.length;
    filtered.forEach(d => {
        if (d.rx > maxVal) maxVal = d.rx;
        if (d.tx > maxVal) maxVal = d.tx;
        
        sumRx += d.rx;
        sumTx += d.tx;
        
        if (d.rx > sessionMaxRx) sessionMaxRx = d.rx;
        if (d.tx > sessionMaxTx) sessionMaxTx = d.tx;
    });
    
    let avgRx = count > 0 ? (sumRx / count) : 0;
    let avgTx = count > 0 ? (sumTx / count) : 0;
    
    if (g('avg_speed_rx')) g('avg_speed_rx').innerText = avgRx.toFixed(2);
    if (g('avg_speed_tx')) g('avg_speed_tx').innerText = avgTx.toFixed(2);
    if (g('peak_speed_rx')) g('peak_speed_rx').innerText = sessionMaxRx.toFixed(2);
    if (g('peak_speed_tx')) g('peak_speed_tx').innerText = sessionMaxTx.toFixed(2);

    maxVal = Math.ceil(maxVal * 1.15);

    ctx.strokeStyle = '#262626';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for(let i=1; i<4; i++) {
        let y = ((h - 25) / 4) * i;
        ctx.moveTo(0, y); ctx.lineTo(w, y);
    }
    ctx.stroke();

    ctx.fillStyle = '#6b7280';
    ctx.font = '10px monospace';
    ctx.textAlign = 'left';
    ctx.fillText(maxVal.toFixed(1) + ' Mbit/s', 5, 12);
    ctx.fillText((maxVal / 2).toFixed(1) + ' Mbit/s', 5, (h - 25)/2 + 4);

    ctx.fillStyle = '#6b7280';
    ctx.font = '9px monospace';
    ctx.textAlign = 'center';
    
    const ticksCount = 5;
    for (let i = 0; i <= ticksCount; i++) {
        const x = w - (i / ticksCount) * w;
        const timeOffset = (i / ticksCount) * graphRange;
        let timeLabel = '';
        if (timeOffset === 0) {
            timeLabel = 'Сейчас';
        } else if (timeOffset >= 60) {
            timeLabel = '-' + (timeOffset / 60).toFixed(0) + 'м';
        } else {
            timeLabel = '-' + timeOffset.toFixed(0) + 'с';
        }
        
        ctx.strokeStyle = '#374151';
        ctx.beginPath();
        ctx.moveTo(x, h - 22);
        ctx.lineTo(x, h - 26);
        ctx.stroke();
        
        ctx.fillText(timeLabel, x, h - 8);
    }

    const drawLine = (key, strokeColor, fillColor) => {
        ctx.beginPath();
        const points = [];
        const timeWindow = graphRange;
        
        for (let i = 0; i < filtered.length; i++) {
            const d = filtered[i];
            const age = now - d.time;
            if (age > timeWindow) continue;
            
            const x = w - (age / timeWindow) * w;
            const y = h - 25 - (d[key] / maxVal) * (h - 45);
            points.push({x, y});
        }

        if (points.length < 2) return;

        ctx.beginPath();
        ctx.moveTo(points[0].x, points[0].y);
        for (let i = 1; i < points.length; i++) {
            ctx.lineTo(points[i].x, points[i].y);
        }
        ctx.strokeStyle = strokeColor;
        ctx.lineWidth = 2;
        ctx.stroke();

        ctx.lineTo(points[points.length - 1].x, h - 22);
        ctx.lineTo(points[0].x, h - 22);
        ctx.closePath();
        ctx.fillStyle = fillColor;
        ctx.fill();
    };

    drawLine('rx', '#4ade80', 'rgba(74, 222, 128, 0.1)');
    drawLine('tx', '#60a5fa', 'rgba(96, 165, 250, 0.1)');
}

function updateGraphRange() {
    graphRange = parseInt(g('graph_range').value);
    drawChart();
}

function setSpeedtestUrl(url) {
    g('speedtest_url').value = url;
}

function checkSpeedtestStatus() {
    fetch('<%=luci.dispatcher.build_url("admin/modem/speedtest_status")%>')
        .then(res => res.json())
        .then(data => {
            const startBtn = g('btn_start_speedtest');
            const stopBtn = g('btn_stop_speedtest');
            const statusText = g('speedtest_status_text');
            
            if (data.success) {
                if (data.running) {
                    startBtn.disabled = true;
                    startBtn.style.opacity = 0.5;
                    stopBtn.disabled = false;
                    stopBtn.style.opacity = 1;
                    statusText.innerHTML = '<span style="display:inline-block; width:8px; height:8px; border-radius:50%; background:#10b981; box-shadow: 0 0 8px #10b981; animation: pulse 1.5s infinite;"></span> <span style="color:#10b981; font-weight:bold;">Активен (скачивание...)</span>';
                } else {
                    startBtn.disabled = false;
                    startBtn.style.opacity = 1;
                    stopBtn.disabled = true;
                    stopBtn.style.opacity = 0.5;
                    statusText.innerHTML = '<span style="display:inline-block; width:8px; height:8px; border-radius:50%; background:#94a3b8;"></span> Не активен';
                }
            }
        })
        .catch(err => console.error('Speedtest status check failed:', err));
}

function startSpeedtest() {
    const urlVal = g('speedtest_url').value;
    if (!urlVal) return;
    
    g('btn_start_speedtest').disabled = true;
    g('btn_start_speedtest').style.opacity = 0.5;
    
    fetch('<%=luci.dispatcher.build_url("admin/modem/speedtest_start")%>?url=' + encodeURIComponent(urlVal))
        .then(res => res.json())
        .then(data => {
            if (data.success) {
                g('update_interval_select').value = "1000";
                changeUpdateInterval();
                setTimeout(checkSpeedtestStatus, 500);
            } else {
                alert('Ошибка запуска: ' + (data.error || 'неизвестная ошибка'));
                checkSpeedtestStatus();
            }
        })
        .catch(err => {
            console.error(err);
            checkSpeedtestStatus();
        });
}

function stopSpeedtest() {
    g('btn_stop_speedtest').disabled = true;
    g('btn_stop_speedtest').style.opacity = 0.5;
    
    fetch('<%=luci.dispatcher.build_url("admin/modem/speedtest_stop")%>')
        .then(res => res.json())
        .then(data => {
            setTimeout(checkSpeedtestStatus, 500);
        })
        .catch(err => {
            console.error(err);
            checkSpeedtestStatus();
        });
}

window.addEventListener('resize', drawChart);

function fetchModemData() {
    const dev = g('modem_interface_select').value;
    const url = '<%=luci.dispatcher.build_url("admin/modem/data")%>?qmi_dev=' + encodeURIComponent(dev);
    
    const live = g('live_indicator');
    live.style.opacity = 0.5;

    // Constantly poll active background speedtests
    checkSpeedtestStatus();

    fetch(url)
        .then(res => res.json())
        .then(data => {
            live.style.opacity = 1;
            if (data.success && data.lte_rsrp !== null && data.lte_rsrp !== "") {
                retryCount = 0;
                const intervalVal = g('update_interval_select').value;
                g('live_indicator').innerText = intervalVal === "0" ? "○ PAUSED" : "● LIVE SYNC";
                g('live_indicator').style.color = intervalVal === "0" ? "#94a3b8" : "#4ade80";

                let rsrp = null, rsrq = null, sinr = null;
                
                if (data.is_umts) {
                    rsrp = parseFloat(data.lte_rsrp) || null;
                    rsrq = null;
                    sinr = parseFloat(data.lte_snr) || null;
                } else {
                    rsrp = parseFloat(data.lte_rsrp) || null;
                    rsrq = parseFloat(data.lte_rsrq) || null;
                    sinr = parseFloat(data.lte_snr) || null;
                }

                // Render metrics with dynamic coloration
                if (rsrp !== null) {
                    g('giant_rsrp').innerHTML = rsrp + '<span>dBm</span>';
                    g('giant_rsrp').style.color = getRSRPColor(rsrp);
                } else {
                    g('giant_rsrp').innerHTML = '--<span>dBm</span>';
                    g('giant_rsrp').style.color = "#64748b";
                }

                if (rsrq !== null) {
                    g('giant_rsrq').innerHTML = rsrq + '<span>dB</span>';
                    g('giant_rsrq').style.color = getRSRQColor(rsrq);
                } else {
                    g('giant_rsrq').innerHTML = '--<span>dB</span>';
                    g('giant_rsrq').style.color = "#64748b";
                }

                if (sinr !== null) {
                    g('giant_sinr').innerHTML = sinr + '<span>dB</span>';
                    g('giant_sinr').style.color = getSINRColor(sinr);
                } else {
                    g('giant_sinr').innerHTML = '--<span>dB</span>';
                    g('giant_sinr').style.color = "#64748b";
                }

                // Render Details
                g('op_name').innerText = _t(data.plmn_display);
                g('rat_tech').innerText = _t(data.state_str);
                g('head_pci').innerText = data.serv_pci || '-';
                
                const bandStr = data.is_umts ? `B${data.serv_band}` : `B${data.serv_band} (EARFCN: ${data.serv_earfcn}) | BW: ${data.serv_bw} MHz`;
                g('head_band').innerText = bandStr;

                // Speed
                if (data.speed) {
                    g('speed_dl').innerHTML = data.speed.rx_speed.toFixed(2) + ' <span style="font-size: 16px; color: #94a3b8; font-weight: normal;">Mbps</span>';
                    g('speed_ul').innerHTML = data.speed.tx_speed.toFixed(2) + ' <span style="font-size: 16px; color: #94a3b8; font-weight: normal;">Mbps</span>';
                    
                    chartData = data.speed.history || [];
                    drawChart();
                }
            } else {
                if (retryCount < 3) {
                    retryCount++;
                    g('live_indicator').innerText = "● RETRYING (" + retryCount + ")...";
                    g('live_indicator').style.color = "#fbbf24";
                    setTimeout(fetchModemData, 1000);
                } else {
                    g('live_indicator').innerText = "⚠️ ERROR";
                    g('live_indicator').style.color = "#ef4444";
                }
            }
        })
        .catch(err => {
            console.error('Antenna sync failed:', err);
            live.style.opacity = 0.3;
            if (retryCount < 3) {
                retryCount++;
                g('live_indicator').innerText = "● RETRYING (" + retryCount + ")...";
                g('live_indicator').style.color = "#fbbf24";
                setTimeout(fetchModemData, 1000);
            } else {
                g('live_indicator').innerText = "⚠️ ERROR";
                g('live_indicator').style.color = "#ef4444";
            }
        });
}

function changeUpdateInterval() {
    if (tId) clearInterval(tId);
    const val = parseInt(g('update_interval_select').value);
    if (val > 0) {
        tId = setInterval(fetchModemData, val);
        g('live_indicator').innerText = "● LIVE SYNC";
        g('live_indicator').style.color = "#4ade80";
    } else {
        g('live_indicator').innerText = "○ PAUSED";
        g('live_indicator').style.color = "#94a3b8";
    }
}

function startSync() {
    fetchModemData();
    changeUpdateInterval();
}

// Trigger start
setTimeout(startSync, 500);

// Language Translation Logic
const dict = {
    "Отсутствует": "Missing",
    "Нет сети": "No network",
    "Запущена": "Running",
    "Остановлена": "Stopped",
    "Включен": "Enabled",
    "Отключен": "Disabled",
    "Не активен": "Inactive",
    "Активен (скачивание...)": "Active (downloading...)",
    "Выключить": "Disable",
    "Включить": "Enable",
    "Старт": "Start",
    "Стоп": "Stop",
    "Обновление...": "Updating...",
    "перезапуск": "restart",
    "Настройка антенны (Setup Antenna)": "Antenna Setup",
    "Крупный формат вывода ключевых радиопоказателей для юстировки уличных антенн в реальном времени.": "Large format display of key radio metrics for real-time outdoor antenna alignment.",
    "Модемный интерфейс не обнаружен": "Modem interface not detected",
    "Пожалуйста, подключите модем, проверьте питание и убедитесь, что служба ModemManager активна.": "Please connect a modem, check power, and verify that ModemManager is running.",
    "Перезапустить ModemManager": "Restart ModemManager",
    "Перезапустить интерфейс MODEM": "Restart MODEM interface",
    "Применение настроек...": "Applying settings...",
    "Пожалуйста, подождите, выполняется операция перезапуска...": "Please wait, restarting operation is running...",
    "Пожалуйста, подождите, выполняется перезапуск (около 6 сек)...": "Please wait, restarting (about 6 sec)...",
    "Порт модема:": "Modem Port:",
    "Обновление:": "Update interval:",
    "Обновить сейчас": "Update now",
    "Оператор:": "Carrier:",
    "Технология:": "Technology:",
    "PCI:": "PCI:",
    "Сигнал:": "Band/Freq:",
    "Мощность сигнала (RSRP)": "Signal Power (RSRP)",
    "Качество сигнала (RSRQ)": "Signal Quality (RSRQ)",
    "Соотношение сигнал/шум (SINR)": "Signal to Noise Ratio (SINR)",
    "Текущий Downlink (Скачивание)": "Current Downlink (DL)",
    "Текущий Uplink (Отдача)": "Current Uplink (UL)",
    "График скорости в реальном времени": "Real-time Speed Chart",
    "Диапазон:": "Range:",
    "СРЕДНЯЯ (DL / UL)": "AVERAGE (DL / UL)",
    "ПИКОВАЯ (DL / UL)": "PEAK (DL / UL)",
    "Генератор входящего трафика для теста скорости": "Incoming Traffic Generator for Speed Test",
    "Выберите или введите ссылку для скачивания (прямая ссылка на файл):": "Select or enter a download URL (direct link to file):",
    "Тестовые ссылки (могут быть недоступны):": "Test links (may be unavailable):",
    "Статус генератора:": "Generator Status:",
    "Ожидание данных скорости...": "Waiting for speed data...",
    "Сейчас": "Now",
    "выкл": "off",
    "1 сек": "1 sec",
    "3 сек": "3 sec",
    "5 сек": "5 sec",
    "30 сек": "30 sec",
    "1 мин": "1 min",
    "5 мин": "5 min"
};

function _t(str) {
    if (!str) return str;
    const lang = localStorage.getItem('modem_lang') || 'ru';
    if (lang === 'ru') return str;
    return dict[str] || str;
}

function changeLanguage(lang) {
    localStorage.setItem('modem_lang', lang);
    document.cookie = "modem_lang=" + lang + "; path=/; max-age=31536000";
    const selects = document.querySelectorAll('#lang_select');
    selects.forEach(s => s.value = lang);
    translatePage(lang);
}

function translatePage(lang) {
    const elements = document.querySelectorAll('h3, h4, h5, p, label, button, span, strong, option, th, td, a, div.sim-row, div.ant-label, small, div, input, select');
    const sortedKeys = Object.keys(dict).sort((a, b) => b.length - a.length);
    elements.forEach(el => {
        // Translate text nodes
        let hasTextChild = false;
        for (let node of el.childNodes) {
            if (node.nodeType === Node.TEXT_NODE && node.nodeValue.trim().length > 0) {
                hasTextChild = true;
                break;
            }
        }
        if (hasTextChild) {
            if (!el.hasAttribute('data-ru')) {
                el.setAttribute('data-ru', el.innerHTML);
            }
            const origRu = el.getAttribute('data-ru');
            if (lang === 'en') {
                let translated = origRu;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.innerHTML = translated;
            } else {
                el.innerHTML = origRu;
            }
        }

        // Translate placeholders
        if (el.placeholder) {
            if (!el.hasAttribute('data-placeholder-ru')) {
                el.setAttribute('data-placeholder-ru', el.placeholder);
            }
            const origPl = el.getAttribute('data-placeholder-ru');
            if (lang === 'en') {
                let translated = origPl;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.placeholder = translated;
            } else {
                el.placeholder = origPl;
            }
        }

        // Translate titles
        if (el.title) {
            if (!el.hasAttribute('data-title-ru')) {
                el.setAttribute('data-title-ru', el.title);
            }
            const origTitle = el.getAttribute('data-title-ru');
            if (lang === 'en') {
                let translated = origTitle;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.title = translated;
            } else {
                el.title = origTitle;
            }
        }
    });
}

// Initial language setup
const currentLang = localStorage.getItem('modem_lang') || 'ru';
document.cookie = "modem_lang=" + currentLang + "; path=/; max-age=31536000";
const select = document.getElementById('lang_select');
if (select) select.value = currentLang;
setTimeout(() => translatePage(currentLang), 100);
</script>

<% end %>
<%+footer%>

EOF

echo "Deploying /usr/lib/lua/luci/view/modem/sms.htm..."
cat << \EOF > /usr/lib/lua/luci/view/modem/sms.htm
<%+header%>
<%
    local http = require "luci.http"

    local jsonc = require "luci.jsonc"

    local function exec(cmd)
        local h = io.popen(cmd .. " 2>/dev/null")
        if h then
            local res = h:read("*a")
            h:close()
            return res or ""
        end
        return ""
    end

    local ARCHIVE_FILE = "/etc/sms_archive.json"

    local mmcli_idx = http.formvalue("mmcli_idx") or "any"

    local send_error = ""

    -- Обработка отправки SMS
    if http.formvalue("send_sms") then
        local num = http.formvalue("sms_number")
        local txt = http.formvalue("sms_text")
        if num and txt and num ~= "" and txt ~= "" then
            -- Проверка статуса модема
            local m_out = exec("mmcli -m " .. mmcli_idx)
            local m_state = m_out:match("state:%s*([^\n]+)") or "unknown"
            
            if not m_state:match("connected") then
                send_error = "Модем не подключен к сети (статус: " .. m_state .. "). Отправка SMS невозможна."
            else
                -- Очистка от кавычек во избежание инъекций
                local safe_num = num:gsub("'", ""):gsub('"', "")
                local safe_txt = txt:gsub("'", "'\\''")
                
                -- Шаг 1: Создание SMS
                local create_cmd = string.format("mmcli -m %s --messaging-create-sms=\"text='%s',number='%s'\"", mmcli_idx, safe_txt, safe_num)
                local create_out = exec(create_cmd)
                local new_sms_path = create_out:match("SMS/(%d+)")
                
                if new_sms_path then
                    -- Шаг 2: Отправка SMS синхронно
                    os.execute(string.format("mmcli -s %s --send >/dev/null 2>&1", new_sms_path))
                    os.execute("sleep 1") 
                    -- Запуск синхронизации, чтобы отправленное сообщение попало в архив
                    os.execute("/usr/bin/sms_sync.lua")
                end
                
                -- Редирект после успешной отправки
                http.redirect(luci.dispatcher.build_url('admin/modem/sms'))
                return
            end
        end
    end

    -- Обработка удаления SMS
    if http.formvalue("delete_sms") then
        local del_id = http.formvalue("delete_sms")
        local f = io.open(ARCHIVE_FILE, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content and content ~= "" then
                local archive = jsonc.parse(content) or {}
                local new_arc = {}
                for _, s in ipairs(archive) do
                    if s.id ~= del_id then
                        table.insert(new_arc, s)
                    end
                end
                local out_f = io.open(ARCHIVE_FILE, "w")
                if out_f then
                    out_f:write(jsonc.stringify(new_arc))
                    out_f:close()
                end
            end
        end
        http.redirect(luci.dispatcher.build_url('admin/modem/sms'))
        return
    end

    -- Обработка добавления в sysupgrade
    if http.formvalue("add_sysupgrade") then
        os.execute("grep -q '/etc/sms_archive.json' /etc/sysupgrade.conf 2>/dev/null || echo '/etc/sms_archive.json' >> /etc/sysupgrade.conf")
        http.redirect(luci.dispatcher.build_url('admin/modem/sms'))
        return
    end

    -- Запуск принудительной синхронизации перед загрузкой страницы
    os.execute("/usr/bin/sms_sync.lua")

    -- Чтение архива для отображения
    local received_sms = {}
    local sent_sms = {}
    local archive = {}
    
    local f = io.open(ARCHIVE_FILE, "r")
    if f then
        local content = f:read("*a")
        f:close()
        if content and content ~= "" then
            archive = jsonc.parse(content) or {}
        end
    end

    for _, sms_obj in ipairs(archive) do
        if sms_obj.state == "received" then
            table.insert(received_sms, sms_obj)
        elseif sms_obj.state == "sent" then
            table.insert(sent_sms, sms_obj)
        end
    end

    -- Сортировка: новые сверху (по saved_at или timestamp)
    local function sort_sms(a, b) 
        return (tonumber(a.saved_at) or 0) > (tonumber(b.saved_at) or 0) 
    end
    table.sort(received_sms, sort_sms)
    table.sort(sent_sms, sort_sms)

    -- Проверка наличия архива в sysupgrade.conf
    local sysconf_check = exec("grep '/etc/sms_archive.json' /etc/sysupgrade.conf 2>/dev/null")
    local is_in_sysupgrade = (sysconf_check:match("sms_archive.json") ~= nil)
%>

<div class="cbi-section">
    <div class="cbi-section-node" style="padding: 10px 0; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px;">
        <div>
            <h3 style="margin-bottom: 5px; color: #ffffff;">Панель SMS (ModemManager)</h3>
        </div>
        <div style="display: flex; align-items: center; gap: 6px; background: rgba(30, 41, 59, 0.7); backdrop-filter: blur(8px); padding: 4px 8px; border-radius: 6px; border: 1px solid rgba(255, 255, 255, 0.08); height: fit-content; margin-right: 15px;">
            <span style="font-size: 12px; color: #94a3b8;">🌐 Language:</span>
            <select id="lang_select" onchange="changeLanguage(this.value)" style="background: transparent; color: #f8fafc; border: none; font-size: 12px; cursor: pointer; outline: none; padding: 0 4px; font-weight: 500;">
                <option value="ru" style="background: #1e293b; color: #f8fafc;">RU</option>
                <option value="en" style="background: #1e293b; color: #f8fafc;">EN</option>
            </select>
        </div>
    </div>
    <div style="background-color: #7f1d1d; border-left: 4px solid #ef4444; color: #fca5a5; padding: 10px 15px; margin-top: 10px; margin-bottom: 15px; border-radius: 4px; font-size: 13px;">
        <strong>⚠️ Внимание:</strong> Если при обновлении прошивки роутера (sysupgrade) вы <strong>снимете</strong> галочку "Сохранять настройки", <strong>все архивированные здесь SMS будут безвозвратно удалены!</strong>
            <% if not is_in_sysupgrade then %>
            <br>Для надежности убедитесь, что путь <code>/etc/sms_archive.json</code> добавлен в список файлов для сохранения (<code>/etc/sysupgrade.conf</code>).
            <form method="post" action="<%=luci.dispatcher.build_url('admin/modem/sms')%>" style="margin-top: 10px;">
                <button type="submit" name="add_sysupgrade" value="1" class="cbi-button cbi-button-apply" style="padding: 6px 12px; font-weight: bold;">Добавить автоматически</button>
            </form>
            <% end %>
        </div>
    </div>
</div>

<style>
.sms-dash { background-color:#1e293b; color:#d1d5db; padding:20px; border-radius:6px; margin-bottom:15px; font-family:sans-serif;}
.sms-dash h4 { color:#fff; border-bottom:1px solid #334155; padding-bottom:8px; margin-top:0; font-weight:normal; }
.sms-card { background-color:#0f172a; border:1px solid #334155; border-radius:6px; padding:12px; margin-bottom:12px; }
.sms-header { display:flex; justify-content:space-between; margin-bottom:10px; font-size:13px; color:#94a3b8; border-bottom:1px dashed #334155; padding-bottom:5px; }
.sms-body { color:#f8fafc; font-size:14px; white-space:pre-wrap; line-height:1.5; }
.sms-input { width:100%; max-width:400px; background:#0f172a; color:#fff; border:1px solid #3b82f6; padding:8px 12px; border-radius:4px; margin-bottom:15px; box-sizing:border-box; outline:none; }
.sms-input:focus { border-color:#60a5fa; }
.sms-textarea { width:100%; height:100px; background:#0f172a; color:#fff; border:1px solid #3b82f6; padding:10px 12px; border-radius:4px; resize:vertical; box-sizing:border-box; font-family:inherit; outline:none; }
.sms-textarea:focus { border-color:#60a5fa; }
.btn-del { background:none; border:none; color:#ef4444; cursor:pointer; font-size:13px; font-weight:bold; }
.btn-del:hover { color:#f87171; text-decoration:underline; }
.char-counter { font-size:13px; color:#94a3b8; margin-top:5px; margin-bottom:15px; }
</style>

<!-- Форма отправки SMS -->
<div class="sms-dash">
    <h4>Написать SMS</h4>
    
    <% if send_error ~= "" then %>
        <div style="background-color: #7f1d1d; border-left: 4px solid #ef4444; color: #fca5a5; padding: 10px 15px; margin-bottom: 15px; border-radius: 4px;">
            <strong>Ошибка:</strong> <%=send_error%>
        </div>
    <% end %>

    <form id="sms-send-form" method="post" action="<%=luci.dispatcher.build_url('admin/modem/sms')%>" onsubmit="return validateSMSForm(event)">
        <label style="color:#e2e8f0; display:block; margin-bottom:5px; font-weight:bold;">Номер телефона:</label>
        <input type="text" name="sms_number" class="sms-input" placeholder="+7..." required>
        
        <label style="color:#e2e8f0; display:block; margin-bottom:5px; font-weight:bold;">Сообщение:</label>
        <textarea name="sms_text" id="sms_text" class="sms-textarea" placeholder="Введите текст сообщения..." oninput="updateCounter()" required></textarea>
        
        <div class="char-counter" id="char_counter">
            Длина: 0 | SMS: 0 (макс 160 симв. латиница / 70 симв. кириллица)
        </div>
        
        <button type="submit" name="send_sms" value="1" class="cbi-button cbi-button-apply" style="padding:10px 20px; font-weight:bold;">Отправить SMS</button>
    </form>
</div>

<!-- Полученные SMS -->
<div class="sms-dash">
    <h4>Полученные сообщения <span style="background:#3b82f6; color:#fff; border-radius:10px; padding:2px 8px; font-size:12px; margin-left:10px;"><%=#received_sms%></span></h4>
    <% if #received_sms == 0 then %>
        <div style="color:#94a3b8; font-style:italic;">Нет полученных сообщений.</div>
    <% else %>
        <% for _, s in ipairs(received_sms) do %>
            <div class="sms-card">
                <div class="sms-header">
                    <span>От: <strong style="color:#60a5fa;"><%=s.number%></strong></span>
                    <span><%=s.timestamp%></span>
                </div>
                <div class="sms-body"><%=s.text%></div>
                <div style="text-align:right; margin-top:10px;">
                    <form method="post" action="<%=luci.dispatcher.build_url('admin/modem/sms')%>" style="display:inline;" onsubmit="return confirm('Удалить это сообщение?');">
                        <input type="hidden" name="delete_sms" value="<%=s.id%>">
                        <button type="submit" class="btn-del">Удалить</button>
                    </form>
                </div>
            </div>
        <% end %>
    <% end %>
</div>

<!-- Отправленные SMS -->
<div class="sms-dash">
    <h4>Отправленные сообщения <span style="background:#10b981; color:#fff; border-radius:10px; padding:2px 8px; font-size:12px; margin-left:10px;"><%=#sent_sms%></span></h4>
    <% if #sent_sms == 0 then %>
        <div style="color:#94a3b8; font-style:italic;">Нет отправленных сообщений.</div>
    <% else %>
        <% for _, s in ipairs(sent_sms) do %>
            <div class="sms-card">
                <div class="sms-header">
                    <span>Кому: <strong style="color:#34d399;"><%=s.number%></strong></span>
                    <span><%=s.timestamp%></span>
                </div>
                <div class="sms-body"><%=s.text%></div>
                <div style="text-align:right; margin-top:10px;">
                    <form method="post" action="<%=luci.dispatcher.build_url('admin/modem/sms')%>" style="display:inline;" onsubmit="return confirm(_t('Удалить это сообщение?'));">
                        <input type="hidden" name="delete_sms" value="<%=s.id%>">
                        <button type="submit" class="btn-del">${_t('Удалить')}</button>
                    </form>
                </div>
            </div>
        <% end %>
    <% end %>
</div>

<script>
function updateCounter() {
    let txt = document.getElementById('sms_text').value;
    
    // Проверка на наличие кириллицы (UCS-2)
    let isCyrillic = /[А-Яа-яЁё]/.test(txt);
    
    // GSM-7 bit = 160 символов, UCS-2 = 70 символов
    let maxLen = isCyrillic ? 70 : 160;
    
    // Подсчет количества SMS-частей
    // (на самом деле при склейке длинных SMS лимиты 153 для GSM и 67 для UCS-2, но для простоты оставим базовые)
    let smsCount = 0;
    if (txt.length > 0) {
        if (txt.length <= maxLen) {
            smsCount = 1;
        } else {
            let partLen = isCyrillic ? 67 : 153;
            smsCount = Math.ceil(txt.length / partLen);
        }
    }
    
    let info = isCyrillic 
        ? '<span style="color:#fbbf24;">' + _t('(Кириллица, лимит 1 части: 70 симв.)') + '</span>' 
        : '<span style="color:#4ade80;">' + _t('(Латиница, лимит 1 части: 160 симв.)') + '</span>';
        
    if (txt.length === 0) info = "";
    
    document.getElementById('char_counter').innerHTML = 
        _t("Длина:") + " <strong>" + txt.length + "</strong> | " + _t("Количество частей SMS:") + " <strong>" + smsCount + "</strong> " + info;
}

function validateSMSForm(event) {
    event.preventDefault();
    const form = event.target;
    const btn = form.querySelector('button[type="submit"]');
    const oldText = btn.innerText;
    btn.innerHTML = '<span style="border: 2px solid rgba(255,255,255,.3); border-top-color: #fff; width: 12px; height: 12px; border-radius: 50%; display: inline-block; vertical-align: middle; margin-right: 5px; animation: spin 1s infinite;"></span> ' + _t('Проверка модема...');
    btn.disabled = true;

    fetch('<%=luci.dispatcher.build_url("admin/modem/data")%>')
        .then(res => res.json())
        .then(data => {
            if (data && data.success) {
                form.submit();
            } else {
                alert(_t("Ошибка: модемный интерфейс не обнаружен! Отправка SMS невозможна."));
                btn.innerText = oldText;
                btn.disabled = false;
            }
        })
        .catch(err => {
            alert(_t("Ошибка при проверке интерфейса модема:") + " " + err);
            btn.innerText = oldText;
            btn.disabled = false;
        });

    return false;
}

// Language Translation Logic
const dict = {
    "Панель SMS (ModemManager)": "SMS Dashboard (ModemManager)",
    "⚠️ Внимание:": "⚠️ Warning:",
    "Если при обновлении прошивки роутера (sysupgrade) вы <strong>снимете</strong> галочку \"Сохранять настройки\", <strong>все архивированные здесь SMS будут безвозвратно удалены!</strong>": "If you <strong>uncheck</strong> the \"Keep settings\" checkbox during router firmware update (sysupgrade), <strong>all archived SMS here will be permanently deleted!</strong>",
    "Для надежности убедитесь, что путь <code>/etc/sms_archive.json</code> добавлен в список файлов для сохранения (<code>/etc/sysupgrade.conf</code>).": "For reliability, make sure that the path <code>/etc/sms_archive.json</code> is added to the list of files to save (<code>/etc/sysupgrade.conf</code>).",
    "Добавить автоматически": "Add automatically",
    "Написать SMS": "Write SMS",
    "Номер телефона:": "Phone number:",
    "Сообщение:": "Message:",
    "Длина: 0 | SMS: 0 (макс 160 симв. латиница / 70 симв. кириллица)": "Length: 0 | SMS: 0 (max 160 chars latin / 70 chars cyrillic)",
    "Отправить SMS": "Send SMS",
    "Полученные сообщения": "Received messages",
    "Нет полученных сообщений.": "No received messages.",
    "От:": "From:",
    "Удалить": "Delete",
    "Отправленные сообщения": "Sent messages",
    "Нет отправленных сообщений.": "No sent messages.",
    "Кому:": "To:",
    "Удалить это сообщение?": "Delete this message?",
    "Длина:": "Length:",
    "Количество частей SMS:": "SMS parts count:",
    "(Кириллица, лимит 1 части: 70 симв.)": "(Cyrillic, limit of 1 part: 70 chars)",
    "(Латиница, лимит 1 части: 160 симв.)": "(Latin, limit of 1 part: 160 chars)",
    "Проверка модема...": "Checking modem...",
    "Ошибка: модемный интерфейс не обнаружен! Отправка SMS невозможна.": "Error: modem interface not found! Unable to send SMS.",
    "Ошибка при проверке интерфейса модема:": "Error verifying modem interface:",
    "Ошибка:": "Error:"
};

function _t(str) {
    if (!str) return str;
    const lang = localStorage.getItem('modem_lang') || 'ru';
    if (lang === 'ru') return str;
    return dict[str] || str;
}

function changeLanguage(lang) {
    localStorage.setItem('modem_lang', lang);
    document.cookie = "modem_lang=" + lang + "; path=/; max-age=31536000";
    const selects = document.querySelectorAll('#lang_select');
    selects.forEach(s => s.value = lang);
    translatePage(lang);
}

function translatePage(lang) {
    const elements = document.querySelectorAll('h3, h4, h5, p, label, button, span, strong, option, th, td, a, div, input, select');
    const sortedKeys = Object.keys(dict).sort((a, b) => b.length - a.length);
    elements.forEach(el => {
        // Translate text nodes
        let hasTextChild = false;
        for (let node of el.childNodes) {
            if (node.nodeType === Node.TEXT_NODE && node.nodeValue.trim().length > 0) {
                hasTextChild = true;
                break;
            }
        }
        if (hasTextChild) {
            if (!el.hasAttribute('data-ru')) {
                el.setAttribute('data-ru', el.innerHTML);
            }
            const origRu = el.getAttribute('data-ru');
            if (lang === 'en') {
                let translated = origRu;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.innerHTML = translated;
            } else {
                el.innerHTML = origRu;
            }
        }

        // Translate placeholders
        if (el.placeholder) {
            if (!el.hasAttribute('data-placeholder-ru')) {
                el.setAttribute('data-placeholder-ru', el.placeholder);
            }
            const origPl = el.getAttribute('data-placeholder-ru');
            if (lang === 'en') {
                let translated = origPl;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.placeholder = translated;
            } else {
                el.placeholder = origPl;
            }
        }

        // Translate titles
        if (el.title) {
            if (!el.hasAttribute('data-title-ru')) {
                el.setAttribute('data-title-ru', el.title);
            }
            const origTitle = el.getAttribute('data-title-ru');
            if (lang === 'en') {
                let translated = origTitle;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.title = translated;
            } else {
                el.title = origTitle;
            }
        }
    });
}

// Initial language setup
const currentLang = localStorage.getItem('modem_lang') || 'ru';
document.cookie = "modem_lang=" + currentLang + "; path=/; max-age=31536000";
const select = document.getElementById('lang_select');
if (select) select.value = currentLang;
setTimeout(() => translatePage(currentLang), 100);
</script>

<%+footer%>

EOF

echo "Deploying /usr/lib/lua/luci/view/modem/esim.htm..."
cat << \EOF > /usr/lib/lua/luci/view/modem/esim.htm
<%+header%>
<%
    local http = require "luci.http"

    local act = http.formvalue("action")
    if act == "restart_mm" then
        os.execute("/etc/init.d/modemmanager restart")
        os.execute("sleep 6")
        http.redirect(http.getenv("REQUEST_URI"):gsub("%?.*$", ""))
        return
    elseif act == "restart_iface" then
        os.execute("ifdown MODEM && sleep 3 && ifup MODEM")
        os.execute("sleep 6")
        http.redirect(http.getenv("REQUEST_URI"):gsub("%?.*$", ""))
        return
    end

    local function exec(cmd)
        local h = io.popen(cmd .. " 2>/dev/null")
        if h then
            local res = h:read("*a")
            h:close()
            return res or ""
        end
        return ""
    end
    
    local m_list = exec("mmcli -L") or ""
    local has_modem = (m_list:match("ModemManager1/Modem/(%d+)") ~= nil)
%>

<div class="cbi-section">
    <div class="cbi-section-node" style="padding: 10px 0; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px;">
        <div>
            <h3 style="margin-bottom: 5px; color: #ffffff;">Управление eSIM (LPAC)</h3>
        </div>
        <div style="display: flex; align-items: center; gap: 6px; background: rgba(30, 41, 59, 0.7); backdrop-filter: blur(8px); padding: 4px 8px; border-radius: 6px; border: 1px solid rgba(255, 255, 255, 0.08); height: fit-content; margin-right: 15px;">
            <span style="font-size: 12px; color: #94a3b8;">🌐 Language:</span>
            <select id="lang_select" onchange="changeLanguage(this.value)" style="background: transparent; color: #f8fafc; border: none; font-size: 12px; cursor: pointer; outline: none; padding: 0 4px; font-weight: 500;">
                <option value="ru" style="background: #1e293b; color: #f8fafc;">RU</option>
                <option value="en" style="background: #1e293b; color: #f8fafc;">EN</option>
            </select>
        </div>
    </div>
</div>

<% if not has_modem then %>
    <div style="background: #1e293b; border-left: 4px solid #ef4444; border-radius: 8px; padding: 24px; text-align: center; box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1);">
        <h3 style="color: #ef4444; margin-top: 0; font-size: 20px;">⚠️ Модемный интерфейс не обнаружен</h3>
        <p style="color: #94a3b8; margin: 0; font-size: 14px; margin-bottom: 20px;">Пожалуйста, подключите модем, проверьте питание и убедитесь, что служба ModemManager активна.</p>
        
        <div style="display: flex; justify-content: center; gap: 15px; flex-wrap: wrap;">
            <a href="?action=restart_mm" style="display: inline-block; padding: 8px 16px; background-color: #3b82f6; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезапуск службы ModemManager...')">Перезапустить ModemManager</a>
            <a href="?action=restart_iface" style="display: inline-block; padding: 8px 16px; background-color: #f59e0b; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезапуск интерфейса MODEM...')">Перезапустить интерфейс MODEM</a>
        </div>
    </div>

    <div id="apply_overlay" style="display:none; position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(15,23,42,0.95); z-index:99999; justify-content:center; align-items:center; flex-direction:column; color:#fff; font-family:sans-serif; backdrop-filter:blur(5px);">
        <div class="spinning" style="width:60px; height:60px; border:4px solid #334155; border-top-color:#3b82f6; border-radius:50%; animation:spin 1s linear infinite; margin-bottom:20px;"></div>
        <div id="overlay_title" style="font-size:20px; font-weight:bold; color:#f8fafc;">Применение настроек...</div>
        <div id="overlay_subtitle" style="font-size:14px; color:#94a3b8; margin-top:8px; text-align:center; max-width:400px; padding:0 20px; line-height:1.5;">Пожалуйста, подождите, выполняется операция перезапуска...</div>
    </div>
    <style>
    @keyframes spin { to { transform: rotate(360deg); } }
    </style>
    <script>
    function showRecoveryOverlay(title) {
        document.getElementById('overlay_title').innerText = title;
        document.getElementById('overlay_subtitle').innerText = "Пожалуйста, подождите, выполняется перезапуск (около 6 сек)...";
        document.getElementById('apply_overlay').style.display = 'flex';
    }
    </script>
<% else %>

<style>
.esim-dash { background-color:#1e293b; color:#d1d5db; padding:20px; border-radius:6px; margin-bottom:15px; font-family:sans-serif;}
.esim-dash h4 { color:#fff; border-bottom:1px solid #334155; padding-bottom:8px; margin-top:0; font-weight:normal; }
.profile-card { background-color:#0f172a; border:1px solid #334155; border-radius:6px; padding:15px; margin-bottom:12px; display: flex; justify-content: space-between; align-items: center; }
.profile-active { border-color: #4ade80; }
.profile-info { flex-grow: 1; }
.profile-actions { display: flex; gap: 10px; flex-wrap: wrap; }
.btn-action { background:#3b82f6; color:#fff; border:none; padding:6px 12px; border-radius:4px; cursor:pointer; font-weight:bold; font-size:13px; }
.btn-action:hover { background:#2563eb; }
.btn-danger { background:#ef4444; }
.btn-danger:hover { background:#dc2626; }
.btn-success { background:#10b981; }
.btn-success:hover { background:#059669; }
.input-text { background:#0f172a; color:#fff; border:1px solid #3b82f6; padding:8px 12px; border-radius:4px; margin-bottom:10px; width:100%; box-sizing:border-box; outline:none; }
.spinner { border: 3px solid rgba(255,255,255,.3); border-radius: 50%; border-top-color: #fff; width: 16px; height: 16px; animation: spin 1s ease-in-out infinite; display: inline-block; vertical-align: middle; margin-right: 5px; }
@keyframes spin { to { transform: rotate(360deg); } }
.toast { position: fixed; bottom: 20px; right: 20px; background: #334155; color: #fff; padding: 15px 20px; border-radius: 6px; box-shadow: 0 4px 6px rgba(0,0,0,0.3); z-index: 1000; display: none; }
</style>

<div id="toast" class="toast"></div>

<!-- Информация о чипе -->
<div class="esim-dash">
    <h4>Информация об eSIM</h4>
    <div id="esim-status-container">
        <div class="spinner"></div> Загрузка информации о чипе...
    </div>
</div>

<!-- Список профилей -->
<div class="esim-dash">
    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px;">
        <h4 style="margin-bottom: 0; border: none; padding: 0;">Установленные профили</h4>
        <button class="btn-action" onclick="loadProfiles()">Обновить список</button>
    </div>
    <div id="profiles-container">
        <div class="spinner"></div> Загрузка профилей...
    </div>
</div>

<!-- Настройка APN сотовой сети -->
<div class="esim-dash">
    <h4>Настройка APN сотовой сети</h4>
    <div style="display: flex; gap: 10px; align-items: center; max-width: 500px; margin-bottom: 10px;">
        <input type="text" id="cell-apn" class="input-text" style="margin-bottom: 0;" placeholder="Например: plus, globaldata, internet.proximus.be">
        <button class="btn-action btn-success" onclick="saveAPN()">Сохранить APN</button>
    </div>
    <div id="apn-status" style="font-size: 13px; color: #94a3b8;">
        Загрузка APN...
    </div>
</div>

<!-- Загрузка профиля -->
<div class="esim-dash">
    <h4>Добавить новый профиль</h4>
    
    <div style="margin-bottom: 15px;">
        <label style="color:#e2e8f0; display:block; margin-bottom:5px; font-weight:bold;">Вариант 1: Загрузить QR-код (Картинка)</label>
        <input type="file" id="qr-file" accept="image/*" class="input-text" style="background: transparent; border: 1px dashed #3b82f6; cursor: pointer;" onchange="decodeQR(this)">
        <small style="color: #9ca3af;">Изображение обрабатывается локально в вашем браузере.</small>
    </div>
    
    <div style="border-top: 1px solid #334155; margin: 20px 0;"></div>
    
    <div style="margin-bottom: 15px;">
        <label style="color:#e2e8f0; display:block; margin-bottom:5px; font-weight:bold;">Вариант 2: Ручной ввод</label>
        <input type="text" id="smdp-server" class="input-text" placeholder="SM-DP+ Server (например: lpa.example.com)">
        <input type="text" id="activation-code" class="input-text" placeholder="Activation Code">
        <input type="text" id="confirmation-code" class="input-text" placeholder="Confirmation Code (если требуется)">
    </div>
    
    <!-- Скрытое поле для распарсенного QR-кода -->
    <input type="hidden" id="qr-result">
    
    <button id="btn-download" class="btn-action btn-success" style="padding:10px 20px;" onclick="downloadProfile()">Загрузить профиль на eSIM</button>
</div>

<script src="https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.min.js"></script>
<script>
const API_BASE = "<%=luci.dispatcher.build_url('admin/modem/esim')%>";

function showToast(msg, isError = false) {
    const toast = document.getElementById('toast');
    toast.innerText = msg;
    toast.style.background = isError ? '#ef4444' : '#10b981';
    toast.style.display = 'block';
    setTimeout(() => { toast.style.display = 'none'; }, 5000);
}

function req(endpoint, data, cb) {
    let xhr = new XMLHttpRequest();
    xhr.open("POST", API_BASE + "/" + endpoint, true);
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
            try {
                let res = JSON.parse(xhr.responseText);
                cb(res);
            } catch(e) {
                cb({success: false, error: "Invalid JSON response"});
            }
        }
    };
    let params = [];
    if(data) {
        for (let k in data) { params.push(encodeURIComponent(k) + "=" + encodeURIComponent(data[k])); }
    }
    xhr.send(params.join("&"));
}

function loadStatus() {
    document.getElementById('esim-status-container').innerHTML = '<div class="spinner"></div> ' + _t('Загрузка...');
    req("status", null, function(res) {
        if(res.success) {
            document.getElementById('esim-status-container').innerHTML = `
                <div style="margin-bottom: 5px;"><strong>EID:</strong> <span style="color:#60a5fa; font-family:monospace;">${res.eid}</span></div>
                <div style="margin-bottom: 5px;"><strong>${_t('Свободная память:')}</strong> ${res.info && res.info.extCardResource ? res.info.extCardResource.freeNonVolatileMemory + ' bytes' : _t('Неизвестно')}</div>
            `;
        } else {
            document.getElementById('esim-status-container').innerHTML = `<div style="color:#ef4444;">${_t('Ошибка:')} ${res.error}</div>`;
        }
    });
}

function loadProfiles() {
    document.getElementById('profiles-container').innerHTML = '<div class="spinner"></div> ' + _t('Загрузка...');
    req("profiles", null, function(res) {
        if(res.success) {
            if(!res.profiles || res.profiles.length === 0) {
                document.getElementById('profiles-container').innerHTML = '<div style="color:#9ca3af;">' + _t('Нет установленных профилей.') + '</div>';
                return;
            }
            let html = '';
            res.profiles.forEach(p => {
                let isActive = p.profileState === 1;
                html += `
                <div class="profile-card ${isActive ? 'profile-active' : ''}">
                    <div class="profile-info">
                        <div style="font-size: 16px; font-weight: bold; color: ${isActive ? '#4ade80' : '#fff'}; margin-bottom: 4px;">
                            ${p.profileNickname ? p.profileNickname : (p.serviceProviderName || 'Unknown Provider')}
                        </div>
                        <div style="font-size: 13px; color: #94a3b8; font-family: monospace; margin-bottom: 4px;">ICCID: ${p.iccid}</div>
                        <div style="font-size: 13px; color: #94a3b8;">${_t('Провайдер:')} ${p.serviceProviderName || '-'}</div>
                        <div style="font-size: 13px; color: #94a3b8;">${_t('Состояние:')} ${isActive ? _t('Активен') : _t('Отключен')}</div>
                    </div>
                    <div class="profile-actions">
                        <button class="btn-action ${isActive ? 'btn-danger' : 'btn-success'}" onclick="toggleProfile('${p.iccid}', '${isActive ? 'disable' : 'enable'}', this)">
                            ${isActive ? _t('Отключить') : _t('Включить')}
                        </button>
                        <button class="btn-action" onclick="renameProfile('${p.iccid}', '${p.profileNickname || ''}', this)">${_t('Переименовать')}</button>
                        <button class="btn-action btn-danger" onclick="deleteProfile('${p.iccid}', this)" ${isActive ? 'disabled style="opacity:0.5; cursor:not-allowed;" title="' + _t('Отключите профиль перед удалением') + '"' : ''}>${_t('Удалить')}</button>
                    </div>
                </div>`;
            });
            document.getElementById('profiles-container').innerHTML = html;
        } else {
            document.getElementById('profiles-container').innerHTML = `<div style="color:#ef4444;">${_t('Ошибка:')} ${res.error}</div>`;
        }
    });
}

function toggleProfile(iccid, action, btn) {
    if(!confirm(_t(`Вы уверены, что хотите ${action === 'enable' ? 'включить' : 'отключить'} этот профиль? Модем может перезагрузиться.`))) return;
    let oldTxt = btn.innerText;
    btn.innerHTML = '<div class="spinner"></div> ' + _t('Пожалуйста, ждите...');
    btn.disabled = true;
    req("toggle", {iccid: iccid, action: action}, function(res) {
        if(res.success) {
            showToast(_t(res.message));
            setTimeout(loadProfiles, 2000); // refresh list
        } else {
            showToast(_t("Ошибка:") + " " + res.error, true);
            btn.innerText = oldTxt;
            btn.disabled = false;
        }
    });
}

function deleteProfile(iccid, btn) {
    if(!confirm(_t('ВНИМАНИЕ! Удаление профиля необратимо. Вы уверены?'))) return;
    let oldTxt = btn.innerText;
    btn.innerHTML = '<div class="spinner"></div> ...';
    btn.disabled = true;
    req("delete", {iccid: iccid}, function(res) {
        if(res.success) {
            showToast(_t("Профиль успешно удален"));
            loadProfiles();
        } else {
            showToast(_t("Ошибка удаления:") + " " + res.error, true);
            btn.innerText = oldTxt;
            btn.disabled = false;
        }
    });
}

function renameProfile(iccid, currName, btn) {
    let newName = prompt(_t("Введите новое имя профиля:"), currName);
    if(newName === null || newName === currName) return;
    let oldTxt = btn.innerText;
    btn.innerHTML = '<div class="spinner"></div> ...';
    btn.disabled = true;
    req("nickname", {iccid: iccid, nickname: newName}, function(res) {
        if(res.success) {
            showToast(_t("Имя профиля изменено"));
            loadProfiles();
        } else {
            showToast(_t("Ошибка переименования:") + " " + res.error, true);
            btn.innerText = oldTxt;
            btn.disabled = false;
        }
    });
}

function decodeQR(input) {
    if (input.files && input.files[0]) {
        var reader = new FileReader();
        reader.onload = function(e) {
            var img = new Image();
            img.onload = function() {
                var canvas = document.createElement('canvas');
                var ctx = canvas.getContext('2d');
                canvas.width = img.width;
                canvas.height = img.height;
                ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
                var imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
                if(typeof jsQR !== "undefined") {
                    var code = jsQR(imageData.data, imageData.width, imageData.height, { inversionAttempts: "dontInvert" });
                    if (code) {
                        document.getElementById('qr-result').value = code.data;
                        showToast(_t("QR-код успешно распознан!"));
                        // Очистим ручные поля
                        document.getElementById('smdp-server').value = "";
                        document.getElementById('activation-code').value = "";
                    } else {
                        showToast(_t("Не удалось найти или прочитать QR-код на изображении"), true);
                        document.getElementById('qr-result').value = "";
                    }
                } else {
                    showToast(_t("Библиотека декодирования QR еще не загружена. Проверьте интернет соединение."), true);
                }
            }
            img.src = e.target.result;
        }
        reader.readAsDataURL(input.files[0]);
    }
}

function downloadProfile() {
    let qr = document.getElementById('qr-result').value;
    let smdp = document.getElementById('smdp-server').value;
    let actCode = document.getElementById('activation-code').value;
    let confCode = document.getElementById('confirmation-code').value;
    
    if(!qr && !(smdp && actCode)) {
        showToast(_t("Пожалуйста, загрузите QR-код или заполните SM-DP+ и код активации"), true);
        return;
    }
    
    let btn = document.getElementById('btn-download');
    let oldTxt = btn.innerText;
    btn.innerHTML = '<div class="spinner"></div> ' + _t('Загрузка профиля (может занять до 2-х минут)...');
    btn.disabled = true;
    
    req("download", {qr_code: qr, smdp_server: smdp, activation_code: actCode, confirmation_code: confCode}, function(res) {
        btn.innerText = oldTxt;
        btn.disabled = false;
        
        if(res.success || (res.payload && res.payload.code === 0)) {
            showToast(_t("Профиль успешно загружен!"));
            // Очистка формы
            document.getElementById('qr-result').value = "";
            document.getElementById('qr-file').value = "";
            document.getElementById('smdp-server').value = "";
            document.getElementById('activation-code').value = "";
            loadProfiles();
        } else {
            showToast(_t("Ошибка загрузки:") + " " + (res.error || (res.payload ? res.payload.message : _t("Неизвестная ошибка"))), true);
        }
    });
}

function loadAPN() {
    document.getElementById('apn-status').innerHTML = '<div class="spinner"></div> ' + _t('Загрузка APN...');
    req("apn", null, function(res) {
        if(res.success) {
            document.getElementById('cell-apn').value = res.apn || '';
            document.getElementById('apn-status').innerHTML = _t('Текущий APN интерфейса') + ` <strong>${res.interface}</strong>: <span style="color:#60a5fa; font-weight:bold;">${res.apn || _t('(не задан)')}</span>`;
        } else {
            document.getElementById('apn-status').innerHTML = `<span style="color:#ef4444;">${_t('Не удалось загрузить APN:')} ${res.error}</span>`;
        }
    });
}

function saveAPN() {
    let apnVal = document.getElementById('cell-apn').value;
    req("apn", {apn: apnVal}, function(res) {
        if(res.success) {
            showToast(_t("APN успешно сохранен!"));
            loadAPN();
        } else {
            showToast(_t("Ошибка сохранения APN:") + " " + res.error, true);
        }
    });
}

// Language Translation Logic
const dict = {
    "Управление eSIM (LPAC)": "eSIM Management (LPAC)",
    "Информация об eSIM": "eSIM Info",
    "Загрузка информации о чипе...": "Loading chip info...",
    "Установленные профили": "Installed Profiles",
    "Обновить список": "Refresh List",
    "Загрузка профилей...": "Loading profiles...",
    "Настройка APN сотовой сети": "Cell APN Settings",
    "Сохранить APN": "Save APN",
    "Загрузка APN...": "Loading APN...",
    "Добавить новый профиль": "Add New Profile",
    "Вариант 1: Загрузить QR-код (Картинка)": "Option 1: Upload QR code (Image)",
    "Изображение обрабатывается локально в вашем браузере.": "Image is processed locally in your browser.",
    "Вариант 2: Ручной ввод": "Option 2: Manual Input",
    "Загрузить профиль на eSIM": "Download Profile to eSIM",
    "Свободная память:": "Free memory:",
    "Провайдер:": "Provider:",
    "Состояние:": "State:",
    "Активен": "Active",
    "Отключен": "Disabled",
    "Включить": "Enable",
    "Отключить": "Disable",
    "Переименовать": "Rename",
    "Удалить": "Delete",
    "Неизвестно": "Unknown",
    "Нет установленных профилей.": "No installed profiles.",
    "Ошибка:": "Error:",
    "Загрузка...": "Loading...",
    "Пожалуйста, ждите...": "Please wait...",
    "Профиль успешно удален": "Profile successfully deleted",
    "Имя профиля изменено": "Profile name changed",
    "QR-код успешно распознан!": "QR code successfully recognized!",
    "Не удалось найти или прочитать QR-код на изображении": "Could not find or read QR code on image",
    "Библиотека декодирования QR еще не загружена. Проверьте интернет соединение.": "QR decoding library not loaded yet. Check internet connection.",
    "Пожалуйста, загрузите QR-код или заполните SM-DP+ и код активации": "Please upload QR code or fill in SM-DP+ and activation code",
    "Загрузка профиля (может занять до 2-х минут)...": "Downloading profile (may take up to 2 minutes)...",
    "Профиль успешно загружен!": "Profile successfully downloaded!",
    "Текущий APN интерфейса": "Current interface APN",
    "(не задан)": "(not set)",
    "Не удалось загрузить APN:": "Failed to load APN:",
    "APN успешно сохранен!": "APN successfully saved!",
    "Ошибка сохранения APN:": "Failed to save APN:",
    "Вы уверены, что хотите включить этот профиль? Модем может перезагрузиться.": "Are you sure you want to enable this profile? The modem might reboot.",
    "Вы уверены, что хотите отключить этот профиль? Модем может перезагрузиться.": "Are you sure you want to disable this profile? The modem might reboot.",
    "ВНИМАНИЕ! Удаление профиля необратимо. Вы уверены?": "WARNING! Deleting a profile is irreversible. Are you sure?",
    "Введите новое имя профиля:": "Enter new profile name:",
    "Отключите профиль перед удалением": "Disable profile before deletion",
    "Неизвестная ошибка": "Unknown error",
    "Ошибка удаления:": "Error deleting:",
    "Ошибка переименования:": "Error renaming:",
    "Ошибка загрузки:": "Error downloading:",
    "Модемный интерфейс не обнаружен": "Modem interface not detected",
    "Пожалуйста, подключите модем, проверьте питание и убедитесь, что служба ModemManager активна.": "Please connect a modem, check power, and verify that ModemManager is running.",
    "Перезапустить ModemManager": "Restart ModemManager",
    "Перезапустить интерфейс MODEM": "Restart MODEM interface",
    "Применение настроек...": "Applying settings...",
    "Пожалуйста, подождите, выполняется операция перезапуска...": "Please wait, restarting operation is running...",
    "Пожалуйста, подождите, выполняется перезапуск (около 6 сек)...": "Please wait, restarting (about 6 sec)...",
    
    // Missing eSIM strings
    "Например: plus, globaldata, internet.proximus.be": "e.g. plus, globaldata, internet.proximus.be",
    "SM-DP+ Server (например: lpa.example.com)": "SM-DP+ Server (e.g. lpa.example.com)",
    "Confirmation Code (если требуется)": "Confirmation Code (if required)"
};

function _t(str) {
    if (!str) return str;
    const lang = localStorage.getItem('modem_lang') || 'ru';
    if (lang === 'ru') return str;
    return dict[str] || str;
}

function changeLanguage(lang) {
    localStorage.setItem('modem_lang', lang);
    document.cookie = "modem_lang=" + lang + "; path=/; max-age=31536000";
    const selects = document.querySelectorAll('#lang_select');
    selects.forEach(s => s.value = lang);
    translatePage(lang);
}

function translatePage(lang) {
    const elements = document.querySelectorAll('h3, h4, h5, p, label, button, span, strong, option, th, td, a, div.sim-row, div.ant-label, small, div, input, select');
    const sortedKeys = Object.keys(dict).sort((a, b) => b.length - a.length);
    elements.forEach(el => {
        // Translate text nodes
        let hasTextChild = false;
        for (let node of el.childNodes) {
            if (node.nodeType === Node.TEXT_NODE && node.nodeValue.trim().length > 0) {
                hasTextChild = true;
                break;
            }
        }
        if (hasTextChild) {
            if (!el.hasAttribute('data-ru')) {
                el.setAttribute('data-ru', el.innerHTML);
            }
            const origRu = el.getAttribute('data-ru');
            if (lang === 'en') {
                let translated = origRu;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.innerHTML = translated;
            } else {
                el.innerHTML = origRu;
            }
        }

        // Translate placeholders
        if (el.placeholder) {
            if (!el.hasAttribute('data-placeholder-ru')) {
                el.setAttribute('data-placeholder-ru', el.placeholder);
            }
            const origPl = el.getAttribute('data-placeholder-ru');
            if (lang === 'en') {
                let translated = origPl;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.placeholder = translated;
            } else {
                el.placeholder = origPl;
            }
        }

        // Translate titles
        if (el.title) {
            if (!el.hasAttribute('data-title-ru')) {
                el.setAttribute('data-title-ru', el.title);
            }
            const origTitle = el.getAttribute('data-title-ru');
            if (lang === 'en') {
                let translated = origTitle;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.title = translated;
            } else {
                el.title = origTitle;
            }
        }
    });
}

// Init
window.onload = function() {
    loadStatus();
    loadProfiles();
    loadAPN();
    const currentLang = localStorage.getItem('modem_lang') || 'ru';
    document.cookie = "modem_lang=" + currentLang + "; path=/; max-age=31536000";
    const select = document.getElementById('lang_select');
    if (select) select.value = currentLang;
    setTimeout(() => translatePage(currentLang), 100);
};
</script>

<% end %>
<%+footer%>

EOF

echo "Deploying /usr/lib/lua/luci/view/modem/ussd.htm..."
cat << \EOF > /usr/lib/lua/luci/view/modem/ussd.htm
<%+header%>
<%
    local http = require "luci.http"

    local act = http.formvalue("action")
    if act == "restart_mm" then
        os.execute("/etc/init.d/modemmanager restart")
        os.execute("sleep 6")
        http.redirect(http.getenv("REQUEST_URI"):gsub("%?.*$", ""))
        return
    elseif act == "restart_iface" then
        os.execute("ifdown MODEM && sleep 3 && ifup MODEM")
        os.execute("sleep 6")
        http.redirect(http.getenv("REQUEST_URI"):gsub("%?.*$", ""))
        return
    end

    local function exec(cmd)
        local h = io.popen(cmd .. " 2>&1")
        if h then
            local res = h:read("*a")
            h:close()
            return res or ""
        end
        return ""
    end

    local function exec_with_recovery(cmd)
        local out = exec(cmd)
        local err_lower = out:lower()
        if err_lower:match("error") or err_lower:match("timeout") or err_lower:match("not supported") or err_lower:match("operation not supported") then
            os.execute("ifdown MODEM && /etc/init.d/modemmanager restart && sleep 5 && ifup MODEM && sleep 5")
            out = exec(cmd)
        end
        return out
    end

    
    local m_list = exec("mmcli -L") or ""
    local has_modem = (m_list:match("ModemManager1/Modem/(%d+)") ~= nil)
    local mmcli_idx = "any"
    local id = m_list:match("ModemManager1/Modem/(%d+)")
    if id then mmcli_idx = id end

    local mmcli_out = ""
    local modes = ""
    local bands = ""
    local has_2g3g = false
    local has_bands = false
    local ussd_status = "idle"
    local ussd_reply = ""
    local action = http.formvalue("ussd_action")
    local cmd_val = http.formvalue("ussd_cmd")
    local response_msg = ""
    local error_msg = ""

    if has_modem then
        mmcli_out = exec("mmcli -m " .. mmcli_idx)
        modes = mmcli_out:match("Modes.-allowed:%s*([^;\n]+)") or ""
        bands = mmcli_out:match("Bands.-current:%s*([^;\n]+)") or ""
        has_2g3g = modes:match("2g") or modes:match("3g") or modes:match("any")
        has_bands = bands:match("gsm") or bands:match("utran") or bands:match("any")

        local status_out = exec("mmcli -m " .. mmcli_idx .. " --3gpp-ussd-status")
        ussd_status = status_out:match("status:%s*([^\n]+)") or "unknown"
        ussd_status = ussd_status:gsub("^['\"]", ""):gsub("['\"]$", ""):gsub("^%s*", ""):gsub("%s*$", "")
        ussd_reply = status_out:match("network request:%s*([^\n]+)") or status_out:match("network response:%s*([^\n]+)") or ""
        ussd_reply = ussd_reply:gsub("^['\"]", ""):gsub("['\"]$", ""):gsub("^%s*", ""):gsub("%s*$", "")

        if action == "initiate" and cmd_val and cmd_val ~= "" then
            local safe_cmd = cmd_val:gsub("'", ""):gsub('"', "")
            local res = exec_with_recovery(string.format("mmcli -m %s --timeout=30 --3gpp-ussd-initiate='%s'", mmcli_idx, safe_cmd))
            if res:match("successfully initiated") or res:match("network response:") then
                response_msg = res:match("network response:%s*([^\n]+)") or "USSD отправлен."
                response_msg = response_msg:gsub("^['\"]", ""):gsub("['\"]$", ""):gsub("^%s*", ""):gsub("%s*$", "")
                ussd_status = "active"
            else
                error_msg = res
            end
            -- re-read status
            status_out = exec("mmcli -m " .. mmcli_idx .. " --3gpp-ussd-status")
            local new_status = status_out:match("status:%s*([^\n]+)")
            if new_status then
                ussd_status = new_status:gsub("^['\"]", ""):gsub("['\"]$", ""):gsub("^%s*", ""):gsub("%s*$", "")
            end
            local new_reply = status_out:match("network request:%s*([^\n]+)") or status_out:match("network response:%s*([^\n]+)")
            if new_reply then
                ussd_reply = new_reply:gsub("^['\"]", ""):gsub("['\"]$", ""):gsub("^%s*", ""):gsub("%s*$", "")
            else
                ussd_reply = response_msg
            end
        elseif action == "respond" and cmd_val and cmd_val ~= "" then
            local safe_cmd = cmd_val:gsub("'", ""):gsub('"', "")
            local res = exec_with_recovery(string.format("mmcli -m %s --timeout=30 --3gpp-ussd-respond='%s'", mmcli_idx, safe_cmd))
            if res:match("successfully responded") or res:match("network response:") then
                response_msg = res:match("network response:%s*([^\n]+)") or "Ответ отправлен."
                response_msg = response_msg:gsub("^['\"]", ""):gsub("['\"]$", ""):gsub("^%s*", ""):gsub("%s*$", "")
            else
                error_msg = res
            end
            status_out = exec("mmcli -m " .. mmcli_idx .. " --3gpp-ussd-status")
            local new_status = status_out:match("status:%s*([^\n]+)")
            if new_status then
                ussd_status = new_status:gsub("^['\"]", ""):gsub("['\"]$", ""):gsub("^%s*", ""):gsub("%s*$", "")
            end
            local new_reply = status_out:match("network request:%s*([^\n]+)") or status_out:match("network response:%s*([^\n]+)")
            if new_reply then
                ussd_reply = new_reply:gsub("^['\"]", ""):gsub("['\"]$", ""):gsub("^%s*", ""):gsub("%s*$", "")
            else
                ussd_reply = response_msg
            end
        elseif action == "cancel" then
            exec("mmcli -m " .. mmcli_idx .. " --3gpp-ussd-cancel")
            ussd_status = "idle"
            ussd_reply = ""
        end
    end
%>

<div class="cbi-section">
    <div class="cbi-section-node" style="padding: 10px 0; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px;">
        <div>
            <h3 style="margin-bottom: 5px; color: #ffffff;">USSD Команды</h3>
        </div>
        <div style="display: flex; align-items: center; gap: 6px; background: rgba(30, 41, 59, 0.7); backdrop-filter: blur(8px); padding: 4px 8px; border-radius: 6px; border: 1px solid rgba(255, 255, 255, 0.08); height: fit-content; margin-right: 15px;">
            <span style="font-size: 12px; color: #94a3b8;">🌐 Language:</span>
            <select id="lang_select" onchange="changeLanguage(this.value)" style="background: transparent; color: #f8fafc; border: none; font-size: 12px; cursor: pointer; outline: none; padding: 0 4px; font-weight: 500;">
                <option value="ru" style="background: #1e293b; color: #f8fafc;">RU</option>
                <option value="en" style="background: #1e293b; color: #f8fafc;">EN</option>
            </select>
        </div>
    </div>
</div>

<% if not has_modem then %>
    <div style="background: #1e293b; border-left: 4px solid #ef4444; border-radius: 8px; padding: 24px; text-align: center; box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1); font-family: sans-serif;">
        <h3 style="color: #ef4444; margin-top: 0; font-size: 20px;">⚠️ Модемный интерфейс не обнаружен</h3>
        <p style="color: #94a3b8; margin: 0; font-size: 14px; margin-bottom: 20px;">Пожалуйста, подключите модем, проверьте питание и убедитесь, что служба ModemManager активна.</p>
        
        <div style="display: flex; justify-content: center; gap: 15px; flex-wrap: wrap;">
            <a href="?action=restart_mm" style="display: inline-block; padding: 8px 16px; background-color: #3b82f6; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезапуск службы ModemManager...')">Перезапустить ModemManager</a>
            <a href="?action=restart_iface" style="display: inline-block; padding: 8px 16px; background-color: #f59e0b; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 13px; font-family: sans-serif;" onclick="showRecoveryOverlay('Перезапуск интерфейса MODEM...')">Перезапустить интерфейс MODEM</a>
        </div>
    </div>

    <div id="apply_overlay" style="display:none; position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(15,23,42,0.95); z-index:99999; justify-content:center; align-items:center; flex-direction:column; color:#fff; font-family:sans-serif; backdrop-filter:blur(5px);">
        <div class="spinning" style="width:60px; height:60px; border:4px solid #334155; border-top-color:#3b82f6; border-radius:50%; animation:spin 1s linear infinite; margin-bottom:20px;"></div>
        <div id="overlay_title" style="font-size:20px; font-weight:bold; color:#f8fafc;">Применение настроек...</div>
        <div id="overlay_subtitle" style="font-size:14px; color:#94a3b8; margin-top:8px; text-align:center; max-width:400px; padding:0 20px; line-height:1.5;">Пожалуйста, подождите, выполняется операция перезапуска...</div>
    </div>
    <style>
    @keyframes spin { to { transform: rotate(360deg); } }
    </style>
    <script>
    function showRecoveryOverlay(title) {
        document.getElementById('overlay_title').innerText = title;
        document.getElementById('overlay_subtitle').innerText = "Пожалуйста, подождите, выполняется перезапуск (около 6 сек)...";
        document.getElementById('apply_overlay').style.display = 'flex';
    }
    </script>
<% else %>

<style>
.ussd-dash { background-color:#1e293b; color:#d1d5db; padding:20px; border-radius:6px; margin-bottom:15px; font-family:sans-serif;}
.ussd-input { width:100%; max-width:300px; background:#0f172a; color:#fff; border:1px solid #3b82f6; padding:8px 12px; border-radius:4px; outline:none; }
.btn-action { background:#3b82f6; color:#fff; border:none; padding:8px 15px; border-radius:4px; cursor:pointer; font-weight:bold; }
.btn-danger { background:#ef4444; }
.reply-box { background:#0f172a; border:1px solid #4ade80; padding:15px; border-radius:6px; margin-top:15px; color:#4ade80; white-space:pre-wrap; }
.err-box { background:#7f1d1d; border-left:4px solid #ef4444; padding:10px 15px; margin-bottom:15px; color:#fca5a5; }
.warn-box { background:#78350f; border-left:4px solid #f59e0b; padding:10px 15px; margin-bottom:15px; color:#fcd34d; }
#timer-box { font-size: 20px; font-weight: bold; color: #ef4444; margin-top:10px; display:none; }
</style>

<div class="ussd-dash">
    <% if not has_2g3g or not has_bands then %>
    <div class="warn-box">
        <strong>Внимание:</strong> Похоже, модем не находится в режиме 2G/3G или нужные диапазоны отключены. 
        USSD работает преимущественно в сетях 2G/3G. Текущие режимы: <%=modes%>.
    </div>
    <% end %>

    <% if error_msg ~= "" then %>
        <div class="err-box">Ошибка выполнения: <%=error_msg%></div>
    <% end %>

    <div style="margin-bottom: 20px;">
        <strong>Статус сессии:</strong> 
        <span style="color:<%= ussd_status == 'idle' and '#94a3b8' or '#4ade80' %>;"><%=ussd_status:upper()%></span>
    </div>

    <% if ussd_status == "idle" or ussd_status == "unknown" then %>
        <form method="post" action="<%=luci.dispatcher.build_url('admin/modem/ussd')%>">
            <label style="display:block; margin-bottom:5px;">Отправить USSD команду:</label>
            <div style="display:flex; gap:10px;">
                <input type="text" name="ussd_cmd" class="ussd-input" placeholder="*100#" required>
                <button type="submit" name="ussd_action" value="initiate" class="btn-action">Выполнить</button>
            </div>
        </form>
        
        <% if ussd_reply ~= "" then %>
            <div class="reply-box"><strong>Последний ответ:</strong><br><br><%=ussd_reply%></div>
        <% end %>

    <% else %>
        <!-- Сессия активна (user-response) -->
        <div class="reply-box" style="border-color:#3b82f6; color:#60a5fa;">
            <strong>Пришел ответ (требуется ваше действие):</strong><br><br><%=ussd_reply%>
        </div>
        
        <div id="timer-box">Сессия закроется через: <span id="time-left">60</span> сек</div>
        
        <form id="ussd-form" method="post" action="<%=luci.dispatcher.build_url('admin/modem/ussd')%>" style="margin-top:20px;">
            <label style="display:block; margin-bottom:5px;">Ваш ответ:</label>
            <div style="display:flex; gap:10px;">
                <input type="text" name="ussd_cmd" class="ussd-input" placeholder="Введите номер пункта..." required>
                <button type="submit" name="ussd_action" value="respond" class="btn-action">Ответить</button>
                <button type="submit" name="ussd_action" value="cancel" class="btn-action btn-danger" formnovalidate>Прервать (Cancel)</button>
            </div>
        </form>
        
        <script>
            document.getElementById('timer-box').style.display = 'block';
            let timeLeft = 60;
            let timerSpan = document.getElementById('time-left');
            let form = document.getElementById('ussd-form');
            
            let interval = setInterval(function() {
                timeLeft--;
                timerSpan.innerText = timeLeft;
                if(timeLeft <= 0) {
                    clearInterval(interval);
                    // авто-отмена
                    let input = document.createElement('input');
                    input.type = 'hidden';
                    input.name = 'ussd_action';
                    input.value = 'cancel';
                    form.appendChild(input);
                    form.submit();
                }
            }, 1000);
        </script>
    <% end %>
</div>

<script>
// Language Translation Logic
const dict = {
    "USSD Команды": "USSD Commands",
    "⚠️ Модемный интерфейс не обнаружен": "⚠️ Modem interface not detected",
    "Пожалуйста, подключите модем, проверьте питание и убедитесь, что служба ModemManager активна.": "Please connect a modem, check power, and verify that ModemManager is running.",
    "Перезапустить ModemManager": "Restart ModemManager",
    "Перезапустить интерфейс MODEM": "Restart MODEM interface",
    "Применение настроек...": "Applying settings...",
    "Пожалуйста, подождите, выполняется операция перезапуска...": "Please wait, restarting...",
    "Перезапуск службы ModemManager...": "Restarting ModemManager service...",
    "Перезапуск интерфейса MODEM...": "Restarting MODEM interface...",
    "Отправить USSD команду:": "Send USSD command:",
    "Выполнить": "Execute",
    "Последний ответ:": "Last response:",
    "Пришел ответ (требуется ваше действие):": "Response received (your action is required):",
    "Сессия закроется через:": "Session will close in:",
    " сек": " sec",
    "Ваш ответ:": "Your response:",
    "Ответить": "Respond",
    "Прервать (Cancel)": "Cancel",
    "Сессия закроется через: ": "Session will close in: "
};

function _t(str) {
    if (!str) return str;
    const lang = localStorage.getItem('modem_lang') || 'ru';
    if (lang === 'ru') return str;
    return dict[str] || str;
}

function changeLanguage(lang) {
    localStorage.setItem('modem_lang', lang);
    document.cookie = "modem_lang=" + lang + "; path=/; max-age=31536000";
    const selects = document.querySelectorAll('#lang_select');
    selects.forEach(s => s.value = lang);
    translatePage(lang);
}

function translatePage(lang) {
    const elements = document.querySelectorAll('h3, h4, h5, p, label, button, span, strong, option, th, td, a, div, input, select');
    const sortedKeys = Object.keys(dict).sort((a, b) => b.length - a.length);
    elements.forEach(el => {
        // Translate text nodes
        let hasTextChild = false;
        for (let node of el.childNodes) {
            if (node.nodeType === Node.TEXT_NODE && node.nodeValue.trim().length > 0) {
                hasTextChild = true;
                break;
            }
        }
        if (hasTextChild) {
            if (!el.hasAttribute('data-ru')) {
                el.setAttribute('data-ru', el.innerHTML);
            }
            const origRu = el.getAttribute('data-ru');
            if (lang === 'en') {
                let translated = origRu;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.innerHTML = translated;
            } else {
                el.innerHTML = origRu;
            }
        }

        // Translate placeholders
        if (el.placeholder) {
            if (!el.hasAttribute('data-placeholder-ru')) {
                el.setAttribute('data-placeholder-ru', el.placeholder);
            }
            const origPl = el.getAttribute('data-placeholder-ru');
            if (lang === 'en') {
                let translated = origPl;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.placeholder = translated;
            } else {
                el.placeholder = origPl;
            }
        }

        // Translate titles
        if (el.title) {
            if (!el.hasAttribute('data-title-ru')) {
                el.setAttribute('data-title-ru', el.title);
            }
            const origTitle = el.getAttribute('data-title-ru');
            if (lang === 'en') {
                let translated = origTitle;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.title = translated;
            } else {
                el.title = origTitle;
            }
        }
    });
}

// Initial language setup
const currentLang = localStorage.getItem('modem_lang') || 'ru';
document.cookie = "modem_lang=" + currentLang + "; path=/; max-age=31536000";
const select = document.getElementById('lang_select');
if (select) select.value = currentLang;
setTimeout(() => translatePage(currentLang), 100);
</script>

<% end %>
<%+footer%>

EOF

echo "Deploying /usr/bin/sms_sync.lua..."
cat << \EOF > /usr/bin/sms_sync.lua
#!/usr/bin/lua

local jsonc = require "luci.jsonc"

local ARCHIVE_FILE = "/etc/sms_archive.json"
local LOCK_DIR = "/var/run/sms_sync.lock"

-- Простая блокировка (atomic), чтобы два процесса не запустились одновременно
-- /var/run/ очищается при перезагрузке, поэтому "вечной" блокировки при ребуте не будет
local lock_status = os.execute("mkdir " .. LOCK_DIR .. " 2>/dev/null")
if lock_status ~= 0 and lock_status ~= true then
    -- Скрипт уже запущен другим процессом (кроном или веб-страницей)
    return
end

local function exec(cmd)
    local safe_cmd = cmd
    if not cmd:match("^timeout%s") then
        safe_cmd = "timeout 5 " .. cmd
    end
    local h = io.popen(safe_cmd .. " 2>/dev/null")
    if h then
        local res = h:read("*a")
        h:close()
        return res or ""
    end
    return ""
end

local function parse_iso_time(ts_str)
    if not ts_str or ts_str == "-" then return nil end
    local y, m, d, h, min, sec = ts_str:match("(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if y and m and d and h and min and sec then
        return os.time({year=tonumber(y), month=tonumber(m), day=tonumber(d), hour=tonumber(h), min=tonumber(min), sec=tonumber(sec)})
    end
    return nil
end

-- 1. Чтение текущего архива
local archive = {}
local f = io.open(ARCHIVE_FILE, "r")
if f then
    local content = f:read("*a")
    f:close()
    if content and content ~= "" then
        archive = jsonc.parse(content) or {}
    end
end

-- Функция генерации уникального ID для сообщения
local function generate_id()
    return tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
end

math.randomseed(os.time())

-- 2. Получение списка SMS
local mmcli_idx = "any"
local list_out = exec("mmcli -m " .. mmcli_idx .. " --messaging-list-sms")
local new_sms_count = 0

for path, idx, state in list_out:gmatch("(/org/freedesktop/ModemManager1/SMS/(%d+)) %(([^%)]+)%)") do
    if state ~= "sending" then
        local sms_details = exec("mmcli -s " .. idx)
        
        local num = sms_details:match("number:%s*([^\n]+)") or "Неизвестно"
        num = num:gsub("^%s*", ""):gsub("%s*$", ""):gsub("^['\"]", ""):gsub("['\"]$", "")
        
        local ts = sms_details:match("timestamp:%s*([^\n]+)") or "-"
        ts = ts:gsub("^%s*", ""):gsub("%s*$", ""):gsub("^['\"]", ""):gsub("['\"]$", "")

        local pdu = sms_details:match("pdu type:%s*([^\n]+)") or ""
        
        local mapped_state = "received"
        if state == "sent" or pdu == "submit" then
            mapped_state = "sent"
        end
        
        local txt = sms_details:match("text:%s*(.-)\n%s*[%a]+%s*|") or sms_details:match("text:%s*(.-)\n%s*%-") or sms_details:match("text:%s*(.*)") or ""
        txt = txt:gsub("^%s*", ""):gsub("%s*$", "")
        
        -- Если текста нет, пробуем прочитать как бинарное сообщение
        if txt == "" then
            local data = sms_details:match("data:%s*([^\n]+)")
            if data then txt = "[Бинарные данные: " .. data .. "]" end
        end

        -- Защита от мусора (Cell Broadcasts, пустые глючные SMS и т.д.)
        -- Мы не добавляем в архив, если нет ни текста, ни нормального номера
        local is_junk = false
        if pdu == "cbs" or state == "unknown" then
            if txt == "" or num == "Неизвестно" then
                is_junk = true
            end
        end
        
        -- Если это 'receiving' и текста всё ещё нет - скорее всего оно недокачано, 
        -- просто проигнорируем его пока что, не удаляя из модема, ЕСЛИ оно не старое
        if state == "receiving" and txt == "" then
            local ts_epoch = parse_iso_time(ts)
            if ts_epoch and (os.time() - ts_epoch > 21600) then -- старше 6 часов
                -- Удаляем застрявший фрагмент, чтобы освободить память модема
                exec(string.format("mmcli -m %s --messaging-delete-sms=%s", mmcli_idx, idx))
            end
        else
            if not is_junk and txt ~= "" then
                local is_duplicate = false
                for _, existing in ipairs(archive) do
                    if existing.number == num and existing.timestamp == ts and existing.text == txt then
                        is_duplicate = true
                        break
                    end
                end
                
                if not is_duplicate then
                    table.insert(archive, {
                        id = generate_id(),
                        state = mapped_state,
                        number = num,
                        text = txt,
                        timestamp = ts,
                        saved_at = os.time()
                    })
                    new_sms_count = new_sms_count + 1
                end
            end
            
            -- Удаляем сообщение из модема (даже если это мусор, чтобы не забивало память)
            exec(string.format("mmcli -m %s --messaging-delete-sms=%s", mmcli_idx, idx))
        end
    end
end

-- 4. Сохранение архива, если есть новые сообщения
if new_sms_count > 0 then
    local out_f = io.open(ARCHIVE_FILE, "w")
    if out_f then
        -- Сериализация JSON (pretty=false, т.к. jsonc в luci может не принимать 2 аргумента, 
        -- но мы вызовем обычный stringify)
        out_f:write(jsonc.stringify(archive))
        out_f:close()
    end
end

-- Снимаем блокировку
os.execute("rmdir " .. LOCK_DIR)


EOF

echo "Deploying /usr/bin/modem_speed_daemon.lua..."
cat << \EOF > /usr/bin/modem_speed_daemon.lua
local json = require "luci.jsonc"
local sys = require "luci.sys"

local history_max = 300 -- 5 minutes
local output_file = "/tmp/modem_speed.json"

local function find_active_interface()
    local candidates = {"wwan0", "rmnet_data0", "usb0", "wwan0_1", "wwan0_2"}
    for _, name in ipairs(candidates) do
        local f = io.open("/sys/class/net/" .. name .. "/operstate", "r")
        if f then
            f:close()
            return name
        end
    end
    local p = io.popen("ls -d /sys/class/net/wwan* /sys/class/net/rmnet* 2>/dev/null")
    if p then
        local line = p:read("*l")
        p:close()
        if line then
            return line:match("([^/]+)$")
        end
    end
    return "wwan0"
end

local interface = find_active_interface()
local rx_file = "/sys/class/net/" .. interface .. "/statistics/rx_bytes"
local tx_file = "/sys/class/net/" .. interface .. "/statistics/tx_bytes"

local function read_int_file(path)
    local f = io.open(path, "r")
    if not f then return 0 end
    local val = tonumber(f:read("*a")) or 0
    f:close()
    return val
end

-- Load existing history to prevent gaps on daemon restarts
local history = {}
local load_history = {}
local load_history_max = 300
local f = io.open(output_file, "r")
if f then
    local content = f:read("*a")
    f:close()
    local success, parsed = pcall(json.parse, content)
    if success and type(parsed) == "table" then
        if parsed.history then history = parsed.history end
        if parsed.load_history then load_history = parsed.load_history end
    end
end

local prev_rx = read_int_file(rx_file)
local prev_tx = read_int_file(tx_file)
local prev_time = os.time()

while true do
    sys.exec("sleep 1")
    
    -- Dynamically re-evaluate interface if it disappears or changes
    local active_if = find_active_interface()
    if active_if ~= interface then
        interface = active_if
        rx_file = "/sys/class/net/" .. interface .. "/statistics/rx_bytes"
        tx_file = "/sys/class/net/" .. interface .. "/statistics/tx_bytes"
        prev_rx = read_int_file(rx_file)
        prev_tx = read_int_file(tx_file)
    end

    local curr_time = os.time()
    local curr_rx = read_int_file(rx_file)
    local curr_tx = read_int_file(tx_file)

    local delta_time = curr_time - prev_time
    if delta_time <= 0 then delta_time = 1 end

    local rx_speed = ((curr_rx - prev_rx) * 8) / (1024 * 1024 * delta_time)
    local tx_speed = ((curr_tx - prev_tx) * 8) / (1024 * 1024 * delta_time)

    -- Format to 3 decimal places
    rx_speed = math.floor(rx_speed * 1000 + 0.5) / 1000
    tx_speed = math.floor(tx_speed * 1000 + 0.5) / 1000

    if rx_speed < 0 or curr_rx < prev_rx then rx_speed = 0 end
    if tx_speed < 0 or curr_tx < prev_tx then tx_speed = 0 end

    table.insert(history, {rx = rx_speed, tx = tx_speed, time = curr_time})
    if #history > history_max then
        table.remove(history, 1)
    end

    -- Read loadavg
    local loadavg_val = 0
    local f_lavg = io.open("/proc/loadavg", "r")
    if f_lavg then
        local l_line = f_lavg:read("*line")
        f_lavg:close()
        if l_line then
            loadavg_val = tonumber(l_line:match("^(%d+%.%d+)")) or 0
        end
    end

    table.insert(load_history, {val = loadavg_val, time = curr_time})
    if #load_history > load_history_max then
        table.remove(load_history, 1)
    end

    local out_data = {
        interface = interface,
        rx_speed = rx_speed,
        tx_speed = tx_speed,
        history = history,
        loadavg = loadavg_val,
        load_history = load_history
    }

    local out_f = io.open(output_file, "w")
    if out_f then
        out_f:write(json.stringify(out_data))
        out_f:close()
    end

    prev_rx = curr_rx
    prev_tx = curr_tx
    prev_time = curr_time
end

EOF

echo "Deploying /etc/init.d/modem_speed..."
cat << \EOF > /etc/init.d/modem_speed
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
        procd_open_instance
        procd_set_param command /usr/bin/lua /usr/bin/modem_speed_daemon.lua
        procd_set_param respawn
        procd_close_instance
}

EOF

echo "Deploying /usr/lib/lua/luci/view/modem/pingcheck.htm..."
cat << \EOF > /usr/lib/lua/luci/view/modem/pingcheck.htm
<%+header%>
<%
    -- Check if initial logs exist
    local sys = require "luci.sys"
    local has_log = (os.execute("test -f /tmp/pingcheck.log") == 0)
%>

<div class="cbi-section">
    <div class="cbi-section-node" style="padding: 10px 0; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px;">
        <div>
            <h3 style="margin-bottom: 5px; color: #ffffff;">Мониторинг доступности интернета (Internet Availability)</h3>
            <p style="color: #94a3b8; margin: 0; font-size: 13px;">Фоновый контроль соединения на интерфейсе wwan0 с автоматическим сбором логов при сбоях.</p>
        </div>
        <div style="display: flex; align-items: center; gap: 6px; background: rgba(30, 41, 59, 0.7); backdrop-filter: blur(8px); padding: 4px 8px; border-radius: 6px; border: 1px solid rgba(255, 255, 255, 0.08); height: fit-content; margin-right: 15px;">
            <span style="font-size: 12px; color: #94a3b8;">🌐 Language:</span>
            <select id="lang_select" onchange="changeLanguage(this.value)" style="background: transparent; color: #f8fafc; border: none; font-size: 12px; cursor: pointer; outline: none; padding: 0 4px; font-weight: 500;">
                <option value="ru" style="background: #1e293b; color: #f8fafc;">RU</option>
                <option value="en" style="background: #1e293b; color: #f8fafc;">EN</option>
            </select>
        </div>
    </div>
</div>

<style>
/* Glassmorphism theme styles matching modeminfo.htm */
.pc-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
    gap: 20px;
    margin-bottom: 25px;
}
.pc-card {
    background: #1e293b;
    border: 1px solid #334155;
    border-radius: 8px;
    padding: 24px;
    box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1);
    position: relative;
    overflow: hidden;
}
.pc-card::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 4px;
}
.card-status::before { background: #3b82f6; }
.card-stats::before { background: #8b5cf6; }

.pc-label {
    font-size: 12px;
    color: #94a3b8;
    text-transform: uppercase;
    font-weight: 600;
    letter-spacing: 0.05em;
    margin-bottom: 8px;
}
.status-badge {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-size: 28px;
    font-weight: 800;
    font-family: 'Outfit', 'Inter', sans-serif;
    line-height: 1;
    margin: 10px 0;
}
.status-duration {
    font-size: 14px;
    color: #cbd5e1;
    margin-top: 4px;
    font-family: monospace;
}

/* Timeline visualization styling */
.timeline-container {
    background: #1e293b;
    border: 1px solid #334155;
    border-radius: 8px;
    padding: 24px;
    margin-bottom: 25px;
}
.timeline-bar-wrapper {
    position: relative;
    margin: 20px 0 10px 0;
}
.timeline-bar {
    height: 32px;
    background-color: #10b981; /* Default online state (green) */
    border-radius: 6px;
    position: relative;
    overflow: hidden;
    box-shadow: inset 0 2px 4px rgba(0,0,0,0.3);
}
.timeline-segment-down {
    position: absolute;
    top: 0;
    height: 100%;
    background-color: #ef4444; /* Offline state (red) */
    cursor: pointer;
    transition: background-color 0.2s;
}
.timeline-segment-down:hover {
    background-color: #f87171;
}
.timeline-labels {
    display: flex;
    justify-content: space-between;
    font-size: 11px;
    color: #94a3b8;
    font-family: monospace;
    margin-top: 6px;
}

/* Tooltip style */
.pc-tooltip {
    position: absolute;
    background: #0f172a;
    color: #ffffff;
    padding: 8px 12px;
    border-radius: 6px;
    border: 1px solid #475569;
    font-size: 12px;
    font-family: monospace;
    z-index: 100;
    pointer-events: none;
    box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.5);
    display: none;
    line-height: 1.4;
}

/* Tables and logs management */
.panel-card {
    background: #1e293b;
    border: 1px solid #334155;
    border-radius: 8px;
    padding: 20px;
    margin-bottom: 25px;
}
.panel-header {
    border-bottom: 1px solid #334155;
    padding-bottom: 10px;
    margin-bottom: 15px;
    display: flex;
    justify-content: space-between;
    align-items: center;
}
.panel-title {
    margin: 0;
    color: #ffffff;
    font-weight: 500;
    font-size: 16px;
    display: flex;
    align-items: center;
    gap: 8px;
}
.pc-table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
    text-align: left;
}
.pc-table th {
    padding: 10px 12px;
    background: #0f172a;
    color: #94a3b8;
    font-weight: 600;
    border-bottom: 2px solid #334155;
}
.pc-table td {
    padding: 10px 12px;
    border-bottom: 1px solid #334155;
    color: #d1d5db;
}
.pc-table tr:hover td {
    background: rgba(51, 65, 85, 0.2);
}

.badge-up {
    background: rgba(16, 185, 129, 0.15);
    color: #34d399;
    padding: 2px 8px;
    border-radius: 4px;
    font-weight: bold;
    font-size: 11px;
}
.badge-down {
    background: rgba(239, 68, 68, 0.15);
    color: #f87171;
    padding: 2px 8px;
    border-radius: 4px;
    font-weight: bold;
    font-size: 11px;
}

/* Pulse animation */
@keyframes pc-pulse {
    0% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.5); }
    70% { transform: scale(1); box-shadow: 0 0 0 10px rgba(16, 185, 129, 0); }
    100% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(16, 185, 129, 0); }
}
@keyframes pc-pulse-red {
    0% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(239, 68, 68, 0.6); }
    70% { transform: scale(1); box-shadow: 0 0 0 10px rgba(239, 68, 68, 0); }
    100% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(239, 68, 68, 0); }
}

.pulse-green {
    display: inline-block;
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: #10b981;
    animation: pc-pulse 2s infinite;
}
.pulse-red {
    display: inline-block;
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: #ef4444;
    animation: pc-pulse-red 1.5s infinite;
}
</style>

<!-- Warning Banner for inactive daemon -->
<div id="daemon_warning_banner" style="display: none; background: rgba(239, 68, 68, 0.15); border: 1px solid #ef4444; border-radius: 8px; padding: 12px 16px; margin-bottom: 20px; align-items: center; gap: 12px;">
    <svg style="width:24px; height:24px; color:#ef4444; flex-shrink:0;" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"></path>
    </svg>
    <div>
        <strong style="color: #ffffff; display: block; font-size: 14px;">Фоновая служба мониторинга не запущена!</strong>
        <span style="color: #94a3b8; font-size: 12px;">Пожалуйста, проверьте статус службы `/etc/init.d/pingcheck`. Статистика и данные о сбоях могут быть неактуальными.</span>
    </div>
</div>

<div class="pc-grid">
    <!-- Status Card -->
    <div class="pc-card card-status">
        <div class="pc-label">Текущее состояние связи</div>
        <div class="status-badge" id="current_status">
            <span class="pulse-green"></span>
            <span style="color: #10b981;">ONLINE</span>
        </div>
        <div class="status-duration" id="current_duration">Непрерывная работа: --</div>
        <div style="font-size:11px; color:#94a3b8; margin-top: 8px;" id="last_check_time_label">Обновлено: --</div>
    </div>
    
    <!-- Stats Card -->
    <div class="pc-card card-stats">
        <div class="pc-label">Статистика за текущую сессию</div>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-top: 5px;">
            <div>
                <span style="display:block; color:#94a3b8; font-size:11px;">СБОЕВ ИНТЕРНЕТА:</span>
                <strong style="font-size:22px; color:#ffffff; font-family:sans-serif;" id="stat_drops_count">0</strong>
            </div>
            <div>
                <span style="display:block; color:#94a3b8; font-size:11px;">ОБЩЕЕ ВРЕМЯ ПРОСТОЯ:</span>
                <strong style="font-size:22px; color:#ef4444; font-family:sans-serif;" id="stat_total_downtime">0s</strong>
            </div>
        </div>
        <div style="font-size:12px; color:#94a3b8; margin-top:12px;" id="stat_uptime_percent">Доступность линии: 100.00%</div>
    </div>
</div>

<!-- Timeline Card -->
<div class="timeline-container">
    <div style="display: flex; justify-content: space-between; align-items: center;">
        <h4 style="margin: 0; border: none; padding: 0; color: #ffffff; font-weight: normal; font-size: 15px;">Таймлайн аптайма (История за 24ч)</h4>
        <span style="font-size: 12px; color: #94a3b8;" id="timeline_span_label">Обнаружено событий: 0</span>
    </div>
    
    <div class="timeline-bar-wrapper">
        <div class="timeline-bar" id="timeline_bar"></div>
        <div class="timeline-labels">
            <span id="timeline_label_start">--:--:--</span>
            <span>Срез времени доступности</span>
            <span id="timeline_label_end">--:--:--</span>
        </div>
    </div>
</div>

<!-- Custom Tooltip element -->
<div class="pc-tooltip" id="pc_tooltip"></div>

<!-- Transition Logs Table -->
<div class="panel-card">
    <div class="panel-header">
        <h4 class="panel-title">
            <svg style="width:16px; height:16px; color:#3b82f6;" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"></path>
            </svg>
            История переходов и инцидентов
        </h4>
        <button type="button" onclick="clearLogs()" style="background: #ef4444; color: #ffffff; border: none; padding: 6px 12px; border-radius: 4px; cursor: pointer; font-weight: bold; font-size: 12px; outline: none; transition: all 0.2s ease;">Очистить лог</button>
    </div>
    
    <div style="max-height: 300px; overflow-y: auto;">
        <table class="pc-table" id="logs_table">
            <thead>
                <tr>
                    <th style="width: 30%;">Время события</th>
                    <th style="width: 25%;">Состояние</th>
                    <th>Детали сбоя</th>
                </tr>
            </thead>
            <tbody>
                <tr>
                    <td colspan="3" style="text-align: center; color: #94a3b8;">Загрузка логов переходов...</td>
                </tr>
            </tbody>
        </table>
    </div>
</div>

<!-- Diagnostics / Bug Reports -->
<div class="panel-card">
    <div class="panel-header">
        <h4 class="panel-title">
            <svg style="width:16px; height:16px; color:#f59e0b;" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"></path>
            </svg>
            Архив багрепортов (сбои > 10 секунд)
        </h4>
        <span style="color:#94a3b8; font-size:12px;">Снимаются автоматически ровно один раз при падении</span>
    </div>
    
    <table class="pc-table" id="bugreports_table">
        <thead>
            <tr>
                <th>Имя файла</th>
                <th>Размер</th>
                <th>Дата сбора</th>
                <th style="width: 200px; text-align: center;">Действия</th>
            </tr>
        </thead>
        <tbody>
            <tr>
                <td colspan="4" style="text-align: center; color: #94a3b8;">Загрузка багрепортов...</td>
            </tr>
        </tbody>
    </table>
</div>

<script>
const g=i=>document.getElementById(i);

let activePollId = null;
let timeSkew = 0;

function getRouterNow() {
    return Date.now() - timeSkew;
}

let currentUptimeState = "UNKNOWN";
let currentUptimeStart = 0;
let eventsHistory = [];

function formatDuration(sec) {
    const lang = localStorage.getItem('modem_lang') || 'ru';
    if (lang === 'en') {
        if (sec < 60) return sec + " sec";
        const min = Math.floor(sec / 60);
        const rSec = sec % 60;
        if (min < 60) return min + " min " + rSec + " sec";
        const hr = Math.floor(min / 60);
        const rMin = min % 60;
        return hr + " h " + rMin + " min " + rSec + " sec";
    } else {
        if (sec < 60) return sec + " сек";
        const min = Math.floor(sec / 60);
        const rSec = sec % 60;
        if (min < 60) return min + " мин " + rSec + " сек";
        const hr = Math.floor(min / 60);
        const rMin = min % 60;
        return hr + " ч " + rMin + " мин " + rSec + " сек";
    }
}

function parseDateStr(tsStr) {
    if (!tsStr) return getRouterNow();
    if (/^\d+$/.test(tsStr)) {
        return parseInt(tsStr) * 1000;
    }
    const parts = tsStr.match(/^(\d+)-(\d+)-(\d+)\s+(\d+):(\d+):(\d+)$/);
    if (!parts) return getRouterNow();
    return Date.UTC(parseInt(parts[1]), parseInt(parts[2])-1, parseInt(parts[3]), parseInt(parts[4]), parseInt(parts[5]), parseInt(parts[6]));
}

function utcToLocalStr(tsStr) {
    if (!tsStr) return "";
    if (/^\d+$/.test(tsStr)) {
        const date = new Date(parseInt(tsStr) * 1000);
        const pad = n => n.toString().padStart(2, '0');
        return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
               `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
    }
    const parts = tsStr.match(/^(\d+)-(\d+)-(\d+)\s+(\d+):(\d+):(\d+)$/);
    if (!parts) return tsStr;
    const utcMs = Date.UTC(parseInt(parts[1]), parseInt(parts[2])-1, parseInt(parts[3]), parseInt(parts[4]), parseInt(parts[5]), parseInt(parts[6]));
    const localDate = new Date(utcMs);
    const pad = n => n.toString().padStart(2, '0');
    return `${localDate.getFullYear()}-${pad(localDate.getMonth() + 1)}-${pad(localDate.getDate())} ` +
           `${pad(localDate.getHours())}:${pad(localDate.getMinutes())}:${pad(localDate.getSeconds())}`;
}

function processAvailabilityData(logs) {
    eventsHistory = [];
    if (!logs || logs.length === 0) {
        g('stat_drops_count').innerText = 0;
        g('stat_total_downtime').innerText = "0s";
        g('stat_uptime_percent').innerText = "Доступность линии (24ч): 100.00%";
        g('current_status').innerHTML = '<span class="pulse-green"></span><span style="color:#10b981;">ONLINE</span>';
        g('current_duration').innerText = "Непрерывная работа: --";
        g('current_status').parentNode.style.borderColor = "#334155";
        renderTimelineBar();
        return;
    }
    
    // Sort chronologically
    logs.sort((a,b) => parseDateStr(a.timestamp) - parseDateStr(b.timestamp));
    
    let totalDrops = 0;
    let totalDowntimeSec = 0;
    
    for (let i = 0; i < logs.length; i++) {
        const item = logs[i];
        const stateLower = item.state.toLowerCase();
        
        if (stateLower.includes("down")) {
            totalDrops++;
            const tStart = parseDateStr(item.timestamp);
            let tEnd = getRouterNow();
            let duration = 0;
            
            // Find corresponding UP state
            for (let j = i + 1; j < logs.length; j++) {
                if (logs[j].state.toLowerCase().includes("up")) {
                    tEnd = parseDateStr(logs[j].timestamp);
                    // Extract duration
                    const durMatch = logs[j].details.match(/Downtime:\s*(\d+)s/);
                    if (durMatch) {
                        duration = parseInt(durMatch[1]);
                    } else {
                        duration = Math.floor((tEnd - tStart) / 1000);
                    }
                    break;
                }
            }
            
            if (duration === 0) {
                duration = Math.floor((tEnd - tStart) / 1000);
            }
            
            totalDowntimeSec += duration;
            
            eventsHistory.push({
                start: tStart,
                end: tEnd,
                duration: duration,
                timeStr: item.timestamp
            });
        }
    }
    
    // Update Stats Card
    g('stat_drops_count').innerText = totalDrops;
    g('stat_total_downtime').innerText = totalDowntimeSec + "s";
    
    // Update Current Status Card
    if (logs.length > 0) {
        const lastEvent = logs[logs.length - 1];
        const lastStateLower = lastEvent.state.toLowerCase();
        const lastTime = parseDateStr(lastEvent.timestamp);
        
        let statusHtml = "";
        let durLabel = "";
        
        if (lastStateLower.includes("down")) {
            statusHtml = '<span class="pulse-red"></span><span style="color:#ef4444;">OFFLINE</span>';
            const dur = Math.floor((getRouterNow() - lastTime) / 1000);
            durLabel = _t("Сбой длится:") + " " + formatDuration(dur);
            g('current_status').parentNode.style.borderColor = "#ef4444";
        } else {
            statusHtml = '<span class="pulse-green"></span><span style="color:#10b981;">ONLINE</span>';
            const dur = Math.floor((getRouterNow() - lastTime) / 1000);
            durLabel = _t("Непрерывная работа:") + " " + formatDuration(dur);
            g('current_status').parentNode.style.borderColor = "#334155";
        }
        
        g('current_status').innerHTML = statusHtml;
        g('current_duration').innerText = durLabel;
    }
    
    renderTimelineBar();
}

function renderTimelineBar() {
    const wrapper = g('timeline_bar');
    if (!wrapper) return;
    
    wrapper.innerHTML = "";
    
    if (eventsHistory.length === 0) {
        g('timeline_span_label').innerText = _t("Аптайм линии:") + " 100%";
        g('stat_uptime_percent').innerText = _t("Доступность линии:") + " 100.00%";
        
        const nowStr = new Date().toLocaleTimeString();
        g('timeline_label_start').innerText = _t("24ч назад");
        g('timeline_label_end').innerText = nowStr;
        return;
    }
    
    const now = getRouterNow();
    const oneDayAgo = now - 24 * 60 * 60 * 1000;
    
    // Calculate uptime percentage
    let totalDowntimeInWindow = 0;
    eventsHistory.forEach(ev => {
        const s = Math.max(ev.start, oneDayAgo);
        const e = Math.min(ev.end, now);
        if (e > s) {
            totalDowntimeInWindow += (e - s);
        }
    });
    
    const totalWindowTime = now - oneDayAgo;
    const uptimePercent = Math.max(0, Math.min(100, 100 - (totalDowntimeInWindow / totalWindowTime) * 100));
    g('stat_uptime_percent').innerText = _t("Доступность линии:") + " " + uptimePercent.toFixed(2) + "%";
    g('timeline_span_label').innerText = _t("Сбоев:") + " " + eventsHistory.length + " (" + _t("Аптайм:") + " " + uptimePercent.toFixed(2) + "%)";
    
    g('timeline_label_start').innerText = new Date(oneDayAgo).toLocaleTimeString();
    g('timeline_label_end').innerText = new Date(now).toLocaleTimeString();
    
    // Add red blocks for downtime
    eventsHistory.forEach(ev => {
        if (ev.end < oneDayAgo) return; // Older than 24h
        
        const startOffset = Math.max(ev.start, oneDayAgo) - oneDayAgo;
        const duration = Math.min(ev.end, now) - Math.max(ev.start, oneDayAgo);
        
        const leftPercent = (startOffset / totalWindowTime) * 100;
        const widthPercent = Math.max(0.5, (duration / totalWindowTime) * 100); // at least 0.5% width to be visible
        
        const segment = document.createElement('div');
        segment.className = "timeline-segment-down";
        segment.style.left = leftPercent + "%";
        segment.style.width = widthPercent + "%";
        
        // Show tooltip on hover
        segment.addEventListener('mouseenter', (e) => {
            const tooltip = g('pc_tooltip');
            tooltip.innerHTML = `<strong>${_t('СБОЙ ИНТЕРНЕТА')}</strong><br/>` +
                                `${_t('Начало:')} ${utcToLocalStr(ev.timeStr)}<br/>` +
                                `${_t('Длительность:')} ${formatDuration(ev.duration)}`;
            tooltip.style.display = 'block';
            
            const rect = wrapper.getBoundingClientRect();
            const segRect = segment.getBoundingClientRect();
            
            tooltip.style.left = (segRect.left - rect.left + segRect.width/2 - 80) + "px";
            tooltip.style.top = "-65px";
        });
        
        segment.addEventListener('mouseleave', () => {
            g('pc_tooltip').style.display = 'none';
        });
        
        wrapper.appendChild(segment);
    });
}

function fetchPingcheckData() {
    const url = '<%=luci.dispatcher.build_url("admin/modem/pingcheck_data")%>';
    fetch(url)
        .then(res => res.json())
        .then(data => {
            if (data.success) {
                if (data.router_time) {
                    timeSkew = Date.now() - data.router_time;
                }
                // Update Daemon Status Warning Banner
                const warningBanner = g('daemon_warning_banner');
                if (data.daemon_running) {
                    warningBanner.style.display = 'none';
                } else {
                    warningBanner.style.display = 'flex';
                }

                // Update Last Checked Time Label
                const lastCheckTimeLabel = g('last_check_time_label');
                if (data.last_check) {
                    lastCheckTimeLabel.innerText = _t('Обновлено:') + ' ' + utcToLocalStr(data.last_check);
                } else {
                    lastCheckTimeLabel.innerText = _t('Обновлено:') + ' --';
                }

                // 1. Process stats & status
                processAvailabilityData(data.logs);
                
                // 2. Populate logs table
                const logsBody = g('logs_table').querySelector('tbody');
                logsBody.innerHTML = "";
                if (data.logs.length === 0) {
                    logsBody.innerHTML = `<tr><td colspan="3" style="text-align: center; color: #94a3b8;">${_t('Лог мониторинга пуст. Соединение стабильно.')}</td></tr>`;
                } else {
                    // Show reverse chronological
                    const sortedLogs = [...data.logs].reverse();
                    sortedLogs.forEach(item => {
                        const tr = document.createElement('tr');
                        const isUp = item.state.toLowerCase().includes("up");
                        const start = item.state.toLowerCase().includes("start");
                        
                        let badgeHtml = "";
                        if (start) {
                            badgeHtml = `<span class="badge-up" style="background:rgba(59,130,246,0.15); color:#60a5fa;">${_t('СТАРТ')}</span>`;
                        } else if (isUp) {
                            badgeHtml = `<span class="badge-up">ONLINE</span>`;
                        } else {
                            badgeHtml = `<span class="badge-down">OFFLINE</span>`;
                        }
                        
                        tr.innerHTML = `
                            <td style="font-family: monospace;">${utcToLocalStr(item.timestamp)}</td>
                            <td>${badgeHtml}</td>
                            <td style="color: ${isUp ? '#94a3b8' : '#f87171'};">${item.details ? _t(item.details) : (isUp ? _t('Связь успешно восстановлена') : _t('Соединение прервано'))}</td>
                        `;
                        logsBody.appendChild(tr);
                    });
                }
                
                // 3. Populate bugreports table
                const brBody = g('bugreports_table').querySelector('tbody');
                brBody.innerHTML = "";
                if (data.bugreports.length === 0) {
                    brBody.innerHTML = `<tr><td colspan="4" style="text-align: center; color: #94a3b8;">${_t('Багрепорты не найдены. Сбоев длиннее 10 сек не зафиксировано.')}</td></tr>`;
                } else {
                    // Sort newest first
                    data.bugreports.sort((a,b) => b.filename.localeCompare(a.filename));
                    data.bugreports.forEach(br => {
                        const tr = document.createElement('tr');
                        
                        const dlUrl = '<%=luci.dispatcher.build_url("admin/modem/download_bugreport")%>?file=' + encodeURIComponent(br.filename);
                        
                        const nameMatch = br.filename.match(/bugreport_(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})/);
                        let displayDate = br.date;
                        if (nameMatch) {
                            displayDate = utcToLocalStr(`${nameMatch[1]}-${nameMatch[2]}-${nameMatch[3]} ${nameMatch[4]}:${nameMatch[5]}:${nameMatch[6]}`);
                        }
                        
                        tr.innerHTML = `
                            <td style="font-family: monospace; font-weight: bold; color: #f59e0b;">${br.filename}</td>
                            <td>${br.size}</td>
                            <td>${displayDate}</td>
                            <td style="text-align: center; display: flex; gap: 8px; justify-content: center;">
                                <a href="${dlUrl}" style="display: inline-block; padding: 4px 10px; background-color: #3b82f6; color: #ffffff; border-radius: 4px; font-weight: bold; cursor: pointer; text-decoration: none; font-size: 11px;">${_t('Скачать')}</a>
                                <button type="button" onclick="deleteBugreport('${br.filename}')" style="display: inline-block; padding: 4px 10px; background-color: #ef4444; color: #ffffff; border: none; border-radius: 4px; font-weight: bold; cursor: pointer; font-size: 11px; outline: none;">${_t('Удалить')}</button>
                            </td>
                        `;
                        brBody.appendChild(tr);
                    });
                }
            }
        })
        .catch(err => console.error('Pingcheck sync failed:', err));
}

function deleteBugreport(filename) {
    if (!confirm(_t('Вы действительно хотите удалить этот багрепорт?') + '\n' + filename)) return;
    
    const url = '<%=luci.dispatcher.build_url("admin/modem/delete_bugreport")%>?file=' + encodeURIComponent(filename);
    fetch(url)
        .then(res => res.json())
        .then(data => {
            if (data.success) {
                fetchPingcheckData();
            } else {
                alert(_t('Не удалось удалить файл'));
            }
        })
        .catch(err => console.error(err));
}

function clearLogs() {
    if (!confirm(_t('Вы действительно хотите очистить всю историю переходов?\nЛог pingcheck.log будет полностью стерт.'))) return;
    
    const url = '<%=luci.dispatcher.build_url("admin/modem/clear_pingcheck_log")%>';
    fetch(url)
        .then(res => res.json())
        .then(data => {
            if (data.success) {
                fetchPingcheckData();
            } else {
                alert(_t('Не удалось очистить лог'));
            }
        })
        .catch(err => console.error(err));
}

// Start polling
function startPolling() {
    fetchPingcheckData();
    activePollId = setInterval(fetchPingcheckData, 4000);
}

// Language Translation Logic
const dict = {
    "Фоновая служба мониторинга не запущена!": "Background monitoring service is not running!",
    "Пожалуйста, проверьте статус службы `/etc/init.d/pingcheck`. Статистика и данные о сбоях могут быть неактуальными.": "Please check the status of the `/etc/init.d/pingcheck` service. Stats and crash data might be outdated.",
    "Текущее состояние связи": "Current Connection State",
    "Непрерывная работа:": "Continuous uptime:",
    "Обновлено:": "Updated:",
    "Статистика за текущую сессию": "Current Session Statistics",
    "СБОЕВ ИНТЕРНЕТА:": "INTERNET FAILURES:",
    "ОБЩЕЕ ВРЕМЯ ПРОСТОЯ:": "TOTAL DOWNTIME:",
    "Доступность линии:": "Line availability:",
    "Таймлайн аптайма (История за 24ч)": "Uptime Timeline (24h History)",
    "Срез времени доступности": "Availability Timeline",
    "История переходов и инцидентов": "State Transitions & Incidents History",
    "Очистить лог": "Clear Log",
    "Архив багрепортов (сбои > 10 секунд)": "Bug Reports Archive (Failures > 10 sec)",
    "Снимаются автоматически ровно один раз при падении": "Automatically collected exactly once per failure",
    "Имя файла": "Filename",
    "Размер": "Size",
    "Дата сбора": "Gather Date",
    "Действия": "Actions",
    "Скачать": "Download",
    "Удалить": "Delete",
    "Загрузка логов переходов...": "Loading transition logs...",
    "Лог мониторинга пуст. Соединение стабильно.": "Monitoring log is empty. Connection is stable.",
    "Багрепорты не найдены. Сбоев длиннее 10 сек не зафиксировано.": "No bug reports found. No failures longer than 10 sec recorded.",
    "Сбой длится:": "Failure duration:",
    "Сбоев:": "Failures:",
    "Аптайм:": "Uptime:",
    "Аптайм линии:": "Line Uptime:",
    "24ч назад": "24h ago",
    "Вы действительно хотите очистить всю историю переходов?\nЛог pingcheck.log будет полностью стерт.": "Are you sure you want to clear transition history?\nThe pingcheck.log file will be completely erased.",
    "Вы действительно хотите удалить этот багрепорт?": "Are you sure you want to delete this bug report?",
    "Не удалось удалить файл": "Failed to delete file",
    "Не удалось очистить лог": "Failed to clear log",
    "Время события": "Event Time",
    "Состояние": "State",
    "Детали сбоя": "Failure Details",
    "Начало:": "Start:",
    "Длительность:": "Duration:",
    "СБОЙ ИНТЕРНЕТА": "INTERNET FAILURE",
    "СТАРТ": "START",
    "Связь успешно восстановлена": "Connection successfully restored",
    "Соединение прервано": "Connection interrupted",
    "Мониторинг доступности интернета (Internet Availability)": "Internet Availability Monitoring",
    "Фоновый контроль соединения на интерфейсе wwan0 с автоматическим сбором логов при сбоях.": "Background connection monitoring on wwan0 interface with automatic crash log gathering."
};

function _t(str) {
    if (!str) return str;
    const lang = localStorage.getItem('modem_lang') || 'ru';
    if (lang === 'ru') return str;
    return dict[str] || str;
}

function changeLanguage(lang) {
    localStorage.setItem('modem_lang', lang);
    document.cookie = "modem_lang=" + lang + "; path=/; max-age=31536000";
    const selects = document.querySelectorAll('#lang_select');
    selects.forEach(s => s.value = lang);
    translatePage(lang);
}

function translatePage(lang) {
    const elements = document.querySelectorAll('h3, h4, h5, p, label, button, span, strong, option, th, td, a, div, input, select');
    const sortedKeys = Object.keys(dict).sort((a, b) => b.length - a.length);
    elements.forEach(el => {
        // Translate text nodes
        let hasTextChild = false;
        for (let node of el.childNodes) {
            if (node.nodeType === Node.TEXT_NODE && node.nodeValue.trim().length > 0) {
                hasTextChild = true;
                break;
            }
        }
        if (hasTextChild) {
            if (!el.hasAttribute('data-ru')) {
                el.setAttribute('data-ru', el.innerHTML);
            }
            const origRu = el.getAttribute('data-ru');
            if (lang === 'en') {
                let translated = origRu;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.innerHTML = translated;
            } else {
                el.innerHTML = origRu;
            }
        }

        // Translate placeholders
        if (el.placeholder) {
            if (!el.hasAttribute('data-placeholder-ru')) {
                el.setAttribute('data-placeholder-ru', el.placeholder);
            }
            const origPl = el.getAttribute('data-placeholder-ru');
            if (lang === 'en') {
                let translated = origPl;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.placeholder = translated;
            } else {
                el.placeholder = origPl;
            }
        }

        // Translate titles
        if (el.title) {
            if (!el.hasAttribute('data-title-ru')) {
                el.setAttribute('data-title-ru', el.title);
            }
            const origTitle = el.getAttribute('data-title-ru');
            if (lang === 'en') {
                let translated = origTitle;
                for (let ruStr of sortedKeys) {
                    const escaped = ruStr.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
                    const regex = new RegExp(escaped, 'g');
                    translated = translated.replace(regex, dict[ruStr]);
                }
                el.title = translated;
            } else {
                el.title = origTitle;
            }
        }
    });
}

// Initial language setup
const currentLang = localStorage.getItem('modem_lang') || 'ru';
document.cookie = "modem_lang=" + currentLang + "; path=/; max-age=31536000";
const select = document.getElementById('lang_select');
if (select) select.value = currentLang;
setTimeout(() => translatePage(currentLang), 100);

setTimeout(startPolling, 500);
</script>

<%+footer%>

EOF

chmod +x /usr/bin/sms_sync.lua
chmod +x /usr/bin/modem_speed_daemon.lua
chmod +x /etc/init.d/modem_speed
/etc/init.d/modem_speed enable
/etc/init.d/modem_speed restart

# Stop, disable, and remove old standalone pingcheck service if it exists
if [ -f /etc/init.d/pingcheck ]; then
    echo "Stopping and disabling old standalone pingcheck service..."
    /etc/init.d/pingcheck stop 2>/dev/null
    /etc/init.d/pingcheck disable 2>/dev/null
    rm -f /etc/init.d/pingcheck /usr/bin/pingcheck.sh
fi

rm -rf /tmp/luci-*
/etc/init.d/rpcd restart
echo "Installation Complete!"
