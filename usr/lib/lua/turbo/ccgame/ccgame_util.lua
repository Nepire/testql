#!/usr/bin/lua

local fs = require "nixio.fs"
local json = require "cjson"
require "turbo.ccgame.iface_ccgame"
local turbo = require "libturbo"
local XQCryptoUtil = require("xiaoqiang.util.XQCryptoUtil")

local px = require "posix"

local string, tonumber, pcall, type, table = string, tonumber, pcall, type, table

local cc_var_logpath = "/tmp/ccgame/log"
local cc_var_statuspath = "/tmp/ccgame/status.log"
local cc_var_gameinfo_path = "/tmp/ccgame/gameinfo.log"
local cc_var_baseinfo_path = "/tmp/ccgame/baseinfo.log"
local cc_var_userpath = "/tmp/ccgame/user.log"
local cc_lock_user = "/tmp/ccgame.user.lock"
local cc_lock_daemon = "/tmp/ccgame.daemon.lock"

local cc_var_vpnserver = "223.202.197.11"
local cc_var_serverurl = "http://games.nubesi.com/manager/ccgame"
local cc_var_conntrack_file = "/proc/net/nf_conntrack"
local cc_var_version = "0.1"

-- global function

-- init log
local px = require "posix"
px.openlog('ccgame', 'np', LOG_USER)
function logger(msg)
    if g_debug then
        print(msg)
    end
end

function ip2str(hex_ip)
    if not hex_ip then return "" end
    return turbo.ip2string(tonumber(hex_ip, 16))
end

function cc_func_get_serverurl()
    return cc_var_serverurl
end

function cc_func_exec_c(string)
    local res = io.popen(string)
    local tmpstr = res:read("*all")
    res:close()
    return string.match(tmpstr, "(.+)%c$") or ""
end

function cc_func_exec(command)
    --print("cc_func_exec:"..command)
    local pp = io.popen(command)
    local data = pp:read("*a")
    pp:close()

    return data
end

