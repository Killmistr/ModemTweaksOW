#!/bin/sh

echo "================================================================="
echo "Installing Cellular Modem Auto-Recovery Daemon..."
echo "================================================================="

echo "Deploying /usr/bin/modem_recovery_daemon.lua..."
cat << \EOF > /usr/bin/modem_recovery_daemon.lua
-- Modem Auto-Recovery Daemon
-- Monitors logread and mmcli to repair cellular connection drops

local M = {}

-- ============================================================================
-- Configuration (User-Configurable)
-- ============================================================================
M.VERSION = "v0.1"
M.CHECK_INTERVAL = 2            -- Seconds between check ticks
M.IFACE_RESTART_COOLDOWN = 15   -- Cooldown after running 'ifup MODEM' (seconds)
M.MM_RESTART_COOLDOWN = 20      -- Cooldown after restarting ModemManager (seconds)
M.POST_MM_RESTART_WAIT = 10     -- Seconds to wait after MM restart or USB reset before resetting interface
M.POST_IFUP_WAIT = 5            -- Seconds to wait inside 'ifup' sequence for stability
M.REGISTRATION_TIMEOUT = 30     -- Seconds to wait for network registration before recovery
M.SYSTEM_HISTORY_PATH = "system_history.log" -- History log path
M.consecutive_recovery_count = 0
M.first_recovery_timestamp = 0               -- Timestamp of when the first recovery started (for total duration watchdog)
M.MAX_TOTAL_RECOVERY_DURATION = 180          -- Max seconds in recovery before forcing USB reset (3 minutes)

-- Trigger Arrays (Lua Pattern Regexes)
M.IFACE_TRIGGERS = {
    "3GPP packet service state changed.*attached.*detached",
    "reloading stats failed: Transaction timed out",
    "Session connection failed",
    "REGISTRATION_FAILED",
    "3GPP registration state changed.*denied",
    "registration check failed",
    "couldn't connect the modem",
    "Error%.Status%.Failure"
}

M.MM_TRIGGERS = {
    "Failed to find primary AT port",
    "port 'cdc%-wdm%d' no longer controllable",
    "could not grab port cdc%-wdm%d",
    "SIM identifier has changed",
    "MBIM protocol error: NotOpened"
}

M.USB_TRIGGERS = {
    "Cannot add port.*unhandled port type",
    "unhandled port type",
    "Device not managed by ModemManager",
    "couldn't find modem"
}

-- ============================================================================
-- Shell Execution Abstraction Layer (For Mocking and Testing)
-- ============================================================================
M.exec = function(cmd)
    local safe_cmd = cmd
    if not cmd:match("^timeout%s") then
        safe_cmd = "timeout 5 " .. cmd
    end
    local h = io.popen(safe_cmd .. " 2>&1")
    if h then
        local res = h:read("*a")
        h:close()
        return res or ""
    end
    return ""
end

M.execute = function(cmd)
    return os.execute(cmd)
end

local function reset_modem_usb()
    -- Send flight mode command before USB disconnect to ensure clean baseband shutdown
    M.execute("mmcli -m any --command='AT+CFUN=0' 2>/dev/null")
    M.execute("sleep 1")

    local p = io.popen("grep -l -E 'VOS_5G|Tri Cascade' /sys/bus/usb/devices/*/product 2>/dev/null")
    if p then
        local filepath = p:read("*l")
        p:close()
        if filepath then
            local dev_dir = filepath:match("(/sys/bus/usb/devices/[a-zA-Z0-9%.%-]+)/product")
            if dev_dir then
                M.execute("logger -t modem_recovery 'PERFORMING HARDWARE USB RESET ON PORT: " .. dev_dir .. "'")
                M.execute("echo 0 > " .. dev_dir .. "/authorized")
                M.execute("sleep 10")
                M.execute("echo 1 > " .. dev_dir .. "/authorized")
                return true
            end
        end
    end
    -- Fallback to hardcoded port if discovery fails
    local f_test = io.open("/sys/bus/usb/devices/2-1.4/authorized")
    if f_test then
        f_test:close()
        M.execute("logger -t modem_recovery 'PERFORMING HARDWARE USB RESET ON FALLBACK PORT: 2-1.4'")
        M.execute("echo 0 > /sys/bus/usb/devices/2-1.4/authorized")
        M.execute("sleep 10")
        M.execute("echo 1 > /sys/bus/usb/devices/2-1.4/authorized")
        return true
    end
    return false
end

-- ============================================================================
-- Helper Logging Functions
-- ============================================================================
local function get_last_signal_metrics()
    local mm_out = M.exec("mmcli -m any 2>/dev/null") or ""
    local wdm = mm_out:match("(cdc%-wdm%d+)") or mm_out:match("(wwan%d*qmi%d*)")
    local qmi_dev = "/dev/cdc-wdm0"
    if wdm then
        qmi_dev = "/dev/" .. wdm
    else
        local ls_p = M.exec("ls /dev/cdc-wdm* /dev/wwan*qmi* 2>/dev/null") or ""
        local first_dev = ls_p:match("(/dev/[^\r\n%s]+)")
        if first_dev then qmi_dev = first_dev end
    end

    local qmi_sig_info = M.exec("qmicli -d " .. qmi_dev .. " --nas-get-signal-info -p 2>/dev/null")
    if not qmi_sig_info or qmi_sig_info == "" or not qmi_sig_info:match("RSSI") then
        local sq = mm_out:match("signal quality:%s*'([^']+)'")
        if sq then
            return string.format("Signal Quality (mmcli): %s%%", sq)
        end
        return "Signal Info: N/A"
    end
    
    local lte_rssi = qmi_sig_info:match("LTE:.-RSSI:%s*'([^']+)'") or "n/a"
    local lte_rsrq = qmi_sig_info:match("LTE:.-RSRQ:%s*'([^']+)'") or "n/a"
    local lte_rsrp = qmi_sig_info:match("LTE:.-RSRP:%s*'([^']+)'") or "n/a"
    local lte_snr  = qmi_sig_info:match("LTE:.-SNR:%s*'([^']+)'") or "n/a"
    
    local nr_rsrp = qmi_sig_info:match("5G:.-RSRP:%s*'?([^'\r\n]+)'?") or "n/a"
    local nr_snr  = qmi_sig_info:match("5G:.-S[IN]*R:%s*'?([^'\r\n]+)'?") or "n/a"
    local nr_rsrq = qmi_sig_info:match("5G:.-RSRQ:%s*'?([^'\r\n]+)'?") or "n/a"

    if lte_rsrp ~= "n/a" or lte_rssi ~= "n/a" then
        local sig_str = string.format("LTE: RSSI=%s, RSRP=%s, RSRQ=%s, SINR=%s", lte_rssi, lte_rsrp, lte_rsrq, lte_snr)
        if nr_rsrp ~= "n/a" then
            sig_str = sig_str .. string.format(" | 5G: RSRP=%s, RSRQ=%s, SINR=%s", nr_rsrp, nr_rsrq, nr_snr)
        end
        return sig_str
    else
        -- If LTE not found, maybe check UMTS
        local umts_rscp = qmi_sig_info:match("UMTS:.-RSCP:%s*'([^']+)'") or "n/a"
        local umts_ecio = qmi_sig_info:match("UMTS:.-ECIO:%s*'([^']+)'") or "n/a"
        if umts_rscp ~= "n/a" then
            return string.format("UMTS: RSCP=%s, ECIO=%s", umts_rscp, umts_ecio)
        end
    end
    
    return "Signal Info: no active carriers"
