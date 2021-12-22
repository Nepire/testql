#!/usr/bin/lua

local json = require "cjson"
local LuciUtil = require("luci.util")
require("turbo.ccgame.ccgame_util")

local uci = require 'luci.model.uci'
local x = uci.cursor()

local string, tonumber, pcall, type, table = string, tonumber, pcall, type, table

local ccgame_cfg = {
    set = function(opt, val)
        x:set('turbo', 'ccgame', opt, val or "")
        x:commit('turbo')
    end,
    get = function(opt)
        local val = x:get('turbo', 'ccgame', opt)
        return val or ""
    end
}

local function valid_input(cmd)
    return 0
end

function ccgame_get_vpn_server(cmd)
    local vpnlistInfo = {}
    local vpnlist = cc_func_get_vpn_server_list(cmd)
    logger("**got vpnlist: " .. (vpnlist or "[]"))
    if vpnlist then
        local it = split(vpnlist, ',')
        if it then
            vpnlistInfo = cc_ping_vpn_list(it)
        end
    else
        return nil, nil
    end

    serverip = cc_func_get_vpn_server_ip(cmd, vpnlistInfo)
    logger("**got terminator-VPN-Srv: " .. serverip)
    return serverip, vpnlistInfo
end

function service_start(cmd, srvIP)
    CC_LOG_INFO("service_start starting ")
    local code = valid_input(cmd)
    if (code ~= 0) then
        return code
    end

    local pwd = cc_func_getpwd()
    if not pwd then
        return -11000
    end

    local uid, password, serverip
    if not cmd.data then
        return -10010
    end

    if not cmd.uid then
        return -10010
    end

    if not cmd.data.passwd then
        return -10010
    end

    uid = cmd.uid
    password = cmd.data.passwd


    if srvIP then
        serverip = srvIP
    else
        serverip = ccgame_get_vpn_server(cmd)
    end

    CC_LOG_INFO("service_start cc_func_get_vpn_server_ip " .. serverip)
    local ret = start_vpn_config(uid, password, serverip)
    if ret ~= 0 then
        return -11101
    end
    CC_LOG_INFO("service_start start_vpn_config finished ")

    local baseinfo = {}
    baseinfo.uid = uid
    baseinfo.devicetype = cmd.devicetype and cmd.devicetype or "1101"
    baseinfo.version = cmd.version and cmd.version or "0.1"
    baseinfo.usertype = cmd.usertype and cmd.usertype or "2"
    baseinfo.passwd = password
    baseinfo.serverip = serverip
    baseinfo.vpnstart = os.time()

    cc_func_save_baseinfo(baseinfo)

    return 0, vpnState
end

function service_stop(cmd)
    CC_LOG_INFO("service_stop starting ")
    --[[
      local code=valid_input(cmd)
      if (code ~= 0) then
        return code
      end

      local gameinfo = cc_func_get_gameinfo()
      if gameinfo  and gameinfo.info then
        cc_func_route_delete(gameinfo.info)
        CC_GAMEINFO_DEL()
      end
      --]]

    -- just flush ipset rules
    LuciUtil.exec('ipset -q flush ccgame >/dev/null 2>&1')
    CC_GAMEINFO_DEL()
    stop_vpn_config()
    CC_BASEINFO_DEL()
    data = {}
    return 0, data
end

function service_status(cmd)
    CC_LOG_INFO("service_status starting ")
    local code = valid_input(cmd)
    if (code ~= 0) then
        return code
    end

    local vpnStateRet, vpnState = CCFUNC_GET_VPN_STATE()
    if not vpnStateRet or vpnStateRet ~= 0 then
        return -11002
    end

    return 0, vpnState
end

