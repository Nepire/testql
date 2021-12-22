#!/usr/bin/lua

-- service-name
local turboService = "ccgame"

local iproute2table = "/etc/iproute2/rt_tables"
-- fwmark for such lx game
local fwmark = "0x0100/0x0300"

local proto = 'l2tp'

local XQFunction = require("xiaoqiang.common.XQFunction")
local XQCryptoUtil = require("xiaoqiang.util.XQCryptoUtil")

local Network = require("luci.model.network")
local Firewall = require("luci.model.firewall")
local turbo = require("libturbo")

function initService()
    turbo.ipset_init()
end

function destroyService()
    turbo.ipset_destroy()
    os.execute("ip route del fwmark " .. fwmark .. " table " .. ruleTable .. " 2>/dev/null")
end

-- @param proto pptp/l2tp
-- @param auto  0/1
local function setVpn(interface, server, username, password, proto, maxtries, ipv6)
    if XQFunction.isStrNil(interface) or
            XQFunction.isStrNil(server) or
            XQFunction.isStrNil(username) or
            XQFunction.isStrNil(password) or
            XQFunction.isStrNil(proto) then
        return false
    end

    local vpnid = XQCryptoUtil.md5Str(server .. username .. proto)
    local protocal = string.lower(proto)
    local network = Network.init()
    network:del_network(interface)

    local vpnNetwork = network:add_network(interface, {
        proto = protocal,
        server = server,
        username = username,
        password = password,
        auth = 'auto',
        auto = '0',
        pppd_options = 'refuse-eap',
        peerdns = '0',
        defaultroute = '0',
        maxtries = maxtries or '0',
    })

    -- add ipv6 support
    local vpn6Network = false
    if ipv6 then
        vpn6Network = network:add_network(interface .. '6', {
            proto = 'dhcpv6',
            iface = '@' .. interface
        })
    else
        vpn6Network = true
    end

    if vpnNetwork and vpn6Network then
        network:save("network")
        network:commit("network")
        local firewall = Firewall.init()
        local zoneWan = firewall:get_zone("wan")
        zoneWan:add_network(interface)
        firewall:save("firewall")
        firewall:commit("firewall")
        return true
    end

    return false
end

-- del vpn config in /etc/config/network
local function delVpn(interface)
    local nameOfIf = interface
    local network = Network.init()
    network:del_network(nameOfIf)
    network:del_network(nameOfIf .. "6")
    network:save("network")
    network:commit("network")
    local firewall = Firewall.init()
    local zoneWan = firewall:get_zone("wan")
    zoneWan:del_network(nameOfIf)
    firewall:save("firewall")
    firewall:commit("firewall")
end

function vpnOn(server, uname, upass)
    setVpn(turboService, server, uname, upass, proto, '10')
    os.execute("ifup " .. turboService)
end

function vpnOff()
    os.execute("ifdown " .. turboService)
    delVpn(turboService)
end

function getVpnStatCmd()
    local cmd = "ifconfig " .. proto .. "-" .. turboService .. " 2>/dev/null"
    --print(cmd)
    return cmd;
end

--Route Into table