end

local function log_signal_metrics(reason)
    local sig_metrics = get_last_signal_metrics()
    local date_str = os.date("%a %b %d %H:%M:%S %Y")
    local log_msg = string.format("%s daemon.notice modem_recovery: SIGNAL_CHECK (%s): %s", date_str, reason, sig_metrics)
    
    -- Append to system_history.log (matching local directory pattern)
    local f = io.open(M.SYSTEM_HISTORY_PATH, "a")
    if f then
        f:write(log_msg .. "\n")
        f:close()
    end
    
    -- Also log to /www/system_history.log in case of different LuCI working dir
    local f_www = io.open("/www/" .. M.SYSTEM_HISTORY_PATH, "a")
    if f_www then
        f_www:write(log_msg .. "\n")
        f_www:close()
    end

    -- Write to system logger
    M.execute(string.format("logger -t modem_recovery 'SIGNAL_CHECK (%s): %s'", reason, sig_metrics))
end


local function log_recovery(action_name)
    local date_str = os.date("%a %b %d %H:%M:%S %Y")
    local log_msg = string.format("%s daemon.notice modem_recovery: RECOVERY_ACTION: %s", date_str, action_name)
    
    -- Append to system_history.log (matching local directory pattern)
    local f = io.open(M.SYSTEM_HISTORY_PATH, "a")
    if f then
        f:write(log_msg .. "\n")
        f:close()
    end
    
    -- Also log to /www/system_history.log in case of different LuCI working dir
    local f_www = io.open("/www/" .. M.SYSTEM_HISTORY_PATH, "a")
    if f_www then
        f_www:write(log_msg .. "\n")
        f_www:close()
    end

    -- Write to system logger
    M.execute(string.format("logger -t modem_recovery 'RECOVERY_ACTION: %s'", action_name))
end

local function log_ping_state(state, details)
    local timestamp = os.time()
    local log_msg = string.format("%d | %s | %s", timestamp, state, details or "")
    if not details or details == "" then
        log_msg = string.format("%d | %s", timestamp, state)
    end
    
    -- Append to /tmp/pingcheck.log
    local f = io.open("/tmp/pingcheck.log", "a")
    if f then
        f:write(log_msg .. "\n")
        f:close()
    end
    
    -- Append to /root/pingcheck_history.log on state transitions (START, UP, DOWN)
    if state == "START" or state == "UP" or state == "DOWN" then
        local f_hist = io.open("/root/pingcheck_history.log", "a")
        if f_hist then
            f_hist:write(log_msg .. "\n")
            f_hist:close()
        end
    end
end

local function rotate_logs()
    -- Rotate /tmp/pingcheck.log (keep last 28,800 lines)
    local f = io.open("/tmp/pingcheck.log", "r")
    if f then
        local lines = {}
        for line in f:lines() do
            table.insert(lines, line)
        end
        f:close()
        
        if #lines > 28800 then
            local f_w = io.open("/tmp/pingcheck.log", "w")
            if f_w then
                for i = #lines - 28799, #lines do
                    f_w:write(lines[i] .. "\n")
                end
                f_w:close()
            end
        end
    end
    
    -- Rotate /root/pingcheck_history.log (keep last 1000 lines)
    local f_hist = io.open("/root/pingcheck_history.log", "r")
    if f_hist then
        local lines = {}
        for line in f_hist:lines() do
            table.insert(lines, line)
        end
        f_hist:close()
        
        if #lines > 1000 then
            local f_w = io.open("/root/pingcheck_history.log", "w")
            if f_w then
                for i = #lines - 999, #lines do
                    f_w:write(lines[i] .. "\n")
                end
                f_w:close()
            end
        end
    end
end

function M.generate_bugreport(drop_time, net_iface)
    net_iface = net_iface or "wwan0"
    M.execute("mkdir -p /root/bugreports")
    local time_suffix = os.date("%Y-%m-%d_%H-%M-%S")
    local filename = "/root/bugreports/bugreport_" .. time_suffix .. ".log"
    
    local f = io.open(filename, "w")
    if f then
        f:write("=================================================================\n")
        f:write("CELLULAR INTERNET LOSS BUGREPORT\n")
        f:write("=================================================================\n")
        f:write("Problem occurred at: " .. tostring(drop_time) .. "\n")
        f:write("Bugreport generated at: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")
        
        f:write("=== NETWORK INTERFACES ===\n")
        f:write(M.exec("ifconfig " .. net_iface .. " 2>&1") .. "\n\n")
        
        f:write("=== IP ADDRESSES ===\n")
        f:write(M.exec("ip addr show dev " .. net_iface .. " 2>&1") .. "\n\n")
        
        f:write("=== ROUTING TABLE ===\n")
        f:write(M.exec("ip route show 2>&1") .. "\n\n")
        
        f:write("=== MODEM MANAGER STATE ===\n")
        f:write(M.exec("mmcli -m any 2>&1") .. "\n\n")
        
        f:write("=== KERNEL DMESG (LAST 30 LINES) ===\n")
        f:write(M.exec("dmesg | tail -n 30 2>&1") .. "\n\n")
        
        f:write("=== SYSTEM LOGREAD (LAST 1000 LINES) ===\n")
        f:write(M.exec("logread | tail -n 1000 2>&1") .. "\n")
        f:write("=================================================================\n")
        f:close()
        
        M.execute("logger -t pingcheck 'Bugreport successfully saved to " .. filename .. "'")
        
        -- Keep only the last 20 bugreports
        M.execute("(cd /root/bugreports && ls -1t bugreport_*.log 2>/dev/null | tail -n +21 | xargs rm -f)")
    end