--check if current working IP exist, otherwise use IP in parameter for QoS
function qos_get2(cmd)
    --CC_LOG_INFO("qos_get starting in another way")
    local code = valid_input(cmd)
    if (code ~= 0) then
        return code
    end
    local code = 0
    local data = {}
    local qosInfo = {}

    --get game info
    local gameinfo = cc_func_get_gameinfo()
    if not gameinfo then
        return -11003
    end

    --get connected ip list
    local speedlist = cc_func_get_connected_iplist(gameinfo.info, gameinfo.mask)
    --check if get connected ip list
    if type(speedlist) ~= "table" or #speedlist <= 0 then
        if cmd and cmd.data and cmd.data.iplist then
            speedlist = split(cmd.data.iplist, ',')
        end
    end

    if not speedlist then
        return -11011
    end

    -- now start ping
    local qoslist = cc_func_ping_state(speedlist, cmd.data.byvpn)
    if not qoslist then
        return -11005
    end

    qosInfo.info = qoslist
    qosInfo.gameid = gameinfo.gameid
    return code, qosInfo
end

function qos_get(cmd)
    CC_LOG_INFO("qos_get starting ")
    local code = valid_input(cmd)
    if (code ~= 0) then
        return code
    end
    local code = 0
    local data = {}

    if not cmd.data or not cmd.data.iplist or cmd.data.iplist == "" then
        local gameinfo = cc_func_get_gameinfo()
        if not gameinfo then
            return -11003
        end

        local qoslist = cc_func_get_qos(gameinfo)
        if not qoslist then
            return -11004
        end

        return code, qoslist
    end

    local it = split(cmd.data.iplist, ',')
    if not it then
        return -11011
    end

    local qoslist = cc_func_ping_state(it, cmd.data.byvpn)
    if not qoslist then
        return -11005
    end

    local qosInfo = {}
    qosInfo.info = qoslist
    local gameinfo = cc_func_get_gameinfo()
    if gameinfo and gameinfo.gameid then
        qosInfo.gameid = gameinfo.gameid
    else
        qosInfo.gameid = ""
    end

    return code, qosInfo
end

function game_speedup_start(cmd)
    CC_LOG_INFO("game_speedup_start starting ")
    local code = valid_input(cmd)
    if (code ~= 0) then
        return code
    end

    if not cmd.data.gameid or not cmd.data.regionid then
        return -10010
    end

    local ret_v, ret_data = cc_func_ccserver_request(7, cmd)
    if ret_v ~= 0 or not ret_data then
        return -10010
    end

    return 0, ret_data
end

function clean_route_rule(ipset_name)
    LuciUtil.exec('ipset -q flush ' .. ipset_name .. ' >/dev/null 2>&1')
end

function apply_route_new_game(ipset_name, it, notClean)
    if not notClean then
        clean_route_rule(ipset_name)
    end

    local r = cc_func_route_add(ipset_name, it)

    if not r then
        return -11008
    end

    return 0
end

function game_speedup_stop(cmd)
    CC_LOG_INFO("game_speedup_stop starting ")
    --[[
    local code=valid_input(cmd)
    if (code ~= 0) then
      return code
    end

    -- reset gameid if stop gameid
    ccgame_cfg.set('gameid','-1')

    local gameinfo = cc_func_get_gameinfo()
    if not gameinfo  or not gameinfo.info then
      CC_LOG_INFO("game_speedup_stop no gameinfo ")
      return 0, {}
    end

    if cc_func_route_delete(gameinfo.info)  then
      CC_LOG_INFO("game_speedup_stop cc_func_route_delete success ")
      CC_GAMEINFO_DEL()
      return 0, {}
    else
      CC_LOG_INFO("game_speedup_stop cc_func_route_delete failed ")
      return -11010, {}
    end
    --]]

    -- just flush ipset rules
    LuciUtil.exec('ipset -q flush ccgame >/dev/null 2>&1')
    CC_GAMEINFO_DEL()
    return 0, nil
end

function get_cur_gameid(cmd)
    local gameid = ccgame_cfg.get('gameid');
    local gameinfo = cc_func_get_gameinfo()
    local data = {}
    data.gameid = gameid
    if not gameinfo or not gameinfo.info then
        data.status = 0
    elseif gameinfo.gameid and gameid ~= gameinfo.gameid then
        data.gameid = gameinfo.gameid
        ccgame_cfg.set('gameid', gameinfo.gameid)
        data.status = 1
    else
        data.status = 1
    end

    return 0, data
end