function cc_func_execl(command)
    --print("cc_func_execl:"..command)
    local pp = io.popen(command)
    local line = ""
    local data = {}

    while true do
        line = pp:read()
        if (line == nil) then break end
        data[#data + 1] = line
    end
    pp:close()

    return data
end

function cc_func_getpwd()
    local curr_dir = cc_func_exec_c("pwd")
    if not curr_dir then
        return false
    else
        return curr_dir
    end
end


split = function(str, pat, max, regex)
    pat = pat or "\n"
    max = max or #str

    local t = {}
    local c = 1

    if #str == 0 then
        return { "" }
    end

    if #pat == 0 then
        return nil
    end

    if max == 0 then
        return str
    end

    repeat
        local s, e = str:find(pat, c, not regex)
        max = max - 1
        if s and max < 0 then
            t[#t + 1] = str:sub(c)
        else
            t[#t + 1] = str:sub(c, s and s - 1)
        end
        c = e and e + 1 or #str + 1
    until not s or max < 0

    return t
end

trim = function(str)
    return str:gsub("^%s*(.-)%s*$", "%1")
end

-- class

CC_LOG = {
    isInit = false,
    log_init = function(self)

        if self.isInit then
            return
        end

        local cc_dir = fs.dirname(cc_var_logpath)
        if not fs.access(cc_dir) then
            fs.mkdirr(cc_dir)
        end

        self.isInit = true
    end,
    get_timestring = function(self)
        local t = os.date("*t")
        return string.format("%04d-%02d-%02d %02d:%02d:%02d", t.year, t.month, t.day, t.hour, t.min, t.sec)
    end,
    logging = function(self, content, level, caller)
        if g_debug then
            if not self.isInit then
                CC_LOG:log_init()
            end
            msg = "[" .. CC_LOG:get_timestring() .. "] " .. level .. " [" .. caller .. "] " .. content .. "\n"

            --print(msg)
            px.syslog(3, msg)
        end
    end,
    trace_caller = function(self)
        local caller = debug.getinfo(3)
        return fs.basename(caller.short_src) .. ":" .. caller.currentline
    end,
}

CC_LOG_ERROR = function(string)
    CC_LOG:logging(string, "E", CC_LOG:trace_caller())
end

CC_LOG_INFO = function(string)
    CC_LOG:logging(string, "I", CC_LOG:trace_caller())
end

CC_STATUS = {
    init = function(path)
        local cc_dir = fs.dirname(path)
        if not fs.access(cc_dir) then
            fs.mkdirr(cc_dir)
        end
        CC_LOG_INFO("CC_STATUS.init cc_dir=" .. cc_dir)
    end,
    get = function(path)
        if fs.access(path) then
            local data = fs.readfile(path, nil)
            data = XQCryptoUtil.binaryBase64Dec(data)
            --CC_LOG_INFO("CC_STATUS.get data="..data)
            return data
        else
            return nil
        end
    end,
    set = function(path, status)
        --CC_LOG_INFO("CC_STATUS.set status="..status)
        if status then
            CC_STATUS.init(path)

            status = XQCryptoUtil.binaryBase64Enc(status)
            if not fs.writefile(path, status) then
                CC_LOG_INFO("CC_STATUS.set fs.writefile failed cc_var_statuspath=" .. path)
            end
        end
    end,
    del = function(path)
        fs.unlink(path)
    end
}

CC_STATUS_SET = function(status)
    CC_STATUS.set(cc_var_statuspath, status)
end

CC_STATUS_GET = function()
    return CC_STATUS.get(cc_var_statuspath)
end

CC_GAMEINFO_SET = function(status)
    CC_STATUS.set(cc_var_gameinfo_path, status)
end

CC_GAMEINFO_GET = function()
    return CC_STATUS.get(cc_var_gameinfo_path)
end

CC_GAMEINFO_DEL = function()
    return CC_STATUS.del(cc_var_gameinfo_path)
end

CC_BASEINFO_SET = function(status)
    CC_STATUS.set(cc_var_baseinfo_path, status)
end

CC_BASEINFO_GET = function()
    return CC_STATUS.get(cc_var_baseinfo_path)
end

CC_BASEINFO_DEL = function()
    return CC_STATUS.del(cc_var_baseinfo_path)
end

CC_LOCK_FILE = {
    isLock = function(path)
        return fs.access(path)
    end,
    lock = function(path)
        return fs.writefile(path, "start")
    end,
    unlock = function(path)
        return fs.unlink(path)
    end
}

cc_func_user_isLock = function()
    return CC_LOCK_FILE.isLock(cc_lock_user)
end

cc_func_user_lock = function()
    return CC_LOCK_FILE.lock(cc_lock_user)
end

cc_func_user_unlock = function()
    return CC_LOCK_FILE.unlock(cc_lock_user)
end

cc_func_daemon_isLock = function()
    return CC_LOCK_FILE.isLock(cc_lock_daemon)
end

cc_func_daemon_lock = function()
    return CC_LOCK_FILE.lock(cc_lock_daemon)
end

cc_func_daemon_unlock = function()
    return CC_LOCK_FILE.unlock(cc_lock_daemon)
end


CC_IPADDRESS = {
    ipvalue = function(ip, m)

        if not ip or not m then
            return nil
        end

        mask = tonumber(m)
        if mask > 32 or mask < 1 then
            return nil
        end

        return libturbo.ipaddr_ipvalue(ip, m)
    end,
    parse = function(str)
        if not str then
            CC_LOG_INFO("CC_IPADDRESS.parse str is nil")
            return nil
        end

        local ipinfo = {}
        ipinfo.ip, ipinfo.port, ipinfo.mask = string.match(str, "(%d+.%d+.%d+.%d+):(%d+)/(%d+)")

        if ipinfo.ip and ipinfo.port and ipinfo.mask then
            CC_LOG_INFO("CC_IPADDRESS.parse " .. str .. ", mode 1:" .. ipinfo.ip .. "," .. ipinfo.port .. "," .. ipinfo.mask)
            ipinfo.n, ipinfo.v = libturbo.ipaddr_parse(ipinfo.ip .. "/" .. ipinfo.mask)
        else
            ipinfo.ip, ipinfo.mask = string.match(str, "(%d+.%d+.%d+.%d+)/(%d+)")
            if ipinfo.ip and ipinfo.mask then
                CC_LOG_INFO("CC_IPADDRESS.parse " .. str .. ", mode 3:" .. ipinfo.ip .. "," .. ipinfo.mask)
                ipinfo.n, ipinfo.v = libturbo.ipaddr_parse(str)
                ipinfo.port = "0"
            else
                ipinfo.ip = string.match(str, "(%d+.%d+.%d+.%d+)")
                if not ipinfo.ip then
                    return nil
                end

                CC_LOG_INFO("CC_IPADDRESS.parse " .. str .. ", mode 3:" .. ipinfo.ip)

                ipinfo.mask = 32
                ipinfo.port = 0
                ipinfo.n, ipinfo.v = libturbo.ipaddr_parse(str)
            end
        end

        return ipinfo
    end,
    calc = function(ip, masks)
        if not ip or not masks then
            return nil
        end

        local ipinfo = {}
        ipinfo.ip = string.match(ip, "(%d+.%d+.%d+.%d+)")
        if ipinfo.ip then
            ipinfo.v = CC_IPADDRESS.ipvalue(ipinfo.ip, 32)
        else
            return nil
        end

        local a
        for k, v in pairs(masks) do
            m = tonumber(v)
            if m ~= 32 then
                ipinfo[v] = CC_IPADDRESS.ipvalue(ipinfo.ip, m)
            end
        end

        return ipinfo
    end
}

-- ccgame function

function start_vpn_config(user, passwd, server_ip)
    if not user then
        return -11101
    end

    if not passwd then
        return -11102
    end

    if not server_ip then
        return -11103
    end

    vpnOn(server_ip, user, passwd)

    return 0
end

function stop_vpn_config()
    vpnOff()

    return 0
end

function CCFUNC_GET_VPN_STATE()
    local cmd = getVpnStatCmd()
    --ifconfig l2tp-ccgame 2>/dev/null
    CC_LOG_INFO("CCFUNC_GET_VPN_STATE cmd=" .. cmd)
    local res = {}
    local ps = cc_func_execl(cmd)
    if not ps then
        return -1
    end

    local isMatch = false
    for i, line in pairs(ps) do
        CC_LOG_INFO("CCFUNC_GET_VPN_STATE i=" .. i .. ", line=" .. line)
        if i == 1 then
            --i:1, l2tp-ccgame Link encap:Point-to-Point Protocol
            isMatch = string.find(line, "l2tp%-ccgame")
            if not isMatch then
                break
            end
        elseif i == 2 then
            --i:2, line:          inet addr:10.11.0.10  P-t-P:10.10.0.1  Mask:255.255.255.255
            res.ip, res.ptp, res.mask = string.match(line, "inet addr:(%d+.%d+.%d+.%d+)%s+P%-t%-P:(%d+.%d+.%d+.%d+)%s+Mask:(%d+.%d+.%d+.%d+)")
        elseif i == 3 then
            --i:3, line:          UP POINTOPOINT RUNNING NOARP MULTICAST  MTU:1404  Metric:1
            res.mtu, res.metric = string.match(line, "MTU:(%w+)%s+Metric:(%w+)")
        elseif i == 4 then
            --i:4, line:          RX packets:114 errors:0 dropped:0 overruns:0 frame:0
            res.rx_packets, res.rx_errors, res.rx_dropped, res.rx_overruns, res.rx_frame = string.match(line, "packets:(%d+)%s+errors:(%d+)%s+dropped:(%d+)%s+overruns:(%d+)%s+frame:(%d+)")
        elseif i == 5 then
            --i:5, line:          TX packets:115 errors:0 dropped:0 overruns:0 carrier:0
            res.tx_packets, res.tx_errors, res.tx_dropped, res.tx_overruns, res.tx_carrier = string.match(line, "packets:(%d+)%s+errors:(%d+)%s+dropped:(%d+)%s+overruns:(%d+)%s+carrier:(%d+)")
        elseif i == 6 then
            --i:6, line:          collisions:0 txqueuelen:3
            res.collisions, res.txqueuelen = string.match(line, "collisions:(%d+)%s+txqueuelen:(%d+)")
        elseif i == 7 then
            --i:7, line:           RX bytes:830 (830.0 B)  TX bytes:844 (844.0 B)
            res.rx_bytes, res.tx_bytes = string.match(line, "bytes:(%d+).+:(%d+)")
        end
    end

    local vpn_state = {}
    if isMatch then
        vpn_state.status = 1
        vpn_state.ip = res.ip and res.ip or ""
        --[[
        local baseinfo = cc_func_get_baseinfo()
        if baseinfo then
          vpn_state.starttime = baseinfo.vpnstart and baseinfo.vpnstart or "-1"
          if baseinfo.vpnstart then
            vpn_state.duration = os.time() - tonumber(baseinfo.vpnstart)
          else
            vpn_state.duration = -1
          end
        else
          vpn_state.vpnstart = -1
          vpn_state.duration = -1
        end
        --]]
        vpn_state.rx = res.rx_bytes and res.rx_bytes or "-1"
        vpn_state.tx = res.tx_bytes and res.tx_bytes or "-1"
        return 0, vpn_state
    else
        vpn_state.status = 0
        return -2, vpn_state
    end
end

function cc_ping_vpn_list(ips)
    if not ips then
        return nil
    end
    local count = 4

    local res = {}
    for i, v in pairs(ips) do
        local myip, myport = string.match(v, "(%d+.%d+.%d+.%d+):(%d+)")
        if not myip or not myport then
            myip = string.match(v, "(%d+.%d+.%d+.%d+)")
            if myip then
                myport = 0
            else
                myip = nil
                myport = nil
            end
        end

        if myip and myport then
            local cmd = ""
            if byvpn then
                cmd = "tping -q " .. myip .. " -p " .. myport .. " -i l2tp-ccgame"
            else
                cmd = "tping -q " .. myip .. " -p " .. myport
            end
            CC_LOG_INFO("cc_func_ping_state before cmd:" .. cmd .. "$$")

            local ps = cc_func_exec(cmd)
            if not ps then
                --res[myip]=nil
            else
                CC_LOG_INFO("cc_func_ping_state cmd:" .. cmd .. ", ret:" .. ps .. "$$")

                local pingState = {}
                --type=ICMP-0,seq=0,ttl=64,ts=0.42 ms, ts2=0.32 ms
                pingState.ttl = string.match(ps, "ttl=(%d+)")
                --ICMP, 4 sent, 4 received, 0 lost, avg=0.34 ms
                pingState.lose = string.match(ps, "(%d+)%%%s+lost,")
                --round-trip min/avg/max = 0.789/0.795/0.801 ms
                pingState.rtt = string.match(ps, "avg=(%d+.%d*) ms")
                if tonumber(myport) ~= 0 then
                    pingState.ip = myip .. ":" .. myport
                else
                    pingState.ip = myip
                end
                table.insert(res, pingState)
            end
        end
    end

    --print(json.encode(res))
    return res
end

function cc_func_ping_state(ips, byvpn, count)
    if not ips then
        return nil
    end
    if type(ips) ~= "table" then
        return nil
    end

    if not count then
        count = 4
    end

    local res = {}
    for i, v in pairs(ips) do
        local myip, myport = string.match(v, "(%d+.%d+.%d+.%d+):(%d+)")
        if not myip or not myport then
            myip = string.match(v, "(%d+.%d+.%d+.%d+)")
            if myip then
                myport = 0
            else
                myip = nil
                myport = nil
            end
        end

        if myip and myport then
            local cmd = ""
            --tping IP -p PORT -i l2tp-ccgame
            if byvpn then
                cmd = "tping -q " .. myip .. " -p " .. myport .. " -i l2tp-ccgame"
            else
                cmd = "tping -q " .. myip .. " -p " .. myport
            end
            CC_LOG_INFO("cc_func_ping_state before cmd:" .. cmd .. "$$")

            local ps = cc_func_exec(cmd)
            if not ps then
                --res[myip]=nil
            else
                CC_LOG_INFO("cc_func_ping_state cmd:" .. cmd .. ", ret:" .. ps .. "$$")

                local pingState = {}
                --type=ICMP-0,seq=0,ttl=64,ts=0.42 ms, ts2=0.32 ms
                pingState.ttl = string.match(ps, "ttl=(%d+)")
                --ICMP, 4 sent, 4 received, 0 lost, avg=0.34 ms
                pingState.lose = string.match(ps, "(%d+)%%%s+lost,")
                --round-trip min/avg/max = 0.789/0.795/0.801 ms
                pingState.rtt = string.match(ps, "avg=(%d+.%d*) ms")
                if tonumber(myport) ~= 0 then
                    pingState.ip = myip .. ":" .. myport
                else
                    pingState.ip = myip
                end
                table.insert(res, pingState)
            end
        end
    end

    return res
end

-- in param: downloaded iplist string txt
function cc_func_route_add(ipset_name, ips)
    if not ips then
        return -1
    end

    local res = {}
    -- open turbo socket for routing ip importing
    if not turbo.ipset_open() then
        return -1
    end

    turbo.ipset_add_iplist(ipset_name, ips)

    -- close turbo socket
    turbo.ipset_close();

    return 0
end

function cc_func_route_delete(ipset_name, ips)
    if not ips then
        CC_LOG_INFO("cc_func_route_delete input err")
        return nil
    end
    if type(ips) ~= "table" then
        CC_LOG_INFO("cc_func_route_delete input fmt err")
        return nil
    end

    local res = {}
    -- open turbo socket for routing ip importing
    if not turbo.ipset_open() then
        CC_LOG_INFO("cc_func_route_delete turbo.ipset_open() err")
        return nil
    end

    for i, v in pairs(ips) do
        if v and v.ip and v.mask then
            CC_LOG_INFO("cc_func_route_delete " .. ipset_name .. " del:" .. v.ip)
            turbo.ipset_del_ip(ipset_name, v.ip);
            -- refresh conntrack to enable old connection
            turbo.del_ip_conntrack(v.ip);
        end
    end

    -- close turbo socket
    turbo.ipset_close();

    return true
end


local function cc_func_find_ip(dstinfo, ipinfos)
    if not dstinfo or not ipinfos then
        --CC_LOG_INFO("dst or ipinfos is NULL")
        return false
    end

    for k, v in pairs(ipinfos) do
        --CC_LOG_INFO("dst: " .. k .. ":" ..json.encode(v) .. ",dstinfo=" .. json.encode(dstinfo))
        if k and v.n and dstinfo and dstinfo.v then
            if v.n == dstinfo.v then
                return k
            end
        end
    end
    return false
end

function cc_func_get_connected_iplist(ipinfo, masks)
    local cmd = "awk '/dst=/ {for(i=1;i<=NF;i++) if($i ~ /dst=/)  print $i}' " .. cc_var_conntrack_file .. " | awk -F '=' '{print $2}' | sort -n | uniq "
    CC_LOG_INFO("cc_func_get_connected_ips cmd:[" .. cmd .. "]")
    local ps = cc_func_execl(cmd)
    if not ps then
        return nil
    end

    local dstlist = {}
    for i, line in pairs(ps) do
        if line and trim(line) ~= "" then
            dstlist[line] = CC_IPADDRESS.calc(line, masks)
        end
    end

    local speedlist = {}
    for k, v in pairs(dstlist) do
        --CC_LOG_INFO("dstlist k:"..k..", v:"..json.encode(v))
        local isFinded = cc_func_find_ip(v, ipinfo)
        if isFinded then
            speedlist[#speedlist + 1] = isFinded
        end
    end
    CC_LOG_INFO("cc_func_get_connected_ips speedlist:" .. json.encode(speedlist))

    return speedlist
end

local function cc_func_get_connected_ips(ipinfos, masks)

    local speedlist = cc_func_get_connected_iplist(ipinfo, masks)
    local speedinfolist = cc_func_ping_state(speedlist, true)
    local qosInfo = {}
    if speedinfolist then
        qosInfo.info = speedinfolist
        local gameinfo = cc_func_get_gameinfo()
        if gameinfo and gameinfo.gameid then
            qosInfo.gameid = gameinfo.gameid
        else
            qosInfo.gameid = ""
        end
    end

    return qosInfo
end

function cc_func_save_gameinfo(gamelist, gameid, regionid, version)
    if not gamelist then
        CC_LOG_ERROR("cc_func_save_gamelist input err")
        return nil
    end

    local gameinfo = {}
    gameinfo.gameid = gameid
    gameinfo.regionid = regionid
    gameinfo.version = version and version or "0"
    gameinfo.mask = {}
    gameinfo.info = {}
    --[[
    for i, v in pairs(gamelist) do
      local r = CC_IPADDRESS.parse(v)
      if r then
        gameinfo.info[v] = r
        if r.mask then
          gameinfo.mask[r.mask]=r.mask
        end
      end
    end
    --]]

    CC_GAMEINFO_SET(json.encode(gameinfo))
    return gameinfo
end

function cc_func_get_gameinfo()
    local gameinfo_json = CC_GAMEINFO_GET()
    if not gameinfo_json then
        CC_LOG_ERROR("cc_func_get_gamelist CC_GAMEINFO_GET() err")
        return nil
    end

    local ret, gameinfo = pcall(function() return json.decode(gameinfo_json) end)
    if not ret or not gameinfo then
        CC_LOG_ERROR("cc_func_get_gamelist CC_GAMEINFO_GET() decode err: " .. gameinfo_json)
        return nil
    end

    return gameinfo
end

function cc_func_save_baseinfo(baseinfo)
    if not baseinfo then
        return nil
    end

    local ret, baseinfo_json = pcall(function() return json.encode(baseinfo) end)
    if not ret then
        return nil
    end
    CC_BASEINFO_SET(baseinfo_json)
    return baseinfo
end

function cc_func_get_baseinfo()
    local baseinfo_json = CC_BASEINFO_GET()
    if not baseinfo_json then
        return nil
    end

    local ret, baseinfo = pcall(function() return json.decode(baseinfo_json) end)
    if not ret or not baseinfo then
        return nil
    end

    return baseinfo
end

function cc_func_get_qos(game)
    if not game then
        CC_LOG_ERROR("cc_func_get_qos input err")
        return nil
    end

    if not game.info or not game.mask then
        CC_LOG_ERROR("cc_func_get_qos stuct err")
        return nil
    end

    local pingInfo = cc_func_get_connected_ips(game.info, game.mask)
    if pingInfo and game.gameid then
        pingInfo.gameid = game.gameid
    end
    return pingInfo
end

function cc_func_generate_ccserver_cmd_head(cmdid)

    local baseinfo = cc_func_get_baseinfo()
    if not baseinfo then
        return nil
    end

    local cmdhead = {}
    cmdhead.cmdid = cmdid
    cmdhead.uid = baseinfo.uid and baseinfo.uid or "-1"
    cmdhead.version = baseinfo.version and baseinfo.version or "-1"
    cmdhead.devicetype = baseinfo.devicetype and baseinfo.devicetype or "-1"
    cmdhead.usertype = baseinfo.usertype and baseinfo.usertype or "-1"
    cmdhead.time = os.time()
    cmdhead.data = {}

    return cmdhead
end

function cc_func_ccserver_request(cmdid, para, refCmd)
    if not cmdid or not para then
        return -10010
    end

    local cmdhead = {}
    cmdhead.cmdid = cmdid
    cmdhead.uid = para.uid and para.uid or "-1"
    cmdhead.version = para.version and para.version or "-1"
    cmdhead.devicetype = para.devicetype and para.devicetype or "-1"
    cmdhead.usertype = para.usertype and para.usertype or "-1"
    cmdhead.time = para.time
    cmdhead.data = para.data

    local cmd = string.format('curl -H "Content-type: application/json" -X POST --data \'%s\' %s  2>/dev/null ', json.encode(cmdhead), cc_func_get_serverurl())
    logger("cc_func_ccserver_request cmd " .. cmd)

    local retCurl, curl_ret = pcall(cc_func_exec, cmd)
    if not retCurl or not curl_ret then
        return -11006
    end

    if cmdid == 7 then
        return 0, curl_ret
    end

    curl_ret = trim(curl_ret)
    if not retCurl or not curl_ret or curl_ret == "" then
        CC_LOG_INFO("cc_func_ccserver_request curl faild:" .. curl_ret .. "$$")
        return -11006
    end

    CC_LOG_INFO("cc_func_ccserver_request curl success.")
    local ret
    local curl_ret_sturct = { code = 0 }

    ret, curl_ret_struct = pcall(function() return json.decode(curl_ret) end)

    if not ret or not curl_ret_struct then
        return -11007
    end

    if not curl_ret_struct.code then
        return -11007
    end

    if curl_ret_struct.code ~= 0 then
        return curl_ret_struct.code
    end

    return 0, curl_ret_struct.data
end

function cc_func_get_vpn_server_ip(cmd, vpnlistInfo)

    local data = cmd
    if vpnlistInfo then
        if not cmd.data then
            cmd.data = {}
        end
        cmd.data.info = vpnlistInfo
    end
    local ret_v, ret_data = cc_func_ccserver_request(3, cmd)
    if ret_v ~= 0 then
        CC_LOG_INFO("cc_func_get_vpn_server_ip cc_func_ccserver_request return:" .. ret_v .. ".")
        return nil
    end

    if not ret_data or not ret_data.serverip then
        CC_LOG_INFO("cc_func_get_vpn_server_ip cc_func_ccserver_request data is empty.")
        return nil
    end

    return ret_data.serverip
end

function cc_func_get_vpn_server_list(cmd)
    local data = cmd
    local ret_v, ret_data = cc_func_ccserver_request(5, data)
    if ret_v ~= 0 then
        CC_LOG_INFO("cc_func_get_vpn_server_list cc_func_ccserver_request return:" .. ret_v .. ".")
        return nil
    end

    if not ret_data or not ret_data.iplist then
        CC_LOG_INFO("cc_func_get_vpn_server_list cc_func_ccserver_request data is empty.")
        return nil
    end

    return ret_data.iplist
end