end


-- ============================================================================
-- Metrics Collection and Reporting
-- ============================================================================
M.metrics = {
    total_recovery_count = 0,
    interface_recovery_count = 0,
    rf_recovery_count = 0,
    mm_recovery_count = 0,
    usb_recovery_count = 0,
    last_recovery_type = "none",
    last_recovery_time = "-",
    last_recovery_reason = "-",
    current_state = "Starting",
    current_state_duration = 0,
    total_missing_duration = 0,
    total_unregistered_duration = 0,
    total_no_ip_duration = 0,
    total_no_ping_duration = 0,
    total_connected_duration = 0,
    total_disabled_duration = 0,
    total_denied_duration = 0,
    modem_present = false,
    modemmanager_status = "Starting"
}

local function write_metrics_json()
    local data = M.metrics
    local json_str = string.format([[
{
  "version": %q,
  "total_recovery_count": %d,
  "interface_recovery_count": %d,
  "rf_recovery_count": %d,
  "mm_recovery_count": %d,
  "usb_recovery_count": %d,
  "last_recovery_type": %q,
  "last_recovery_time": %q,
  "last_recovery_reason": %q,
  "current_state": %q,
  "current_state_duration": %d,
  "current_consecutive_recovery_count": %d,
  "total_missing_duration": %d,
  "total_unregistered_duration": %d,
  "total_no_ip_duration": %d,
  "total_no_ping_duration": %d,
  "total_connected_duration": %d,
  "total_disabled_duration": %d,
  "total_denied_duration": %d,
  "modem_present": %s,
  "modemmanager_status": %q
}
]],
        M.VERSION or "v0.1",
        data.total_recovery_count or 0,
        data.interface_recovery_count or 0,
        data.rf_recovery_count or 0,
        data.mm_recovery_count or 0,
        data.usb_recovery_count or 0,
        data.last_recovery_type or "none",
        data.last_recovery_time or "-",
        data.last_recovery_reason or "-",
        data.current_state or "Starting",
        data.current_state_duration or 0,
        M.consecutive_recovery_count or 0,
        data.total_missing_duration or 0,
        data.total_unregistered_duration or 0,
        data.total_no_ip_duration or 0,
        data.total_no_ping_duration or 0,
        data.total_connected_duration or 0,
        data.total_disabled_duration or 0,
        data.total_denied_duration or 0,
        tostring(data.modem_present == true),
        data.modemmanager_status or "Starting"
    )
    local f = io.open("/tmp/modem_recovery_metrics.json.tmp", "w")
    if f then
        f:write(json_str)
        f:close()
        os.rename("/tmp/modem_recovery_metrics.json.tmp", "/tmp/modem_recovery_metrics.json")
    end
end

local function load_metrics_json()
    local f = io.open("/tmp/modem_recovery_metrics.json", "r")
    if f then
        local content = f:read("*a")
        f:close()
        
        local function get_num(key)
            return tonumber(content:match('"' .. key .. '"%s*:%s*(%d+)')) or 0
        end
        local function get_str(key)
            return content:match('"' .. key .. '"%s*:%s*"([^"]*)"') or "-"
        end
        local function get_bool(key)
            return content:match('"' .. key .. '"%s*:%s*(true)') ~= nil
        end

        M.metrics.total_recovery_count = get_num("total_recovery_count")
        M.metrics.interface_recovery_count = get_num("interface_recovery_count")
        M.metrics.rf_recovery_count = get_num("rf_recovery_count")
        M.metrics.mm_recovery_count = get_num("mm_recovery_count")
        M.metrics.usb_recovery_count = get_num("usb_recovery_count")
        M.metrics.last_recovery_type = get_str("last_recovery_type")
        M.metrics.last_recovery_time = get_str("last_recovery_time")
        M.metrics.last_recovery_reason = get_str("last_recovery_reason")
        M.metrics.current_state = get_str("current_state")
        M.metrics.current_state_duration = get_num("current_state_duration")
        M.consecutive_recovery_count = get_num("current_consecutive_recovery_count")
        M.metrics.total_missing_duration = get_num("total_missing_duration")
        M.metrics.total_unregistered_duration = get_num("total_unregistered_duration")
        M.metrics.total_no_ip_duration = get_num("total_no_ip_duration")
        M.metrics.total_no_ping_duration = get_num("total_no_ping_duration")
        M.metrics.total_connected_duration = get_num("total_connected_duration")
        M.metrics.total_disabled_duration = get_num("total_disabled_duration")
        M.metrics.total_denied_duration = get_num("total_denied_duration")
        M.metrics.modem_present = get_bool("modem_present")
        M.metrics.modemmanager_status = get_str("modemmanager_status")
    end
end

local function log_metrics()
    local m = M.metrics
    local msg = string.format("METRICS: total_recoveries=%d (iface=%d, rf=%d, mm=%d, usb=%d) | last_action=%s (reason: %s, time: %s) | current_state=%s (%ds) | durations: missing=%ds, unreg=%ds, no_ip=%ds, no_ping=%ds, connected=%ds, disabled=%ds, denied=%ds",
        m.total_recovery_count, m.interface_recovery_count, m.rf_recovery_count, m.mm_recovery_count, m.usb_recovery_count,
        m.last_recovery_type, m.last_recovery_reason, m.last_recovery_time,
        m.current_state, m.current_state_duration,
        m.total_missing_duration, m.total_unregistered_duration, m.total_no_ip_duration, m.total_no_ping_duration,
        m.total_connected_duration or 0, m.total_disabled_duration or 0, m.total_denied_duration or 0)
    M.execute("logger -t modem_recovery '" .. msg .. "'")
end

