#!/usr/bin/lua

require("socket")
local px =  require "Posix"
local json= require 'json'
local libunix=require 'socket.unix'
local cfg_host_path='/var/run/miqosd.sock'

module("miqos", package.seeall)

function cmd(action)
    local unsock=assert(libunix())
    local trynum=3
    while trynum > 0 and unsock:connect(cfg_host_path) ~= 1 do
        trynum = trynum -1
        --print(trynum)
        socket.sleep(1)
        unsock:close()
        unsock=assert(libunix())
    end

    if trynum == 0 then
        return json.decode('{"status":-1, "data":"cannot connect to service."}')
    end

    local s,err = unsock:send(action..'\n')
    if err then
        return json.decode('{"status":-1, "data":"send error."}')
    end

    local data=''
    while true do
        local line, err = unsock:receive()
        if not line then
            if err == 'closed' then
                unsock:close()
                return json.decode(data)
            else
                unsock:close()
                return json.decode('{"status":-1}')
            end
        else
            data = data .. line
        end
    end
    unsock:close()
    return json.decode('{"status":-1}')
end

--[[
px.openlog("miqos","np",LOG_USER)

function logger(loglevel,msg)
    px.syslog(loglevel,msg)
end

function print_r(root,ind)
    local indent="    " .. ind

    for k,v in pairs(root) do
            if(type(v) == "table") then
                    print(indent .. k .. " = {")
                    print_r(v,indent)
                    print(indent .. "}")
            else
                    print(indent .. k .. "=" .. v)
            end
    end

end

function main()
    local data=''
    for i,v in ipairs(arg) do
        data = data .. ' ' .. v
    end

    local str=cmd(data)
    if str then
        print("{")
        print_r(json.decode(str),"")
        print("}")
    end
end

main()
--]]


