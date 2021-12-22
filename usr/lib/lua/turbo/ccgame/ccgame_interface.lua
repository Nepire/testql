#!/usr/bin/lua

module("turbo.ccgame.ccgame_interface", package.seeall)

local LuciJson = require("cjson")
local LuciUtil = require("luci.util")
local string, tonumber, pcall, type, table = string, tonumber, pcall, type, table

require "turbo.ccgame.ccgame"
require "turbo.ccgame.ccgame_util"

local function response_info(code, data)
    local res = {}
    local curTime = os.time()
    if (not code) then
        res.code = -10000
        res.time = curTime
        res.data = {}
    else
        res.code = code
        res.time = curTime
        if (not data) then
            res.data = {}
        else
            if (type(data) == "table") then
                res.data = {}
                res.data = data
            elseif (type(data) == "string") then
                res.data = {}
                res.data.content = data
            else
                res.data = {}
            end
        end
    end

    return res
end


local action = {
    [1] = function(x) return service_start(x) end,
    [2] = function(x) return service_stop(x) end,
    [3] = function(x) return service_status(x) end,
    [4] = function(x) return qos_get2(x) end,
    [5] = function(x) return game_speedup_start(x) end,
    [6] = function(x) return game_speedup_stop(x) end,
    [7] = function(x) return get_cur_gameid(x) end,
}

local function json_entry(sJson)
    local resInfo = {}

    local res = {}
    if not sJson then
        return response_info(-10001)
    end

    local cmd = sJson
    local ret
    if type(sJson) == 'string' then
        ret, cmd = pcall(function() return LuciJson.decode(sJson) end)
        if not ret then cmd = false end
    elseif type(sJson) ~= 'table' then
        return response_info(-10001)
    end
    if not cmd then
        return response_info(-10002)
    end

    local cmdid = tonumber(cmd.cmdid)
    if not cmdid then
        resInfo = response_info(-10005)
        return resInfo
    end

    if action[cmdid] then
        local code
        local data = {}

        code, data = action[cmdid](cmd)

        if not code then
            resInfo = response_info(-10000)
        else
            resInfo = response_info(code, data)
        end
    else
        resInfo = response_info(-10005)
    end

    return resInfo
end

function ccgame_json_call(jsonstr)
    local sJson = jsonstr
    local ret
    local pret, err = pcall(json_entry, sJson)
    if not pret then
        ret = response_info(-10007, err)
    else
        ret = err
    end

    return ret
end

-- ccgame call from lua, add by xiaomi
local ubus_service = 'turbo_ccgame'
function ccgame_call(paraIn)
    local para = paraIn or {}
    local cmd
    local result = {}

    para.devicetype = 1101
    para.version = "0.1"
    para.usertype = "2"
    para.time = os.time()

    if not para.cmdid then
        result['code'] = -1
        result['msg'] = 'cmdid lost.'
        return result
    end

    cmd = para.cmdid

    -- other command call ubus interface
    local ubus = require("ubus")
    local conn = ubus.connect()
    if not conn then
        result['code'] = -1
        result['msg'] = 'ubus cannot connected.'
        return result
    end

    local data = {}
    local query
    if cmd == 1 or cmd == 5 then
        -- just active account to make accounting happy
        data = { provider = "ccgame" }
        local cmd = "matool --method api_call_post --params /device/vip/account '"
                .. LuciJson.encode(data) .. "'"
        local ret, account = pcall(function() return LuciJson.decode(LuciUtil.trim(LuciUtil.exec(cmd))) end)

        if not ret or not account or type(account) ~= "table" or account.code ~= 0 then
            result['code'] = -1
            result['msg'] = 'active account failed.'
            return result
        elseif not para.data or not para.data.gameid or not para.data.regionid then
            result['code'] = -1
            result['msg'] = 'gameid or regionid lost for turbo-game command.'
            return result
        else
            query = 'game_start'
            data = { gameid = para.data.gameid, regionid = para.data.regionid }
        end
    elseif cmd == 2 then
        query = 'game_stop'
    elseif cmd == 3 then
        query = 'get_vpn'
    elseif cmd == 4 then
        if not para.data or not para.data.iplist then
            result['code'] = -1
            result['msg'] = 'detect ip:port is lost.'
            return result
        end
        query = 'get_ping'
        local iplist = para.data.iplist
        local ipport = split(iplist, ':')
        data.ip = ipport[1]
        data.port = tonumber(ipport[2] or '0')
    elseif cmd == 7 then
        query = 'get_gameid'
    elseif cmd == 8 then
        query = 'get_expire'
    elseif cmd == 9 then
        query = 'get_LPG'
    elseif cmd == 0 then
        if para.ubus then
            query = para.ubus
        end
    else
        result['code'] = -1
        result['msg'] = 'not supported command.'
        return result
    end
    local res = conn:call(ubus_service, query, data)
    conn:close()
    if res then
        return res
    else
        result['code'] = -1
        result['msg'] = 'call ubus failed.'
        return result
    end
end