local function get_current_metrics_state()
    local mm_list = M.exec("mmcli -L 2>&1")
    local mm_running = not mm_list:match("error:") and not mm_list:match("Error") and mm_list ~= ""
    
    local mm_status = mm_running and "Running" or "Unresponsive"
    local has_modem = false
    local m_state = "Unknown"
    
    if mm_running then
        has_modem = mm_list:match("ModemManager1/Modem/(%d+)") ~= nil
        
        if has_modem then
            local mm_out = M.exec("mmcli -m any 2>/dev/null")
            local state_str = mm_out:match("state:%s*([^%\n]+)") or ""
            local reg_state = mm_out:match("3gpp registration:%s*([^%\n]+)") or ""
            state_str = state_str:gsub("%s+", ""):lower()
            reg_state = reg_state:gsub("%s+", ""):lower()
            
            if reg_state:match("denied") or state_str:match("denied") then
                m_state = "Denied"
            elseif state_str == "disabled" then
                m_state = "Disabled"
            elseif state_str == "failed" or state_str == "unknown" then
                m_state = "Failed/Unknown"
            elseif state_str == "enabled" or state_str == "searching" or state_str == "registering" then
                m_state = "Unregistered"
            elseif state_str:match("registered") or state_str:match("connected") then
                local net_iface = mm_out:match("net.-ports:%s*([a-zA-Z0-9%-_]+)") or "wwan0"
                local ip_out = M.exec("ip -4 addr show dev " .. net_iface .. " 2>/dev/null")
                local has_ip = ip_out:match("inet%s+%d+%.%d+%.%d+%.%d+") ~= nil
                
                if not has_ip then
                    m_state = "No IP"
                else
                    local ping_res = M.execute("ping -c 1 -W 1 -I " .. net_iface .. " 77.88.8.8 >/dev/null 2>&1")
                    if ping_res ~= 0 then
                        ping_res = M.execute("ping -c 1 -W 1 -I " .. net_iface .. " 77.88.8.1 >/dev/null 2>&1")
                    end
                    if ping_res ~= 0 then
                        m_state = "No Ping"
                    else
                        m_state = "Connected"
                    end
                end
            end
        else
            m_state = "Missing"
        end
    else
        m_state = "Missing"
    end
    
    return mm_status, has_modem, m_state
end

-- ============================================================================
-- Core Logic & Verification Functions
-- ============================================================================

-- Parse logread for trigger patterns
local last_processed_line = nil
local missing_count = 0
local disabled_count = 0
local unregistered_count = 0
local denied_count = 0
local no_ip_count = 0
local no_ping_count = 0

function M.reset_log_state()
    last_processed_line = nil
    missing_count = 0
    disabled_count = 0
    unregistered_count = 0
    denied_count = 0
    no_ip_count = 0
    no_ping_count = 0
end

