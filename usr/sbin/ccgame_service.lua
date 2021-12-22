#!/usr/bin/lua
--[[
turbo-ccgame service deamon program
Author: MIWIFI@2017
--]]

local uci = require 'luci.model.uci'
local fs = require "nixio.fs"
local LuciUtil = require("luci.util")
local LuciJson = require("cjson")
local XQCCGame = require("turbo.ccgame.ccgame_interface")
local px = require "posix"
local turbo = require "libturbo"
local math = require "math"

require("turbo.ccgame.ccgame_util")
g_debug = nil
--g_debug = 1

local x = uci.cursor()
local E_OK = 'OK';
local E_NOK = 'UNKNOWN';
local E_VIP = 'VIP';
local E_NON_VIP_OK = 'NON_VIP_OK';
local E_NON_VIP_NOK = 'NON_VIP_NOK';


local ipset_ccgame_chk = 'ccgame_chk'
local ipset_name = 'ccgame'

--read uci config
local function read_cfg(conf, type, opt, default)
    local val = x:get(conf, type, opt) or default
    return val or ""
end

local function write_cfg(conf, type, opt, value)
    x:set(conf, type, opt, value)
    x:commit(conf)
end

local function logerr(msg)
    if g_debug then
        print(msg)
    else
        px.syslog(3, msg)
    end
end


-- init uloop
local uloop = require "uloop"
uloop.init()

-- init ubus
local ubus = require "ubus"
local conn = ubus.connect()
if not conn then
    logger("init ubus failed.")
    os.exit(-1)
end


function get_connected_iplist(kill)
    local cmd = "grep ASSURED /proc/net/nf_conntrack "
    local ps = cc_func_execl(cmd)
    if not ps then
        return nil, nil
    end

    local dstlist = {}
    for i, line in pairs(ps) do
        local _, _, dip, dport = string.find(line, "dst=([0-9.]+) sport=%d+ dport=(%d+)")
        if dip and dport then
            dstlist[dip] = dport
        end
    end

    -- get game ips from ipset
    ps = cc_func_execl("ipset -L -q ccgame ")
    if not ps then
        return nil, nil
    end

    local onlineIP, onlinePort
    for i, line in pairs(ps) do
        if line and LuciUtil.trim(line or '') ~= "" and dstlist[line] then
            if not onlineIP or not onlinePort then
                onlineIP = line
                onlinePort = dstlist[line]
                -- just get one valid online IP/PORT
                if not kill then
                    break
                end
            end
            if kill then
                logger("****clean conntrack for IP: " .. line)
                LuciUtil.exec('echo ' .. line .. ' > /proc/net/nf_conntrack')
            end
        end
    end

    return onlineIP, onlinePort
end


local para = { devicetype = 1101, version = '0.1', usertype = '2' }

-- timer for ping target periodly
local ping_timer
-- get current used ip target periodly
local online_ip_timer
--
local get_vpnserver_ip_timer
local get_vpnstate_timer
local start_turbo_game_timer
local check_vip_timer

-- upload info to cc
local upload_log2cc_timer
local check_cc_gamelist_timer

-- update_LPG_iplist
local update_LPG_iplist_timer

-- check_vip_expired_remind
local check_vip_expired_remind_timer
local report_LPG_gameid_timer