function M.check_logs()
    local data = M.exec("logread -l 50")
    if not data or data == "" then return nil end

    local lines = {}
    for line in data:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    -- Filter new lines since last check
    local new_lines = {}
    if last_processed_line then
        local start_idx = 1
        for i = #lines, 1, -1 do
            if lines[i] == last_processed_line then
                start_idx = i + 1
                break
            end
        end
        for i = start_idx, #lines do
            table.insert(new_lines, lines[i])
        end
    else
        new_lines = lines
    end

    if #lines > 0 then
        last_processed_line = lines[#lines]
    end

    local triggered_action = nil
    local triggered_reason = nil
    local modem_states = {}

    -- Match against triggers, but scan all new_lines to track packet service transitions
    for _, line in ipairs(new_lines) do
        -- Track latest state transitions (attached -> detached or detached -> attached)
        local modem_idx, from_state, to_state = line:match("%[modem(%d+)%] 3GPP packet service state changed %((%w+)%s*->%s*(%w+)%)")
        if modem_idx then
            modem_states[modem_idx] = to_state
        end

        local matched = false
        -- Check USB triggers first
        for _, pattern in ipairs(M.USB_TRIGGERS) do
            if line:match(pattern) then
                triggered_action = "usb_reset"
                triggered_reason = line
                matched = true
                break
            end
        end
        
        if not matched then
            -- Check MM triggers second
            for _, pattern in ipairs(M.MM_TRIGGERS) do
                if line:match(pattern) then
                    triggered_action = "modemmanager"
                    triggered_reason = line
                    matched = true
                    break
                end
            end
        end

        if not matched then
            -- Check Interface triggers third
            for _, pattern in ipairs(M.IFACE_TRIGGERS) do
                if line:match(pattern) then
                    triggered_action = "interface"
                    triggered_reason = line
                    matched = true
                    break
                end
            end
        end
    end

    -- Cancel packet service detach triggers if the modem attached/restored later in the same tick
    if triggered_action == "interface" and triggered_reason:match("3GPP packet service state changed") then
        local modem_idx = triggered_reason:match("%[modem(%d+)%]")
        if modem_idx and modem_states[modem_idx] == "attached" then
            log_recovery("INFO: CANCELLING LOG TRIGGER - MODEM " .. modem_idx .. " RESTORED TO ATTACHED STATE IN THE SAME TICK")
            triggered_action = nil
            triggered_reason = nil
        end
    end

    return triggered_action, triggered_reason
end

-- Check modem and IP assignment state
function M.check_modem_state(tick_ping_ok)
    local mm_list = M.exec("mmcli -L")
    local has_modem = mm_list:match("ModemManager1/Modem/(%d+)") ~= nil

    if not has_modem then
        missing_count = missing_count + 1
        disabled_count = 0
        unregistered_count = 0
        denied_count = 0
        no_ip_count = 0
        no_ping_count = 0

        if missing_count == 2 then
            log_recovery("Modem missing from mmcli -L for 10 seconds. Restarting ModemManager...")
            M.execute("/etc/init.d/modemmanager restart >/dev/null 2>&1 &")
        elseif missing_count >= 4 then
            missing_count = 0
            return "usb_reset", "Modem missing from mmcli -L for 20 seconds"
        end
        return nil
    else
        missing_count = 0
    end

    local mm_out = M.exec("mmcli -m any")
    local state_str = mm_out:match("state:%s*([^%\n]+)") or ""
    local reg_state = mm_out:match("3gpp registration:%s*([^%\n]+)") or ""
    
    -- Clean up strings
    state_str = state_str:gsub("%s+", ""):lower()
    reg_state = reg_state:gsub("%s+", ""):lower()

    -- Case 1: Modem is denied registration by the tower
    if reg_state:match("denied") or state_str:match("denied") then
        denied_count = denied_count + 1
        disabled_count = 0
        unregistered_count = 0
        no_ip_count = 0
        no_ping_count = 0

        if denied_count >= 2 then
            denied_count = 0
            return "rf_reset", "Modem registration denied by network (10 seconds)"
        end
        return nil
    else
        denied_count = 0
    end

    -- Case 2: Modem is disabled
    if state_str == "disabled" then
        disabled_count = disabled_count + 1
        unregistered_count = 0
        no_ip_count = 0
        no_ping_count = 0

        if disabled_count == 1 then
            log_recovery("Modem is disabled. Sending background enable request...")
            M.execute("mmcli -m any --enable >/dev/null 2>&1 &")
        elseif disabled_count == 3 then
            log_recovery("Modem stuck in disabled state for 15 seconds. Restarting ModemManager...")
            return "modemmanager", "Modem stuck in disabled state for 15 seconds"
        elseif disabled_count >= 5 then
            disabled_count = 0
            return "usb_reset", "Modem stuck in disabled state for 25 seconds"
        end
        return nil
    -- Case 2b: Modem is failed or unknown (critical software crash state)
    elseif state_str == "failed" or state_str == "unknown" then
        disabled_count = disabled_count + 1
        unregistered_count = 0
        no_ip_count = 0
        no_ping_count = 0

        if disabled_count == 2 then
            log_recovery("Modem in critical state (" .. state_str .. ") for 10 seconds. Restarting ModemManager...")
            return "modemmanager", "Modem in critical state (" .. state_str .. ") for 10 seconds"
        elseif disabled_count >= 4 then
            disabled_count = 0
            return "usb_reset", "Modem in critical state (" .. state_str .. ") for 20 seconds"
        end
        return nil
    else
        disabled_count = 0
    end

    -- Case 3: Modem is unregistered (enabled, searching, registering)
    local is_unregistered = state_str == "enabled" or state_str == "searching" or state_str == "registering"
    if is_unregistered then
        unregistered_count = unregistered_count + 1
        no_ip_count = 0
        no_ping_count = 0

        -- Background poking during unregistered state to trigger registration
        if unregistered_count == 2 then
            log_recovery("Modem stuck in unregistered state (" .. state_str .. ") for 10 seconds. Sending background registration request...")
            M.execute("mmcli -m any --register-in-network >/dev/null 2>&1 &")
        end

        local reg_timeout = 30 -- standard registration timeout is 30 seconds
        -- If we are in an active recovery cycle, allow 90 seconds for cold boot & scanning
        if M.consecutive_recovery_count > 0 then
            reg_timeout = 90
        end

        local max_unregistered_ticks = math.ceil(reg_timeout / M.CHECK_INTERVAL)
        if unregistered_count >= max_unregistered_ticks then
            unregistered_count = 0
            -- Go straight to RF reset because simple interface restart won't fix baseband registration issues
            return "rf_reset", "Modem stuck in unregistered state (" .. state_str .. ") for " .. reg_timeout .. " seconds"
        end
        return nil
    else
        unregistered_count = 0
    end

    -- Case 4: Modem is registered or connected but connection is unstable (no IP or ping fails)
    local is_registered = state_str:match("registered") or state_str:match("connected")
    if is_registered then
        local net_iface = mm_out:match("net.-ports:%s*([a-zA-Z0-9%-_]+)") or "wwan0"
        local ip_out = M.exec("ip -4 addr show dev " .. net_iface)
        local has_ip = ip_out:match("inet%s+%d+%.%d+%.%d+%.%d+") ~= nil

        if not has_ip then
            no_ip_count = no_ip_count + 1
            no_ping_count = 0

            -- Wait 15 seconds for IP address assignment before restarting network interface
            if no_ip_count >= 3 then
                no_ip_count = 0
                return "interface", "Modem registered on " .. net_iface .. " but no IP address found for 15 seconds"
            end
        else
            no_ip_count = 0
            
            -- Perform ping to verify connection stability
            local ping_res = 1
            if tick_ping_ok ~= nil then
                ping_res = tick_ping_ok and 0 or 1
            else
                local ping_check_res = M.execute("ping -c 1 -W 1 -I " .. net_iface .. " 77.88.8.8 >/dev/null 2>&1")
                if ping_check_res ~= 0 then
                    ping_check_res = M.execute("ping -c 1 -W 1 -I " .. net_iface .. " 77.88.8.1 >/dev/null 2>&1")
                end
                ping_res = ping_check_res
            end

            if ping_res ~= 0 then
                no_ping_count = no_ping_count + 1
                -- Wait 15 seconds before restarting interface if ping fails
                if no_ping_count >= 3 then
                    no_ping_count = 0
                    return "interface", "Cellular data path frozen (ping failed) for 15 seconds"
                end
            else
                no_ping_count = 0
            end
        end
    end

    return nil
end

-- Perform recovery action
function M.run_recovery(action, reason)
    local sig_metrics = get_last_signal_metrics()
    log_recovery("LAST SIGNAL STATE BEFORE RECOVERY: " .. sig_metrics)

    -- Track total recovery duration: if first recovery, record timestamp
    if M.first_recovery_timestamp == 0 then
        M.first_recovery_timestamp = os.time()
    end

    -- Determine if this is a hardware/critical fault (which requires USB power reset)
    local is_hardware_fault = reason:match("missing") or reason:match("failed") or reason:match("unknown") or reason:match("disabled") or reason:match("autostart")

    -- Total recovery duration watchdog: if stuck in recovery for too long, force USB reset (only for hardware faults)
    local total_recovery_duration = os.time() - M.first_recovery_timestamp
    if total_recovery_duration > M.MAX_TOTAL_RECOVERY_DURATION and action ~= "usb_reset" and is_hardware_fault then
        log_recovery(string.format("TOTAL RECOVERY DURATION EXCEEDED %ds (%ds elapsed) WITH CRITICAL FAULT. FORCING USB RESET.",
            M.MAX_TOTAL_RECOVERY_DURATION, total_recovery_duration))
        action = "usb_reset"
    end

    -- Escalation logic: If we are in an active recovery cycle, upgrade the action to the next tier
    if M.consecutive_recovery_count == 1 and action == "interface" then
        log_recovery("Interface restart already performed. Escalating action to RF Reset.")
        action = "rf_reset"
    elseif M.consecutive_recovery_count == 2 and (action == "interface" or action == "rf_reset" or action == "modemmanager") then
        if is_hardware_fault then
            log_recovery("RF Reset / MM Restart already performed. Critical fault detected. Escalating action to USB Power Reset.")
            action = "usb_reset"
        else
            log_recovery("RF Reset / Interface cycle performed. Escalating to ModemManager Restart to avoid hardware power cycle.")
            action = "modemmanager"
        end
    elseif M.consecutive_recovery_count == 3 then
        -- We already did a USB Reset. Wrap back to interface restart.
        log_recovery("Post-USB-Reset recovery failed. Wrapping escalation back to interface restart.")
        action = "interface"
    end

    -- Update metrics counters
    M.metrics.total_recovery_count = (M.metrics.total_recovery_count or 0) + 1
    if action == "interface" then
        M.metrics.interface_recovery_count = (M.metrics.interface_recovery_count or 0) + 1
    elseif action == "rf_reset" then
        M.metrics.rf_recovery_count = (M.metrics.rf_recovery_count or 0) + 1
    elseif action == "modemmanager" then
        M.metrics.mm_recovery_count = (M.metrics.mm_recovery_count or 0) + 1
    elseif action == "usb_reset" then
        M.metrics.usb_recovery_count = (M.metrics.usb_recovery_count or 0) + 1
    end
    
    M.metrics.last_recovery_type = action
    M.metrics.last_recovery_time = os.date("%Y-%m-%d %H:%M:%S")
    M.metrics.last_recovery_reason = reason or "triggered recovery"
    
    -- Serialize updated metrics and print report to syslog
    write_metrics_json()
    log_metrics()

    -- Direct Action Router
    if action == "usb_reset" then
        log_recovery("CRITICAL USB/HARDWARE FAULT: PERFORMING HARDWARE USB POWER RESET")
        M.consecutive_recovery_count = 3 -- Mark as post-USB-reset phase (requires longer registration time)
        M.first_recovery_timestamp = 0   -- Reset total recovery timer
        
        log_recovery("CLEARING USERSPACE PORT LOCKS")
        M.execute("killall -9 qmicli mbimcli mbim-proxy qmi-proxy 2>/dev/null")
        M.execute("/etc/init.d/modemmanager stop")
        M.execute("sleep 1")
        
        log_recovery("PERFORMING PHYSICAL USB POWER CYCLE (10s)")
        local success = reset_modem_usb()
        M.execute("/etc/init.d/modemmanager start")
        
        if success then
            return M.MM_RESTART_COOLDOWN + 10, true -- pending interface reset after USB re-enumeration
        else
            log_recovery("HARDWARE USB RESET FAILED (PORT NOT FOUND), FALLING BACK TO MM RESTART")
            return M.MM_RESTART_COOLDOWN, true
        end

    elseif action == "modemmanager" then
        log_recovery("RESTARTING MODEMMANAGER SERVICE")
        M.consecutive_recovery_count = 2 -- Escalate recovery counter
        M.execute("/etc/init.d/modemmanager restart")
        return M.MM_RESTART_COOLDOWN, true

    elseif action == "rf_reset" then
        log_recovery("PERFORMING BASEBAND RF RESET via AT+CFUN")
        M.consecutive_recovery_count = 2 -- Escalate recovery counter
        
        log_recovery("SENDING AT+CFUN=0 (FLIGHT MODE)")
        local cfun_result = M.exec("mmcli -m any --command='AT+CFUN=0' 2>&1")
        
        if cfun_result:match("error") or cfun_result:match("No AT port") then
            log_recovery("AT+CFUN not available, falling back to mmcli --disable/--enable")
            M.execute("mmcli -m any --disable 2>/dev/null")
            M.execute("sleep 2")
            M.execute("mmcli -m any --enable 2>/dev/null")
        else
            log_recovery("AT+CFUN=0 sent successfully, waiting 3s for baseband shutdown...")
            M.execute("sleep 3")
            log_recovery("SENDING AT+CFUN=1 (FULL MODE)")
            M.execute("mmcli -m any --command='AT+CFUN=1' 2>/dev/null")
            M.execute("sleep 3")
        end
        
        -- Cycle logical network interface
        log_recovery("BASEBAND RF RESET: RESTARTING NETWORK INTERFACE")
        M.execute("ifdown MODEM && sleep " .. M.POST_IFUP_WAIT .. " && ifup MODEM")
        
        return M.IFACE_RESTART_COOLDOWN, false

    else -- Default or "interface"
        log_recovery("PERFORMING SIMPLE INTERFACE RESTART")
        M.consecutive_recovery_count = 1 -- Set recovery counter to 1
        
        -- Cycle logical network interface
        M.execute("ifdown MODEM && sleep 2 && ifup MODEM")
        
        return M.IFACE_RESTART_COOLDOWN, false
    end
end

-- Check if connection is truly stable (cellular-bound routing/ping check)
function M.is_connection_stable()
    local mm_list = M.exec("mmcli -L")
    local has_modem = mm_list:match("ModemManager1/Modem/(%d+)") ~= nil
    if not has_modem then
        return false, "no modem"
    end

    local mm_out = M.exec("mmcli -m any")
    local state_str = mm_out:match("state:%s*([^%\n]+)") or ""
    local is_connected = state_str:match("connected") ~= nil
    if not is_connected then
        return false, "disconnected"
    end

    local net_iface = mm_out:match("net.-ports:%s*([a-zA-Z0-9%-_]+)") or "wwan0"
    local ip_out = M.exec("ip -4 addr show dev " .. net_iface)
    local has_ip = ip_out:match("inet%s+%d+%.%d+%.%d+%.%d+") ~= nil
    if not has_ip then
        return false, "no ip"
    end

    -- Perform ping bound specifically to the cellular interface
    -- This ensures we don't get false positives from backup Ethernet WAN links!
    local ping_out = M.exec("ping -c 1 -W 2 -I " .. net_iface .. " 77.88.8.8 2>&1")
    if ping_out:match("time=") then
        local latency = ping_out:match("time=([%d%.]+)%s*ms") or "unknown"
        return true, latency .. " ms"
    end

    local ping_out2 = M.exec("ping -c 1 -W 2 -I " .. net_iface .. " 77.88.8.1 2>&1")
    if ping_out2:match("time=") then
        local latency = ping_out2:match("time=([%d%.]+)%s*ms") or "unknown"
        return true, latency .. " ms"
    end

    -- Determine ping failure reason
    local reason = "timeout"
    if ping_out:match("unreachable") or ping_out2:match("unreachable") then
        reason = "unreachable"
    elseif ping_out:match("bad address") or ping_out2:match("bad address") then
        reason = "bad address"
    elseif ping_out:match("invalid") or ping_out2:match("invalid") then
        reason = "invalid interface"
    end

    return false, reason
end

-- Check if connection is restoring or already stable after a transient drop
function M.is_transient_restored()
    local mm_list = M.exec("mmcli -L")
    local has_modem = mm_list:match("ModemManager1/Modem/(%d+)") ~= nil
    if not has_modem then
        return false
    end

    local mm_out = M.exec("mmcli -m any")
    local state_str = mm_out:match("state:%s*([^%\n]+)") or ""
    local reg_state = mm_out:match("3gpp registration:%s*([^%\n]+)") or ""
    state_str = state_str:gsub("%s+", ""):lower()
    reg_state = reg_state:gsub("%s+", ""):lower()

    -- If registration is searching, idle, denied, or unknown, it's NOT restoring/restored
    if reg_state:match("searching") or reg_state:match("idle") or reg_state:match("denied") or reg_state:match("unknown") then
        return false
    end

    -- If the modem is actively connecting, registering, or registered (but not fully connected yet),
    -- we consider it restoring to allow it to complete the connection process.
    if state_str:match("connecting") or state_str:match("registering") or (state_str:match("registered") and not state_str:match("connected")) then
        return true
    end

    return false
end

-- ============================================================================
-- Main Execution Loop
-- ============================================================================
function M.start_daemon()
    local cooldown_until = 0
    local pending_iface_reset = false
    local was_in_cooldown = false

    -- Telemetry loop state
    local prev_ping_state = "UNKNOWN"
    local down_start_time = 0
    local bugreport_generated = false
    local rotation_counter = 0

    -- Restore persistent log to /tmp on startup if /tmp/pingcheck.log doesn't exist
    local check_tmp = io.open("/tmp/pingcheck.log", "r")
    if check_tmp then
        check_tmp:close()
    else
        M.execute("[ -f /root/pingcheck_history.log ] && cp /root/pingcheck_history.log /tmp/pingcheck.log")
    end
    
    log_ping_state("START", "Service started")

    -- Load existing metrics if they exist
    load_metrics_json()

    -- Prime the logs so we don't process historical startup logs
    M.check_logs()
    M.execute("logger -t modem_recovery 'Cellular Modem Auto-Recovery Daemon started successfully'")

    while true do
        -- Perform telemetry ping check
        local ping_ok, ping_detail = M.is_connection_stable()
        
        -- Discover current interface name for bug reports
        local mm_out_iface = M.exec("mmcli -m any 2>/dev/null")
        local current_iface = mm_out_iface:match("net%-ports:%s*([a-zA-Z0-9%-_]+)") or "wwan0"
        
        if ping_ok then
            local latency = ping_detail or "unknown ms"
            if prev_ping_state == "DOWN" then
                local downtime = os.time() - down_start_time
                log_ping_state("UP", string.format("%s | Downtime: %ds", latency, downtime))
                bugreport_generated = false
            else
                log_ping_state("UP", latency)
            end
            prev_ping_state = "UP"
        else
            local reason = ping_detail or "timeout"
            if prev_ping_state ~= "DOWN" then
                down_start_time = os.time()
                bugreport_generated = false
                log_ping_state("DOWN", reason)
            end
            log_ping_state("DOWN", reason)
            prev_ping_state = "DOWN"
            
            local downtime = os.time() - down_start_time
            if downtime >= 10 and not bugreport_generated then
                local drop_time_str = os.date("%Y-%m-%d %H:%M:%S", down_start_time)
                M.generate_bugreport(drop_time_str, current_iface)
                bugreport_generated = true
            end
        end
        
        -- Periodic rotation (every 200 ticks)
        rotation_counter = rotation_counter + 1
        if rotation_counter >= 200 then
            rotation_counter = 0
            rotate_logs()
        end

        -- Update state metrics at the start of every tick
        local mm_status, has_modem, m_state = get_current_metrics_state()
        
        if m_state ~= M.metrics.current_state then
            log_recovery(string.format("State changed: %s -> %s", M.metrics.current_state or "Unknown", m_state))
            M.metrics.current_state = m_state
            M.metrics.current_state_duration = 0
            log_metrics() -- Log metrics immediately on state change
            log_signal_metrics("State change to " .. m_state)
        else
            M.metrics.current_state_duration = (M.metrics.current_state_duration or 0) + M.CHECK_INTERVAL
            -- Periodically log metrics if in a non-connected state (every 60 seconds)
            if m_state ~= "Connected" and (M.metrics.current_state_duration % 60 == 0) then
                log_metrics()
            end
        end

        -- Periodically log signal metrics every 60 seconds
        if (M.metrics.current_state_duration % 60 == 0) then
            log_signal_metrics("Periodic check (" .. m_state .. ")")
        end
        
        M.metrics.modemmanager_status = mm_status
        M.metrics.modem_present = has_modem
        
        -- Accumulate total durations for states
        if m_state == "Missing" then
            M.metrics.total_missing_duration = (M.metrics.total_missing_duration or 0) + M.CHECK_INTERVAL
        elseif m_state == "Unregistered" then
            M.metrics.total_unregistered_duration = (M.metrics.total_unregistered_duration or 0) + M.CHECK_INTERVAL
        elseif m_state == "No IP" then
            M.metrics.total_no_ip_duration = (M.metrics.total_no_ip_duration or 0) + M.CHECK_INTERVAL
        elseif m_state == "No Ping" then
            M.metrics.total_no_ping_duration = (M.metrics.total_no_ping_duration or 0) + M.CHECK_INTERVAL
        elseif m_state == "Connected" then
            M.metrics.total_connected_duration = (M.metrics.total_connected_duration or 0) + M.CHECK_INTERVAL
        elseif m_state == "Disabled" then
            M.metrics.total_disabled_duration = (M.metrics.total_disabled_duration or 0) + M.CHECK_INTERVAL
        elseif m_state == "Denied" then
            M.metrics.total_denied_duration = (M.metrics.total_denied_duration or 0) + M.CHECK_INTERVAL
        end
        
        -- Save metrics to temp file
        write_metrics_json()

        local status_out = M.exec("ubus call network.interface.MODEM status 2>/dev/null")
        local is_autostart = status_out:match('"autostart":%s*true') ~= nil
        local now = os.time()
        if not is_autostart then
            -- Check if the interface is administratively disabled in UCI configuration
            local uci_disabled = M.exec("uci -q get network.MODEM.disabled")
            local uci_auto = M.exec("uci -q get network.MODEM.auto")
            local is_uci_disabled = uci_disabled:match("1") or uci_auto:match("0")

            if not is_uci_disabled then
                if now >= cooldown_until then
                    log_recovery("MODEM interface is manually stopped or disabled (autostart=false). Triggering recovery.")
                    M.execute("uci set network.MODEM.auto='1' && uci commit network")
                    local cooldown_duration, need_pending = M.run_recovery("interface", "Interface down (autostart=false)")
                    cooldown_until = now + cooldown_duration
                    pending_iface_reset = need_pending
                    was_in_cooldown = true
                end
            else
                -- Respect manual disable/stop: reset recovery counters and do not recover
                if (M.consecutive_recovery_count or 0) > 0 or (M.first_recovery_timestamp or 0) > 0 then
                    log_recovery("Interface manually disabled in UCI. Resetting recovery counters.")
                    M.consecutive_recovery_count = 0
                    M.first_recovery_timestamp = 0
                    M.reset_log_state()
                end
            end
        else
            local in_cooldown = now < cooldown_until
 
            if was_in_cooldown and not in_cooldown then
                -- We just transitioned out of cooldown! Flush all logs written during reset/reboot.
                log_recovery("COOLDOWN EXPIRED: FLUSHING LOG BUFFER TO PREVENT SELF-TRIGGERING")
                M.reset_log_state()
                M.check_logs()
                was_in_cooldown = false
            end
 
            if not in_cooldown then
                if pending_iface_reset then
                    local mm_out = M.exec("mmcli -m any")
                    local state_str = mm_out:match("state:%s*([^%\n]+)") or ""
                    local is_active = state_str:match("enabled") or state_str:match("searching") or state_str:match("registered") or state_str:match("connecting") or state_str:match("connected")
 
                    if M.is_connection_stable() then
                        log_recovery("COOLDOWN EXPIRED: CONNECTION IS ALREADY STABLE. CANCELLING PENDING INTERFACE RESET.")
                        pending_iface_reset = false
                        M.consecutive_recovery_count = 0
                        M.first_recovery_timestamp = 0
                        M.reset_log_state()
                        M.check_logs()
                    elseif is_active then
                        log_recovery("COOLDOWN EXPIRED: MODEM IS ACTIVE (" .. state_str .. "). CANCELLING PENDING INTERFACE RESET TO ALLOW REGISTRATION.")
                        pending_iface_reset = false
                    else
                        -- Perform the follow-up interface reset because the modem is stuck in disabled/failed/locked state
                        log_recovery("COOLDOWN EXPIRED: MODEM IS STUCK IN " .. (state_str ~= "" and state_str or "unknown") .. " STATE. FORCING INTERFACE RESET.")
                        M.execute("ifdown MODEM && sleep " .. M.POST_IFUP_WAIT .. " && ifup MODEM")
                        pending_iface_reset = false
                        cooldown_until = now + M.IFACE_RESTART_COOLDOWN
                        was_in_cooldown = true
                    end
                else
                    local trigger_action, reason = M.check_logs()
                    if not trigger_action then
                        trigger_action, reason = M.check_modem_state(ping_ok)
                    end
 
                    if trigger_action then
                        log_recovery("DETECTED DROP: TRIGGERED BY: " .. reason)
                        log_signal_metrics("Detected Drop: " .. reason)
                        log_recovery("WAITING 2 SECONDS TO VERIFY TRANSIENT RESTORATION...")
                        M.execute("sleep 2")
 
                        if M.is_connection_stable() or M.is_transient_restored() then
                            log_recovery("CONNECTION RECOVERED OR RESTORING ON ITS OWN. SKIPPING RECOVERY.")
                            M.consecutive_recovery_count = 0
                            M.reset_log_state()
                            M.check_logs()
                        else
                            log_recovery("CONNECTION UNSTABLE. PROCEEDING WITH RECOVERY.")
                            local cooldown_duration, need_pending = M.run_recovery(trigger_action, reason)
                            cooldown_until = now + cooldown_duration
                            pending_iface_reset = need_pending
                            was_in_cooldown = true
                        end
                    else
                        if M.consecutive_recovery_count > 0 or M.first_recovery_timestamp > 0 then
                            if M.is_connection_stable() then
                                M.consecutive_recovery_count = 0
                                M.first_recovery_timestamp = 0
                                log_recovery("CONNECTION IS STABLE: RESETTING RECOVERY COUNTER")
                            end
                        end
                    end
                end
            else
                was_in_cooldown = true
            end
        end
 
        M.execute("sleep " .. M.CHECK_INTERVAL)
    end
end

-- Return module or run loop
if not _TEST then
    M.start_daemon()
else
    return M
end

EOF

echo "Deploying /etc/init.d/modem_recovery..."
cat << \EOF > /etc/init.d/modem_recovery
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service() {
        procd_open_instance
        procd_set_param command /usr/bin/lua /usr/bin/modem_recovery_daemon.lua
        procd_set_param respawn
        procd_close_instance
}
EOF

# Stop, disable, and remove old standalone pingcheck service if it exists
if [ -f /etc/init.d/pingcheck ]; then
    echo "Stopping and disabling old standalone pingcheck service..."
    /etc/init.d/pingcheck stop 2>/dev/null
    /etc/init.d/pingcheck disable 2>/dev/null
    rm -f /etc/init.d/pingcheck /usr/bin/pingcheck.sh
fi

echo "Configuring permissions and services..."
chmod +x /usr/bin/modem_recovery_daemon.lua
chmod +x /etc/init.d/modem_recovery

echo "v0.1" > /etc/modem_recovery_version
/etc/init.d/modem_recovery enable
/etc/init.d/modem_recovery restart

echo "Cellular Modem Auto-Recovery Daemon installed and started successfully!"