GAME_INFO = {
    usageInfo = {
        info = {},
        vip = E_NOK,
        vip_expire_days = 0,
        nonvip_left_count = 0,
    },
    latestGameInfo = {
        gameList = {}, -- timestamp as key
        readInterval = 10 * 60 * 1000, -- 10min
    },
    vpnStatus = 0, -- 0: not running, 1: running
    ruleStatus = 0, -- 0: not loaded, 1: loaded done
    vpnInfo = nil,
    gameid = -1, -- -1: no game, >=0 : gameid
    regionid = -1,
    game_version = -1,
    leftPingCount = 0, -- invoke will fill leftPingCount = 5, ping will stop if leftPingCount = 0
    pingInfo = nil,
    data = {},
    online_ip = nil,
    online_port = nil,
    detect_ip = '',
    detect_port = 0,
    byvpn = 1,
    ping_interval = 5 * 1000, -- 5s
    online_ip_interval = 3 * 60 * 1000, -- 3min
    uid = nil,
    passwd = nil,
    passwd_try_num = 3,
    vpn_server = nil,
    vpn_server_try_num = 3,
    get_vpnstate_interval = 1000,
    get_vpnstate_try_num = 10,
    upload_log2cc_interval = 30 * 60 * 1000, --30 min

    check_cc_gamelist_interval = 12 * 60 * 60 * 1000, --check ccgame iplist per 12 hours

    update_LPG_iplist_interval = 12 * 60 * 60 * 1000, -- per 12hours get iplist from cc

    check_vip_expired_remind_interval = 9 * 60 * 60 * 1000, -- per 9hours  check vip expired reminder

    report_LPG_gameid_interval = 30 * 60 * 1000, -- per 30 min report LPG gameid

    get_vpnserver_ip_timer_interval = 0,

    -- get qos info for debugging
    get_ppplog = function()
        local output = LuciUtil.exec('cat /tmp/pppoe.log 2>/dev/null')
        return output
    end,

    -- ccgame upload info
    upload_log2cc = function(isAct)
        local data = para
        if not isAct then
            upload_log2cc_timer:set(GAME_INFO.upload_log2cc_interval)
            -- just return if turbo_ccgame not enabled or vpn not start
            if GAME_INFO.gameid < 0 or GAME_INFO.vpnStatus == 0 then
                return
            end
        end

        if GAME_INFO.vpnInfo or isAct then
            data.data = {}
            -- set if it's user trigger
            data.data.user = isAct
            data.data.vpnserver = GAME_INFO.vpn_server
            data.data.vpnstatus = GAME_INFO.vpnInfo
            data.data.qos = GAME_INFO.pingInfo
            data.data.online = (GAME_INFO.online_ip or '0') .. ':' .. (GAME_INFO.online_port or '0')
            data.uid = GAME_INFO.uid
            data.data.passwd = ''

            logger("log2cc ====> " .. LuciJson.encode(data))
            local ret_v, ret_data = cc_func_ccserver_request(2, data)
        end
    end,

    -- ccgame download info
    check_cc_gamelist = function()
        check_cc_gamelist_timer:set(GAME_INFO.check_cc_gamelist_interval)
        -- just return if turbo_ccgame not enabled or vpn not start
        if GAME_INFO.gameid < 0 or GAME_INFO.vpnStatus == 0 then
            return
        end

        local data = para
        data['gameid'] = GAME_INFO.gameid

        local ret_v, ret_data = cc_func_ccserver_request(4, data)
        if ret_v ~= 0 or not ret_data.version then
            return
        end

        if tostring(ret_data.version) == tostring(GAME_INFO.game_version) then
            return
        end

        logger("different cc game iplist version. try to download new version.")

        local data2 = para
        data2['gameid'] = GAME_INFO.gameid
        data2['regionid'] = GAME_INFO.regionid
        local ret_v2, ret_data2 = cc_func_ccserver_request(7, data2)
        if ret_v2 ~= 0 or not ret_data2 then
            return
        end

        local code = apply_route_new_game(ipset_name, ret_data2)

        -- update current game iplist version
        GAME_INFO.game_version = ret_data.version
    end,

    -- download game iplist
    download_game_speedup_iplist = function(gameid, regionid)
        local cmd = para
        cmd.time = os.time()
        cmd.uid = GAME_INFO.uid
        cmd.data = { gameid = gameid, regionid = regionid }
        local ret_v, ret_data = cc_func_ccserver_request(7, cmd)
        if ret_v ~= 0 or not ret_data then
            return -1, nil
        end
        return 0, ret_data
    end,

    -- mask as 1st-dimension, ip as 2nd-dimension
    MASK_IP_MAPPING = {},
    -- read latest played game
    update_LPG_iplist = function()
        logger("func: update_LPG_iplist")
        update_LPG_iplist_timer:set(GAME_INFO.update_LPG_iplist_interval)
        -- check if user is VIP
        if GAME_INFO.usageInfo.vip == E_VIP then
            return
        end

        -- download hot gamelist
        GAME_INFO.get_hot_gamelist()

        -- download all gamelist info
        local cmd = "matool --method api_call --params /device/vip/ccgame/list '{}'"
        local output = LuciUtil.trim(LuciUtil.exec(cmd))
        if not output or output == "" then
            return
        end

        local ret, gamedata = pcall(function() return LuciJson.decode(output) end)
        if not ret or not gamedata or not gamedata.data or not gamedata.data.result then
            logerr("matool get /device/vip/ccgame/list failed.")
            return
        end

        local ret, allGameList = pcall(function() return LuciJson.decode(gamedata.data.result) end)
        if not ret then
            logerr("matool encode /device/vip/ccgame/list get all gamelist failed.")
            return
        end

        --get topN game
        local topNGameList = GAME_INFO.get_topN_gamelist()
        for i = 1, #topNGameList do
            local gameid = tostring(topNGameList[i])
            GAME_INFO.topNGameList[gameid] = {}
        end

        --clean old MASK_IP_MAPPING
        GAME_INFO.MASK_IP_MAPPING = {}
        local strIPMask
        for _, v in pairs(allGameList.data or {}) do
            local id = tostring(v.game_id)
            local name = v.game_name
            local icon = v.game_icon_url
            local name_icon = name .. ',' .. icon
            for _, n in pairs(v.game_regionlist) do
                if #n.brief_ip_list > 0 then
                    local tmp = ""
                    for _, j in pairs(n.brief_ip_list) do
                        -- get subnet
                        strIPMask = j.brief_ip .. '/' .. j.brief_mask
                        local netip, mask = libturbo.ipaddr_parse(strIPMask)
                        local strNetip, strMask = tostring(netip), tostring(mask)
                        if not GAME_INFO.MASK_IP_MAPPING[strMask] then
                            GAME_INFO.MASK_IP_MAPPING[strMask] = {}
                        end

                        if GAME_INFO.MASK_IP_MAPPING[strMask][strNetip] then
                            GAME_INFO.MASK_IP_MAPPING[strMask][strNetip].id[id] = name_icon
                        else
                            GAME_INFO.MASK_IP_MAPPING[strMask][strNetip] = { ip = j.brief_ip, mask = j.brief_mask, id = {} }
                            GAME_INFO.MASK_IP_MAPPING[strMask][strNetip].id[id] = name_icon
                        end
                    end
                end
            end
            -- fill hot game list
            if GAME_INFO.hotGameList[id] then
                GAME_INFO.hotGameList[id] = { id = id, name = name, icon = icon }
            end

            -- fill topN game list
            if GAME_INFO.topNGameList[id] then
                GAME_INFO.topNGameList[id] = { id = id, name_icon = name_icon }
            end
        end


        if #topNGameList > 0 then
            -- only match configured ip for played game.
            logger("try to apply ip-list for game matching, ip: ")
            clean_route_rule(ipset_ccgame_chk)
            for i = 1, #topNGameList do
                local gameid = topNGameList[i]
                logger("game id: " .. gameid)
                local ret, list = GAME_INFO.download_game_speedup_iplist(gameid, 0)
                if ret == 0 and list then
                    apply_route_new_game(ipset_ccgame_chk, list, true)
                end
            end
            GAME_INFO.useTopNGameList = true
        else
            GAME_INFO.useTopNGameList = false
            -- apply ipset ccgame_chk
            -- flush ipset rule before apply new entry
            clean_route_rule(ipset_ccgame_chk)

            -- open ipset
            if not turbo.ipset_open() then
                return
            end

            for k_, k in pairs(GAME_INFO.MASK_IP_MAPPING) do
                for v_, v in pairs(k) do
                    --print(k_ .. ',' .. v_ .. LuciJson.encode(v))
                    if v.ip and v.mask then
                        turbo.ipset_add_net(ipset_ccgame_chk, v.ip, tonumber(v.mask))
                    else
                    end
                end
            end

            -- close ipset
            turbo.ipset_close()
        end
    end,

    -- latest played game list
    game_iplist_mapping = {},
    read_LPG_gameid = function()
        logger("func: read_LPG_gameid")
        local rdata = {}
        local data = {}
        local nCount = 0
        table.sort(GAME_INFO.game_iplist_mapping)
        for strID, strName in pairs(GAME_INFO.game_iplist_mapping) do
            if nCount < 3 then
                local name = split(strName, ',')
                if name and name[1] and name[2] and name[3] then
                    data[#data + 1] = { ts = name[1], id = strID, name = name[2], icon = name[3] }
                end
            else
                GAME_INFO.game_iplist_mapping[strID] = nil
            end
            nCount = nCount + 1
        end

        -- set latest played game in json layer1 for push feature
        if #data > 0 and data[1] and data[1].name then
            rdata['cur_game'] = data[1].name
        end

        if #data < 3 then
            for _, v in pairs(GAME_INFO.hotGameList) do
                data[#data + 1] = { ts = 0, id = v.id, name = v.name, icon = v.icon }
                if #data >= 3 then
                    break
                end
            end
        end
        --print(LuciJson.encode(data))
        rdata['games'] = data
        return rdata
    end,

    -- read /proc/xt_recent/ccgame
    report_LPG_gameid = function()
        logger("func: report_LPG_gameid")
        -- report LPG periodly
        report_LPG_gameid_timer:set(GAME_INFO.report_LPG_gameid_interval)

        local cmd = 'cat /proc/net/xt_recent/ccgame 2>/dev/null'
        local out = cc_func_execl(cmd)
        if not out or out == '' then
            return
        end

        local curTs = os.time()
        local newEvent

        for _, line in pairs(out) do
            local _, _, strIP = string.find(line, 'src=([0-9.]+)')
            if strIP then
                if GAME_INFO.useTopNGameList then
                    for k, v in pairs(GAME_INFO.topNGameList) do
                        GAME_INFO.game_iplist_mapping[v.id] = tostring(curTs) .. ',' .. v.name_icon
                        newEvent = 1
                    end
                    break
                else
                    for mask_, v_ in pairs(GAME_INFO.MASK_IP_MAPPING) do
                        local ip_, _ = libturbo.ipaddr_parse(strIP .. '/' .. mask_)
                        ip_ = tostring(ip_)
                        if GAME_INFO.MASK_IP_MAPPING[mask_][ip_] then
                            for id, name_icon in pairs(GAME_INFO.MASK_IP_MAPPING[mask_][ip_].id or {}) do
                                GAME_INFO.game_iplist_mapping[id] = tostring(curTs) .. ',' .. name_icon
                                newEvent = 1
                            end
                        end
                    end
                end
            end
        end

        -- new event coming
        if newEvent then
            local type = 1401
            local data = GAME_INFO.read_LPG_gameid()

            -- send out notify
            if data then
                logger('report event.........' .. LuciJson.encode(data))
                GAME_INFO.send_pop_notify(type, data)
            end
        end

        -- clean xt_recent
        LuciUtil.exec('echo / > /proc/net/xt_recent/ccgame 2>/dev/null')
    end,

    -- notify
    send_pop_notify = function(type, data)
        if conn and data then
            --logger(LuciJson.encode({ type = type, data = (data or {}) }))
            --print("encode-json: [" .. LuciJson.encode(data) .. "]")
            local strData = LuciJson.encode(data)
            local res = conn:call("eventservice", "general_event_notify", { type = type, data = strData })
            if not res or res.code ~= 0 then
                logerr("ubus send general event_notify failed. " .. LuciJson.encode(res))
                return nil
            else
                logger("ubus eventservice return: " .. LuciJson.encode(res))
            end
            return res
        end
        return nil
    end,

    -- VIP user expired reminder
    check_vip_expired_remind = function()
        check_vip_expired_remind_timer:set(GAME_INFO.check_vip_expired_remind_interval)
        GAME_INFO.check_vip_info()

        -- VIP expiry check
        if GAME_INFO.usageInfo.vip == E_VIP and GAME_INFO.usageInfo.info.otherInfo and GAME_INFO.usageInfo.info.otherInfo.vipExpiredRemind then
            local type = 1402
            logger("days_to_expire: " .. GAME_INFO.usageInfo.vip_expire_days)
            if GAME_INFO.usageInfo.vip_expire_days == GAME_INFO.usageInfo.info.otherInfo.vipExpiredRemind then
                local data = { days_to_expire = GAME_INFO.usageInfo.vip_expire_days }
                GAME_INFO.send_pop_notify(type, data)
            end
        end
    end,

    -- init fun
    init = function()
        math.randomseed(os.time())

        -- read game id from /etc/config/turbo
        local gameid = tonumber(read_cfg('turbo', 'ccgame', 'gameid', '0')) or 0
        local regionid = tonumber(read_cfg('turbo', 'ccgame', 'regionid', '0')) or 0
        local rule = tonumber(read_cfg('turbo', 'ccgame', 'ruleStatus', '0')) or 0

        -- get passport
        GAME_INFO.get_passport()

        -- check VIP
        check_vip_timer = uloop.timer(GAME_INFO.check_vip_info)
        GAME_INFO.check_vip_info()

        -- check VPN
        get_vpnstate_timer = uloop.timer(GAME_INFO.read_vpnstate)
        GAME_INFO.read_vpnstate()

        -- get vpn server
        get_vpnserver_ip_timer = uloop.timer(GAME_INFO.get_vpnserver)
        get_vpnserver_ip_timer:set(math.random(3000, 2 * 60 * 1000))

        -- ping worker
        ping_timer = uloop.timer(GAME_INFO.ping_worker)
        ping_timer:set(500)

        -- get online ip worker
        online_ip_timer = uloop.timer(GAME_INFO.online_ip_check)
        online_ip_timer:set(1000)

        -- upload log2cc
        upload_log2cc_timer = uloop.timer(GAME_INFO.upload_log2cc)
        upload_log2cc_timer:set(GAME_INFO.upload_log2cc_interval)

        -- check cc gamelist updating
        check_cc_gamelist_timer = uloop.timer(GAME_INFO.check_cc_gamelist)
        check_cc_gamelist_timer:set(2 * 60 * 1000)

        update_LPG_iplist_timer = uloop.timer(GAME_INFO.update_LPG_iplist)
        --update_LPG_iplist_timer:set(3 * 60 * 1000)
        update_LPG_iplist_timer:set(1300)

        report_LPG_gameid_timer = uloop.timer(GAME_INFO.report_LPG_gameid)
        report_LPG_gameid_timer:set(GAME_INFO.report_LPG_gameid_interval)

        check_vip_expired_remind_timer = uloop.timer(GAME_INFO.check_vip_expired_remind)
        check_vip_expired_remind_timer:set(GAME_INFO.check_vip_expired_remind_interval)

        GAME_INFO.gameid = gameid
        GAME_INFO.ruleStatus = 0
        if gameid > 0 and rule == 1 then
            -- here turbo-ccgame should be turn ON
            if GAME_INFO.usageInfo.vip == E_VIP then
                GAME_INFO.on_game(gameid, regionid)
            end
        end

        logger(GAME_INFO.gameid .. ',' .. rule ..
                ',' .. LuciJson.encode(GAME_INFO.usageInfo))
    end,

    --check if service can avaiable for such user
    check_vip_info = function()
        logger("fun: check_vip_info")
        local param = {
            provider = 'ccgame',
        }
        local s = LuciUtil.exec("/usr/bin/matool --method api_call_post --params /device/vip/info/use '" .. LuciJson.encode(param) .. "'")
        local ret, result = pcall(function() return LuciJson.decode(LuciUtil.trim(s))
        end)
        GAME_INFO.usageInfo.vip = E_NOK;

        if ret and result and result.code == 0 and result.data then
            GAME_INFO.usageInfo.info = result.data
            -- check vip 1stly
            local t_vipInfo = result.data.vipInfo
            local curTs = os.time()
            if t_vipInfo then
                local vipEndtime = t_vipInfo.endTime / 1000
                logger("curTs: " .. curTs .. ',vipEndTime: ' .. vipEndtime)
                if t_vipInfo.endTime > 0 then
                    if curTs < vipEndtime then
                        GAME_INFO.usageInfo.vip = E_VIP;
                        GAME_INFO.usageInfo.vip_expire_days = math.floor((vipEndtime - curTs) / 3600 / 24)
                        return
                    end
                end
            end

            -- check free trial
            if result.data.freeInfo then
                local leftTime = tonumber(result.data.freeInfo.maxTime or 0) - (curTs - tonumber(result.data.freeInfo.lastActiveTime or 0))
                if leftTime < 0 then
                    leftTime = 0
                end

                local leftCount = result.data.freeInfo.maxCount - result.data.freeInfo.countUsed
                if leftCount < 0 then
                    leftCount = 0
                end
                GAME_INFO.usageInfo.nonvip_left_count = leftCount
                if leftCount > 0 or (leftCount == 0 and leftTime >= 0) then
                    GAME_INFO.usageInfo.vip = E_NON_VIP_OK
                else
                    GAME_INFO.usageInfo.vip = E_NON_VIP_NOK
                    GAME_INFO.off_vpn()
                end
            else
                -- if no freeinfo, will stop it
                if GAME_INFO.vpnStatus == 0 then
                    GAME_INFO.off_vpn()
                end
            end
        end
    end,

    --check_vpn_state
    check_vpn_state = function()
        GAME_INFO.get_vpnstate_try_num = 10
        get_vpnstate_timer:set(GAME_INFO.get_vpnstate_interval)
    end,

    -- read/update current VPN state
    read_vpnstate = function(not_repeat)
        logger("fun: read_vpnstate")
        local vpnStateRet, vpnState = CCFUNC_GET_VPN_STATE()
        logger(vpnStateRet .. LuciJson.encode(vpnState or {}))
        if vpnStateRet and vpnStateRet == 0 and vpnState and vpnState.ip ~= "" then
            GAME_INFO.vpnStatus = 1
            GAME_INFO.vpnInfo = vpnState
        else
            GAME_INFO.vpnStatus = 0
            GAME_INFO.vpnInfo = nil
        end

        -- vpn On, need check if it's true
        if not not_repeat then
            if GAME_INFO.vpnStatus == 1 then
                GAME_INFO.get_vpnstate_try_num = 0
            end
            if GAME_INFO.get_vpnstate_try_num > 0 then
                GAME_INFO.get_vpnstate_try_num = GAME_INFO.get_vpnstate_try_num - 1
                get_vpnstate_timer:set(GAME_INFO.get_vpnstate_interval)
            end
        end
    end,

    -- get password
    get_passport = function()
        logger("fun: get_passport")
        -- get uid + passwd
        if GAME_INFO.uid and GAME_INFO.passwd then
            return
        end
        local cmd = "matool --method api_call --params /device/radius/info 2>/dev/null"
        local output = LuciUtil.trim(LuciUtil.exec(cmd))

        if not output or output == "" then
            return
        end
        local ret, account = pcall(function() return LuciJson.decode(output) end)

        if not ret and not account or type(account) ~= "table" or
                account.code ~= 0 or not account.data then
            GAME_INFO.uid = nil
            GAME_INFO.passwd = nil
        else
            GAME_INFO.uid = account.data.name
            GAME_INFO.passwd = account.data.password
        end
    end,

    -- read vpn server from cc periodly
    get_vpnserver = function()
        logger("fun: get_vpnserver")

        if not GAME_INFO.uid or not GAME_INFO.passwd then
            GAME_INFO.get_passport()
        end

        -- get vpn server info from cc
        para.data = {}
        para.uid = GAME_INFO.uid
        para.data.passwd = GAME_INFO.passwd
        para.time = os.time()

        local ip, info = ccgame_get_vpn_server(para)

        GAME_INFO.vpn_server = { ip = ip, info = info }
        if ip then
            GAME_INFO.get_vpnserver_ip_timer_interval = math.random(12 * 3600, 24 * 3600)
            get_vpnserver_ip_timer:set(GAME_INFO.get_vpnserver_ip_timer_interval * 1000)
            GAME_INFO.get_vpnserver_ip_timer_interval = 0
        else
            if GAME_INFO.get_vpnserver_ip_timer_interval <= 0 then
                GAME_INFO.get_vpnserver_ip_timer_interval = 1
                get_vpnserver_ip_timer:set(GAME_INFO.get_vpnserver_ip_timer_interval * 60 * 1000)
            elseif GAME_INFO.get_vpnserver_ip_timer_interval > 64 then
                GAME_INFO.get_vpnserver_ip_timer_interval = 0
            else
                GAME_INFO.get_vpnserver_ip_timer_interval = GAME_INFO.get_vpnserver_ip_timer_interval * 2
                get_vpnserver_ip_timer:set(GAME_INFO.get_vpnserver_ip_timer_interval * 60 * 1000)
            end
        end
    end,

    -- VPN status change callback
    update_vpn_status = function(onFlag)
        if not onFlag then
            -- vpn Off
            GAME_INFO.vpnStatus = 0
            GAME_INFO.vpnInfo = nil
        else
            GAME_INFO.read_vpnstate(true)
        end
    end,

    -- ipset Game change callback
    update_gameid = function(gameid, regionid, status)
        if gameid and regionid then
            GAME_INFO.gameid = tonumber(gameid)
            GAME_INFO.regionid = tonumber(regionid)
            write_cfg('turbo', 'ccgame', 'gameid', tostring(gameid))
            write_cfg('turbo', 'ccgame', 'regionid', tostring(regionid))
        end

        if status == 0 then
            GAME_INFO.ruleStatus = 0 -- not loaded
        else
            GAME_INFO.ruleStatus = 1 -- loaded done
        end

        write_cfg('turbo', 'ccgame', 'ruleStatus', tostring(GAME_INFO.ruleStatus))
    end,

    -- update game detect ip and port
    update_detect_target = function(ip, port, vpn)
        if ip and port and vpn then
            GAME_INFO.detect_ip = ip
            GAME_INFO.detect_port = tonumber(port)
            GAME_INFO.byvpn = vpn
        end
    end,

    -- return game info
    get_gameinfo = function()
        logger("func: get_gameinfo")
        local data = {}
        data.gameid = GAME_INFO.gameid
        data.regionid = GAME_INFO.regionid
        data.vpn = GAME_INFO.vpnStatus
        data.rule = GAME_INFO.ruleStatus
        return data
    end,

    -- Hot Game List
    hotGameList = {},
    get_hot_gamelist = function()
        logger("func: get_hot_gamelist")
        local cmd = "matool --method api_call_post --params /device/vip/ccgame/hot '{}' 2>/dev/null"
        local output = LuciUtil.trim(LuciUtil.exec(cmd))

        if not output or output == "" then
            return
        end
        local ret, out = pcall(function() return LuciJson.decode(output) end)

        if ret and out and out.data and out.data.list then
            for _, v in pairs(out.data.list) do
                GAME_INFO.hotGameList[v] = { id = v, name = '', icon = '' }
            end
        end
    end,

    --
    topNGameList = {},
    useTopNGameList = false,
    get_topN_gamelist = function()
        logger("func: get_topN_gamelist")
        local cmd = "matool --method api_call_post --params /device/vip/ccgame/topN '{}' 2>/dev/null"
        local output = LuciUtil.trim(LuciUtil.exec(cmd))

        if not output or output == "" then
            return
        end
        local ret, out = pcall(function() return LuciJson.decode(output) end)
        GAME_INFO.topNGameList = {}
        if ret and out.code == 0 and out.data and out.data.list then
            return out.data.list
        end
        return nil
    end,

    -- check online_ip and online_port periodly
    online_ip_check = function(kill)
        logger("fun: online_ip_check")
        if not kill then
            online_ip_timer:set(GAME_INFO.online_ip_interval)
        end
        if GAME_INFO.vpnStatus == 1 then
            if GAME_INFO.gameid > 0 then
                GAME_INFO.online_ip, GAME_INFO.online_port = get_connected_iplist(kill)
                if GAME_INFO.online_ip and GAME_INFO.online_port then
                    logger("retrive current online ip/port : " .. (GAME_INFO.online_ip or 0) .. ":" .. (GAME_INFO.online_port or 0))
                end
            else
                GAME_INFO.online_ip, GAME_INFO.online_port = nil, nil
            end
        end
    end,

    -- check rt cache get current hit ip
    get_hit_gameip = function()
        logger("func: get_hit_gameid")
        local ps = cc_func_execl('grep ccgame /proc/net/rt_cache 2>/dev/null')
        if not ps then
            return nil
        end

        local data = {}

        for _, line in pairs(ps) do
            local arr = split(line, "%s+", nil, 1)
            if arr[2] then
                data[arr[2]] = { dst = ip2str(arr[2]), count = arr[6], src = ip2str(arr[8]) }
            end
        end

        local target_cmd = "fping -t 1000 -C1 -q "
        local valid = false
        for _, ip in pairs(data) do
            target_cmd = target_cmd .. " " .. ip.dst .. " "
            valid = true
        end

        if not valid then return nil end

        target_cmd = target_cmd .. " 2>&1 "
        local output = LuciUtil.exec(target_cmd)

        return { data = data, qos = output }
    end,

    --
    get_ping_cmd = function()
        local targetIP, targetPort
        if GAME_INFO.online_ip and GAME_INFO.online_port then
            targetIP = GAME_INFO.online_ip
            targetPort = GAME_INFO.online_port
        else
            targetIP = GAME_INFO.detect_ip
            targetPort = GAME_INFO.detect_port
        end

        logger("detected ip:" .. GAME_INFO.detect_ip .. ':' .. GAME_INFO.detect_port)
        local cmd = "tping " .. targetIP .. " -q -p " .. targetPort
        return cmd, targetIP, targetPort
    end,

    -- try to ping game dst ip:port periodly, note: better larger than 4second
    ping_ip = function(byvpn)

        local cmd, tip, tport = GAME_INFO.get_ping_cmd()
        if byvpn ~= 0 and GAME_INFO.vpnStatus and GAME_INFO.vpnStatus == 1 then
            cmd = cmd .. " -i l2tp-ccgame"
        end
        cmd = cmd .. " 2>/dev/null"

        -- ICMP, 4 sent, 4 received, 0% lost, avg=1.39 ms
        local ps = cc_func_exec(cmd)
        if not ps then
            return nil
        end

        logger(cmd .. "=> " .. ps)

        local _, _, nSent, nRecv, lost, rtt = string.find(ps, "(%d+)%s+sent,%s+(%d+)%s+received,%s+(%d+)%%%s+lost,%s+avg=([0-9.]+)%s+ms")
        local info = {}
        if nSent and nRecv and lost and rtt then
            info.ip = tip
            info.port = tport
            info.lost = lost
            info.rtt = rtt
            info.sent = nSent
            info.recv = nRecv
        else
            info = nil
        end

        return info
    end,

    -- fill leftPingCount
    fill_leftPingCount = function()
        GAME_INFO.leftPingCount = 5
    end,

    -- check if need Ping again
    check_leftPingCount = function()
        GAME_INFO.leftPingCount = GAME_INFO.leftPingCount - 1
        if GAME_INFO.leftPingCount < 0 then
            --clear pingInfo because it's no use
            --GAME_INFO.pingInfo = nil
            return false
        end
        return true
    end,

    -- ping loop worker
    ping_worker = function()
        -- logger("fun: ping_worker")
        ping_timer:set(GAME_INFO.ping_interval)
        if GAME_INFO.vpnStatus == 0 then
            return
        end
        if GAME_INFO.check_leftPingCount() then
            GAME_INFO.pingInfo = GAME_INFO.ping_ip(GAME_INFO.byvpn)
            --logger(LuciJson.encode(GAME_INFO.pingInfo or {}))
        end
    end,

    --
    off_vpn = function()
        logger("fun: off_vpn ---------------")
        stop_vpn_config()
        GAME_INFO.clean_ipset(ipset_name)
        GAME_INFO.vpnStatus = 0
        return 0
    end,

    --
    clean_ipset = function(ipset_name)
        clean_route_rule(ipset_name)
        GAME_INFO.update_gameid(nil, nil, 0)
        return 0
    end,

    --
    on_game = function(gameid, regionid)
        logger("fun: on_game(" .. gameid .. "," .. regionid .. ") +++++++++++++++++")
        local ret_code = 0
        -- update vip usage info after clicked
        check_vip_timer:set(200)

        -- report vpn info to cc
        GAME_INFO.upload_log2cc(true)

        if GAME_INFO.vpnStatus ~= 1 then
            para.time = os.time()
            para.cmdid = 2
            para.uid = GAME_INFO.uid
            para.data = {
                passwd = GAME_INFO.passwd
            }

            if not GAME_INFO.vpn_server or not GAME_INFO.vpn_server.ip then
                GAME_INFO.get_vpnserver()
                if not GAME_INFO.vpn_server.ip then
                    GAME_INFO.off_vpn()
                    logerr("get vpn-server failed......")
                    return
                end
            end

            -- start vpn
            ret_code = start_vpn_config(GAME_INFO.uid, GAME_INFO.passwd, GAME_INFO.vpn_server.ip)
            if ret_code ~= 0 then
                GAME_INFO.off_vpn()
                logerr("set vpn config and start vpn failed.....")
                return
            end

            -- checking timer to update VPN status
            GAME_INFO.check_vpn_state()
        end

        -- download gameinfo and load gameinfo now
        if ret_code == 0 then
            para.time = os.time()
            para.cmdid = 5
            para.uid = GAME_INFO.uid
            para.data = { gameid = gameid, regionid = regionid }

            local code, info = game_speedup_start(para)

            if code == 0 then
                -- apply ruleStatus 1stly
                GAME_INFO.update_gameid(gameid, regionid, 1)
                code = apply_route_new_game(ipset_name, info)

                -- just del old conntrack to enforce create new conntrack
                GAME_INFO.online_ip_check(1)
            end

            if code ~= 0 then
                GAME_INFO.clean_ipset(ipset_name)
                GAME_INFO.update_gameid(gameid, regionid, 0)
            end
        end
    end,
}

-- define ubus interface
local ccgame_method =
{
    turbo_ccgame =
    {
        -- callback when ifup VPN/ifdown VPN
        -- { status = ubus.INT32 }
        update_vpn =
        {
            function(req, msg)
                local data = { code = -1 }
                if msg and msg.status then
                    if msg.status == 0 then
                        GAME_INFO.update_vpn_status(false)
                    else
                        GAME_INFO.update_vpn_status(true)
                    end
                    data.code = 0
                else
                    data.msg = "status is lost."
                end
                conn:reply(req, data)
            end, { status = ubus.INT32 }
        },

        --callback for udpate VPNserver and passwd
        update_pass =
        {
            function(req)
                GAME_INFO.get_passport()
                get_vpnserver_ip_timer:set(1500)
                conn:reply(req, { code = 0 })
            end, {}
        },

        -- callback for get game info
        get_gameid =
        {
            function(req)
                conn:reply(req, { code = 0, data = GAME_INFO.get_gameinfo() })
            end, {}
        },
        get_pass =
        {
            function(req)
                local ret = { code = -1 }
                if GAME_INFO.uid and GAME_INFO.passwd and GAME_INFO.vpn_server then
                    ret.uid = GAME_INFO.uid
                    ret.passwd = '********'
                    ret.vpn_server = GAME_INFO.vpn_server
                    GAME_INFO.check_vip_info()
                    ret.vip = GAME_INFO.usageInfo
                    ret.game = GAME_INFO.get_gameinfo()
                    ret.ppplog = GAME_INFO.get_ppplog()
                    ret.hit = GAME_INFO.get_hit_gameip()
                    ret.code = 0
                else
                    ret.msg = "uid or passwd or vpnserver is nil."
                end
                conn:reply(req, ret)
            end, {}
        },

        -- callback for vip info
        get_vip =
        {
            function(req)
                GAME_INFO.check_vip_info()
                local ret = { code = 0, data = GAME_INFO.usageInfo }
                conn:reply(req, ret)
            end, {}
        },

        -- callback for ping info
        -- { ip = ubus.STRING, port = ubus.INT32 }
        get_ping =
        {
            function(req, msg)
                local ret = { code = 0, msg = '', data = GAME_INFO.get_gameinfo() }

                if msg and msg.ip and msg.port then

                    -- update detect-ip + port
                    GAME_INFO.update_detect_target(msg.ip, msg.port, msg.vpn or 1)

                    -- return ping info if it's valid
                    if GAME_INFO.pingInfo then
                        ret.data.info = GAME_INFO.pingInfo
                    else
                        -- cannot get valid ping this time, fetch again next time
                        ret.data.info = {}
                        ret.code = -1
                    end

                    -- fill ping count at last
                    GAME_INFO.fill_leftPingCount()
                else
                    ret.msg = "ip or port lost."
                    ret.code = -1
                    ret.data.info = GAME_INFO.pingInfo
                end

                conn:reply(req, ret)
            end, { ip = ubus.STRING, port = ubus.INT32, vpn = ubus.INT32 }
        },

        -- callback for get vpn status
        get_vpn =
        {
            function(req)
                local ret = { code = -1, msg = '', data = {} }
                if GAME_INFO.vpnStatus and GAME_INFO.vpnStatus == 1 then
                    ret.code = 0
                    ret.data = GAME_INFO.vpnInfo
                    ret.msg = 'VPN is ON'
                else
                    ret.code = -1
                    ret.data = {}
                    ret.msg = 'VPN is OFF'
                end
                conn:reply(req, ret)
            end, {}
        },

        -- callback for open turbo-game
        game_start =
        {
            function(req, msg)
                local ret = { code = -1, msg = 'unknown error.' }
                -- try to check uid and passwd 1stly
                if not GAME_INFO.uid or not GAME_INFO.passwd then
                    GAME_INFO.get_passport()
                end

                if not GAME_INFO.uid or not GAME_INFO.passwd then
                    ret.msg = 'uid or passwd is lost or NULL'
                elseif not msg or not msg.gameid or not msg.regionid then
                    ret.msg = 'gameid or regionid is lost or NULL'
                else
                    -- return response async
                    ret.msg = 'game start is in progress..'
                    ret.code = 1
                    conn:reply(req, ret)

                    -- turn on turbo ccgame
                    GAME_INFO.on_game(msg.gameid, msg.regionid)
                    return
                end
                conn:reply(req, ret)
            end, { gameid = ubus.INT32, regionid = ubus.INT32 }
        },

        -- callback for close turbo-game
        game_stop =
        {
            function(req)
                local ret = { code = 0, msg = '' }
                ret.msg = 'game stop command.'
                conn:reply(req, ret)

                GAME_INFO.off_vpn()
                return
            end, {}
        },

        -- get expire info
        get_expire = {
            function(req)
                local ret = { code = 0, msg = 'ok' }
                GAME_INFO.check_vip_info()
                ret.data = GAME_INFO.usageInfo
                conn:reply(req, ret)
            end, {}
        },

        -- get latest played game id
        get_LPG = {
            function(req)
                local ret = { code = 0, msg = 'ok' }
                ret.data = GAME_INFO.read_LPG_gameid()
                conn:reply(req, ret)
            end, {}
        },

        -- debug interface
        debug = {
            function(req)
                local ret = { code = 0, msg = 'no change' }

                g_debug = 1
                ret.msg = 'turn on debug'
                conn:reply(req, ret)
            end, {}
        },

        --
        test = {
            function(req, msg)
                local ret = { code = 0, msg = 'ok' }
                if msg and msg.func then
                    local f = loadstring('return GAME_INFO.' .. msg.func .. '()')
                    ret.data = f()
                end
                conn:reply(req, ret)
            end, { func = ubus.STRING }
        },
    },
}

--try to start ccgame service
local function ccgame_service()
    logerr("ccgame service loading.....")
    GAME_INFO.init()

    logger("ccgame service ubus binding....")
    conn:add(ccgame_method)

    uloop.run()
end

-- main
ccgame_service()













