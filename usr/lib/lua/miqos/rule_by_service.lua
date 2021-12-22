#!/usr/bin/lua
--[[
MTK HWQOS:

HWQOS是在有线口的硬件上实现.
因为80有一部分端口在某些情况流量需要跳过HWNAT
1. 80等端口的APK流量会跳过HWNAT

这部分流量比较小,所以可以暂时忽略,在外面增加softQoS来控制
如果以后有更大量的流需要跳过HWNAT,就需要考虑下更改结构了,这是个坑.

--]]

require 'miqos.common'

local THIS_QDISC='service' -- 流队列的配置

-- 将对应的处理方法加入qdisc表
local qdisc_df = {}
qdisc[THIS_QDISC]= qdisc_df

local lip  = require "luci.ip"
local upload_sch=0
local download_sch=0

local ipset_skip_hwqos_name = "SKIP_HWNAT4QOS"
local miqosd_init_script="/usr/sbin/miqosd_init.sh"

local service_cfg={
    qos={ack=false,syn=true,fin=true,rst=true,icmp=true,small=false},    -- 优先级的包
    online_timeout={wl=5,wi=300},   -- 在线超时时间判断
}

g_softqos_main=0

-- 在线device列表信息
local device_list={}
local online_device_list={}
local UDF_Q_table={}
local refresh_hwnat_ip_list={}
-- 需要走softqos的ip列表
local UDF_softQ_table={}

-- 需要设置ipset的ip列表
local UDF_softQ_ipset={}
local total_user_queues=0
local rebuild_qos=false
--

-- hwqos的结构
local hwqos_table={
        ['sch_rate']={      -- 2 schedulers, seperated by GMACs
            [UP]={
                id='0',
                rate='0',
                en='0',
            },
            [DOWN]={
                id='1',
                rate='0',
                en='0',
            },
        },
        ['q_rate']={
            ---------------UP--------------------
            ['15']={             -- UP/ all traffic out in total.
                w=15,
                sch=UP,         -- scheduler
                min_rate=0.6,     -- min rate
                min_en=1,       -- 30% UP band
                max_rate=0,     -- max rate
                max_en=1,
                own="flow",
            },
            ['14']={             -- UP/ guest-network
                w=2,
                sch=UP,       -- scheduler
                min_rate=80,     -- min rate
                min_en=1,
                max_rate=0,     -- max rate
                max_en=1,
                own='guest',
            },
            ---------------DOWN------------------
            ['13']={             -- DOWN/ game priority
                w=10,
                sch=DOWN,       -- scheduler
                min_rate=0.06,     -- min rate
                min_en=1,
                max_rate=0.5,     -- max rate
                max_en=1,     -- 50% of whole band-width
                own="flow",
            },
            ['12']={             -- DOWN/ web
                w=8,
                sch=DOWN,       -- scheduler
                min_rate=0.12,     -- min rate
                min_en=1,
                max_rate=1.0,     -- max rate
                max_en=1,
                own="flow",
            },
            ['11']={             -- DOWN/ video
                w=6,
                sch=DOWN,       -- scheduler
                min_rate=0.18,     -- min rate
                min_en=1,
                max_rate=0.95,     -- max rate
                max_en=1,
                own="flow",
            },

            -------------------USER------------------
            --['3'~'10'] for user defined rate-limit
            ['10']={
                w=4,
                sch=DOWN,
                min_rate=80,
                min_en=1,      -- min 10KB/s
                max_rate=0,
                max_en=0,
                own='user',
            },
            ['9']={
                w=4,
                sch=DOWN,
                min_rate=80,
                min_en=1,      -- min 10KB/s
                max_rate=0,
                max_en=0,
                own='user',
            },
            ['8']={
                w=4,
                sch=DOWN,
                min_rate=80,
                min_en=1,      -- min 10KB/s
                max_rate=0,
                max_en=0,
                own='user',
            },
            ['7']={
                w=4,
                sch=DOWN,
                min_rate=80,
                min_en=1,      -- min 10KB/s
                max_rate=0,
                max_en=0,
                own='user',
            },
            ['6']={
                w=4,
                sch=DOWN,
                min_rate=80,
                min_en=1,      -- min 10KB/s
                max_rate=0,
                max_en=0,
                own='user',
            },
            ['5']={
                w=4,
                sch=DOWN,
                min_rate=80,
                min_en=1,      -- min 10KB/s
                max_rate=0,
                max_en=0,
                own='user',
            },
            ['4']={
                w=4,
                sch=DOWN,
                min_rate=80,
                min_en=1,      -- min 10KB/s
                max_rate=0,
                max_en=0,
                own='user',
            },
            ['3']={
                w=4,
                sch=DOWN,
                min_rate=80,
                min_en=1,      -- min 10KB/s
                max_rate=0,
                max_en=0,
                own='user',
            },

            -----------------LOWEST------------------

            ['2']={             -- DOWN/ guest-network
                w=2,
                sch=DOWN,
                min_rate=80,
                min_en=1,      -- min 10KB/s
                max_rate=0,
                max_en=0,
                own='guest',
            },
            ['1']={             -- DOWN/ other
                w=1,
                sch=DOWN,       -- scheduler
                min_rate=80,     -- min rate
                min_en=1,
                max_rate=0,     -- max rate
                max_en=1,
                own='flow',
            },
            ['0']={             -- NO LIMIT Q for flowes between LANs
                w=15,
                sch=UP,         -- assign LAN to UP scheduler
                min_rate=0,     -- min rate
                min_en=0,
                max_rate=0,      -- max rate
                max_en=0,
                own="flow",
            },

        },
    }

-- guest网络
local QUEST_Q={
    UP='14',
    DOWN='2',
}

-- flow对应的Q类型
local DOWN_Q={
    game='13',
    web='12',
    video='11',
    download='1',
}

-- 每一类数据的比重weight
local hwqos_seq_prio={
    auto  ={game=12,web=8,video=4,download=1},
    game  ={game=12,web=8,video=4,download=1},
    web   ={web=10,game=6,video=4,download=1},
    video ={video=8,game=6,web=4,download=1},
}

-- softqos上下文
local softqos_ctx={
    UP={
        dev={
            id="wan",
            ifname="eth1",
        },
        main_handle=0x01,
        default={
            limit=0,
            handle='0xff0',
        },
        root={
            rate=0,
            handle=0x01,
        },
        host={
            limit=1.0,
            handle='ip',
            fw="000000/0xff000000",
            fwprio='2',
        },
        guest={
            handle='0xffe',
            fw="0x00040000/0x000f0000",
            fwprio='3',
        },
        xq={
            handle='0xfff',
            fw="0x00050000/0x000f0000",
            fwprio='3',
        },
    },
    DOWN={
        dev={
            id="lan",
            ifname="ifb0",
        },
        main_handle=0x02,
        default={
            limit=0,
            handle='0xff0',
        },
        root={
            rate=0,
            handle=0x01,
        },
        host={
            limit=1.0,
            handle='ip',
            fw="000000/0xff000000",
            fwprio='2',
        },
        guest={
            handle='0xffe',
            fw="0x00040000/0x000f0000",
            fwprio='3',
        },
        xq={
            handle='0xfff',
            fw="0x00050000/0x000f0000",
            fwprio='3',
        },
    },
}



local function run_cmd_tblist(tblist, ignore_error)
    local outlog ='/tmp/miqos.log'
    for _,v in pairs(tblist) do
        local cmd = v

        if g_debug then
            logger(3, '++' .. cmd)
            cmd = cmd .. ' >/dev/null 2>>' .. outlog
        else
            cmd = cmd .. " &>/dev/null "
        end

        if os.execute(cmd) ~= 0 and not ignore_error then
            if g_debug then
                os.execute('echo "^^^ '.. cmd .. ' ^^^ " >>' .. outlog)
            end
            logger(3, '[ERROR]:  ' .. cmd .. ' failed!')
            return false
        end
    end

    return true
end

-----------------soft qos part-----------
local function softqos_clean_rules()
    local tblist={}

    for k,v in pairs(softqos_ctx or {}) do
        table.insert(tblist, string.format("tc qdisc del dev " .. v.dev.ifname .. ' root '))
    end
    run_cmd_tblist(tblist, true)
end

local function softqos_update_xq_guest_rules(node, tblist, bands, act)
    if act ~= 'add' and act ~= 'replace' then
        return
    end

    if not bands[UP] or not bands[DOWN] or tonumber(bands[UP]) < 8 or tonumber(bands[DOWN]) < 8 then
        logger(3,"bands not valid for softqos. keep empty QoS rules.")
        return
    end

    for dir,v in pairs(softqos_ctx or {}) do

        local dev,main_handle=v.dev.ifname,v.main_handle
        local root_class_handle = v.root.handle
        local node_class_handle=v[node].handle
        local node_rate=math.ceil(cfg[node][dir]*0.2)
        local node_ceil=tonumber(cfg[node][dir])
        local buffer,cbuffer=get_burst(node_ceil)
        if node_rate < 80 then
            node_rate = 80
        end
        if node_rate > node_ceil then
            node_rate = node_ceil
        end
        if act == 'replace' then
            -- class
            table.insert(tblist, string.format(" tc class replace dev %s parent %s:%s classid %s:%s htb rate %s%s ceil %s%s burst %d cburst %d quantum 1600 ",
                dev, main_handle, dec2hexstr(root_class_handle), main_handle, dec2hexstr(node_class_handle), node_rate, UNIT, node_ceil, UNIT, buffer,cbuffer))
        else
            -- class
            table.insert(tblist, string.format(" tc class add dev %s parent %s:%s classid %s:%s htb rate %s%s ceil %s%s burst %d cburst %d quantum 1600 ",
                dev, main_handle, dec2hexstr(root_class_handle), main_handle, dec2hexstr(node_class_handle), node_rate, UNIT, node_ceil, UNIT, buffer,cbuffer))
            -- filter
            table.insert(tblist, string.format(" tc filter add dev %s parent %s: prio %s handle %s fw classid %s:%s",
                dev, main_handle, v[node].fwprio, v[node].fw, main_handle, dec2hexstr(node_class_handle)))
            -- leaf class
            apply_leaf_qdisc(tblist,dev, main_handle, dec2hexstr(node_class_handle), node_ceil, true)
        end
    end
end

local function softqos_refresh_main_rules(bands)
     -- 清除已经存在的规则
    softqos_clean_rules()

    if not bands[UP] or not bands[DOWN] or tonumber(bands[UP]) < 8 or tonumber(bands[DOWN]) < 8 then
        logger(3,"bands not valid for softqos. keep empty QoS rules.")
        return
    end

    local tblist={}

    for dir,v in pairs(softqos_ctx or {}) do
        local dev,main_handle=v.dev.ifname,v.main_handle
        -- root qdisc
        table.insert(tblist, string.format(" tc qdisc add dev %s root handle %s: htb default %s ",
            dev, main_handle, dec2hexstr(v.default.handle)))

        ------------root------------------
        local root_class_handle=v.root.handle
        local root_rate=tonumber(bands[dir])
        -- root class
        table.insert(tblist, string.format(" tc class add dev %s parent %s: classid %s:%s htb rate %s%s quantum 3200 ",
            dev, main_handle, main_handle, dec2hexstr(v.root.handle), root_rate, UNIT))

        ------------default----------------
        local default_class_handle=v.default.handle
        local default_rate=math.ceil(root_rate * 0.5)
        local default_ceil=tonumber(root_rate)
        -- default class
        table.insert(tblist, string.format(" tc class add dev %s parent %s:%s classid %s:%s htb rate %s%s ceil %s%s quantum 3200 ",
            dev, main_handle, dec2hexstr(v.root.handle), main_handle, dec2hexstr(default_class_handle), default_rate,UNIT, default_ceil, UNIT))
        -- leaf class
        apply_leaf_qdisc(tblist,dev, main_handle, dec2hexstr(default_class_handle),default_ceil, true)

    end

    -- guest
    softqos_update_xq_guest_rules('guest', tblist, bands, 'add')
    -- xq
    softqos_update_xq_guest_rules('xq', tblist, bands, 'add')

    g_softqos_main=1

    run_cmd_tblist(tblist)
end


local function softqos_refresh_rules(bands)

    if not bands[UP] or not bands[DOWN] or tonumber(bands[UP]) < 8 or tonumber(bands[DOWN]) < 8 then
        logger(3,"bands not valid for softqos. keep empty QoS rules.")
        return
    end

    if softqos_main == 1 then
        -- skip update main frame is it's done
        g_softqos_main = 0
    else
        softqos_refresh_main_rules(bands)
    end

    local tblist={}
    -- root handle

    for dir,v in pairs(softqos_ctx or {}) do
        local root_class_handle = v.root.handle
        local dev,main_handle=v.dev.ifname,v.main_handle
        -- refresh all soft-UDF list
        for mac,limit in pairs(UDF_softQ_table or {}) do
            local u_class_handle=limit.id
            local u_rate=80
            local u_ceil=tonumber(limit[dir] or '0')
            if u_ceil <= 0 then
                u_ceil = tonumber(bands[dir])
            elseif u_ceil <= 1 then
                u_ceil = math.ceil(bands[dir]*u_ceil)
            elseif u_ceil < 8 then
                u_ceil = 8
            end
            local u_prio='1'
            local u_fwmark=v.host.fw
            -- user class
            table.insert(tblist, string.format(" tc class add dev %s parent %s:%s classid %s:%s htb rate %s%s ceil %s%s quantum 3200 ",
                dev, main_handle, dec2hexstr(root_class_handle), main_handle, dec2hexstr(u_class_handle), u_rate, UNIT, u_ceil, UNIT))
            -- user filter
            table.insert(tblist, string.format(" tc filter add dev %s parent %s: prio %s handle 0x%s%s fw classid %s:%s ",
                dev, main_handle, u_prio, dec2hexstr(u_class_handle), u_fwmark, main_handle, dec2hexstr(u_class_handle)))

            -- leaf class
            apply_leaf_qdisc(tblist,dev, main_handle, dec2hexstr(u_class_handle),u_ceil, true)
        end
    end

    run_cmd_tblist(tblist)

end
---------------------------------------

local function reset_ipset_list()
    local tblist={}
    -- 如果ipset 创建不成功,则重新执行一次miqosd_init脚本来创建规则
    table.insert(tblist, "ipset -L -n -q|grep " .. ipset_skip_hwqos_name .. " || " .. miqosd_init_script)
    table.insert(tblist, "ipset -q flush " .. ipset_skip_hwqos_name)
    run_cmd_tblist(tblist, true)
end

-- 每次均简单的flush set,然后再添加ip进set
local function update_ipset_list()
    -- 每次都先flush再添加
    reset_ipset_list()

    local tblist={}
    for k,v in pairs(UDF_softQ_ipset or {}) do
        table.insert(tblist, string.format("ipset add %s %s",ipset_skip_hwqos_name, v.ip))
    end

    run_cmd_tblist(tblist, true)
end

-- 在清除所有的规则后，需要清除已经记录的设备列表
local function clean_device_list()
    for _ip,_dev in pairs(device_list) do
        device_list[_ip].net = nil
        device_list[_ip].limit = nil
        device_list[_ip] = nil
    end
end


-- down > up, sch0->down, sch1->up
-- up > down, sch0->up, sch1->down
local function prepare_sch_rate(band)
    local enable=0
    local up,down = band[UP], band[DOWN]
    if up and down then
        if tonumber(up)+0 > 0 and tonumber(down)+0 > 0 then
            hwqos_table['sch_rate'].UP.rate = 1000000
            hwqos_table['sch_rate'].DOWN.rate = math.ceil(tonumber(down))
            hwqos_table['sch_rate'].UP.en = 1
            hwqos_table['sch_rate'].DOWN.en = 1
        else
            hwqos_table['sch_rate'].UP.en = 0
            hwqos_table['sch_rate'].DOWN.en = 0
        end

        -- 因为设定上行方向SCH为1G, 所以只能hardcode
        --if math.ceil(tonumber(up)) > math.ceil(tonumber(down)) then
        if math.ceil(1000000) > math.ceil(tonumber(down)) then
            -- MTK suck rule: sch0 with larger band-limit
            hwqos_table['sch_rate'].UP.id = '0'
            hwqos_table['sch_rate'].DOWN.id = '1'
        else
            hwqos_table['sch_rate'].UP.id = '1'
            hwqos_table['sch_rate'].DOWN.id = '0'
        end
    else
        hwqos_table['sch_rate'].UP.en = 0
        hwqos_table['sch_rate'].DOWN.en = 0
    end
end

-- step1. sch
-- cond: 判断是否执行此sch
local function apply_sch_rate_data(band, cond)
    local tblist={}

    prepare_sch_rate(band)

    for k,v in pairs(hwqos_table['sch_rate'] or {}) do
        if not cond or cond(v) then
            table.insert(tblist, string.format("qdma sch_rate %s %d %s", v['id'], v['en'] or 0, tostring(v['rate'] or 0)))
        end
    end

    if not run_cmd_tblist(tblist) then
        logger(3, 'ERROR: apply qdma rule failed!')
        return false
    end
    return true
end

-- cond: 判断是否执行此q
local function apply_q_rate_data(data, bands, cond)
    local tblist={}

    -- 16 queues
    for k,v in pairs(data['q_rate'] or {}) do
        if not cond or cond(v) then
            -- resv data
            table.insert(tblist, string.format("qdma resv %s %d %d", k, v['resv'] or 30, v['resv'] or 30))

            -- assing to sch
            table.insert(tblist, string.format("qdma sch %s %d", k, data['sch_rate'][v['sch']].id))

            -- assign rate
            local min_rate_v = v['min_rate'] or 0
            local max_rate_v = v['max_rate'] or 0

            if tonumber(v['min_rate']) > 0 and tonumber(v['min_rate']) <= 1 then
                min_rate_v = math.ceil(v['min_rate']*bands[v['sch']])
            end
            if tonumber(v['max_rate']) >= 0 and tonumber(v['max_rate']) <= 1 then
                max_rate_v = math.ceil(v['max_rate']*bands[v['sch']])
                if v['max_rate'] == 0 and v['max_en'] == 1 then
                    max_rate_v = math.ceil(bands[v['sch']])
                end
            end

            table.insert(tblist, string.format("qdma rate %s %s %s %s %s", k,
                        v['min_en'] or 0, min_rate_v,
                        v['max_en'] or 0, max_rate_v))

            -- assign weight
            table.insert(tblist, string.format("qdma weight %s %d", k, v['w'] or 1))
        end
    end

    if not run_cmd_tblist(tblist) then
        logger(3, 'ERROR: apply qdma rule failed!')
        return false
    end
    return true
end

-- step0. clean all rules before applying.
local function reset_all_rule_template()
    local tblist={}

    -- 2 sch_rate
    for k,v in pairs(hwqos_table['sch_rate'] or {}) do
        table.insert(tblist, string.format("qdma sch_rate %s %d %s", v['id'], 0, 0))
    end

    -- 15 queue
    for k,v in pairs(hwqos_table['q_rate'] or {}) do
        -- resv hwqos_table
        table.insert(tblist, string.format("qdma resv %s %d %d", k, 30, 30))

        -- assing to sch
        table.insert(tblist, string.format("qdma sch %s %d", k, hwqos_table['sch_rate'][v['sch']].id))

        -- assign rate
        table.insert(tblist, string.format("qdma rate %s %d %s %d %s", k, 0,0,0,0))

        -- assign weight
        table.insert(tblist, string.format("qdma weight %s %d", k, 0))
    end

    if not run_cmd_tblist(tblist) then
        logger(3, 'ERROR: apply qdma rule failed!')
        return false
    end
    return true
end

local function get_hwqos_seq_prio(seq,flow_type)
    local prio_seq=hwqos_seq_prio[seq] or hwqos_seq_prio['auto']
    return prio_seq[flow_type] or prio_seq['download']
end

local function prepare_hwqos_seq_prio()
    for k,v in pairs(DOWN_Q) do
        if hwqos_table['q_rate'][v] then
            hwqos_table['q_rate'][v].w = get_hwqos_seq_prio(cfg.flow.seq,k)
        end
    end
end

-- XXX: FLOW定义的数据
local function apply_flow_rules(bands)
    if g_debug then logger(3,"=====apply flow rules.") end
    prepare_hwqos_seq_prio()
    apply_q_rate_data(hwqos_table, bands, function (q) return q.own == 'flow' end)
end

local function prepare_guest_data(uplimit, downlimit)
    if uplimit > 0 and downlimit > 0 then
        hwqos_table.q_rate[QUEST_Q[UP]].max_en=1
        hwqos_table.q_rate[QUEST_Q[UP]].max_rate=uplimit
        hwqos_table.q_rate[QUEST_Q[DOWN]].max_en=1
        hwqos_table.q_rate[QUEST_Q[DOWN]].max_rate=downlimit
    else
        hwqos_table.q_rate[QUEST_Q[UP]].max_en=1
        hwqos_table.q_rate[QUEST_Q[UP]].max_rate=cfg.guest.default
        hwqos_table.q_rate[QUEST_Q[DOWN]].max_en=1
        hwqos_table.q_rate[QUEST_Q[DOWN]].max_rate=cfg.guest.default
    end
end

-- XXX: guest网络数据
local function apply_guest_rules(bands)
    if g_debug then logger(3,"=====apply guest rules.") end
    prepare_guest_data(cfg.guest.UP, cfg.guest.DOWN)
    apply_q_rate_data(hwqos_table, bands, function (q) return q.own == 'guest' end)
end

-- 清除所有SOFTQOS用户
local function reset_softqos_user_rules()
    softqos_clean_rules()
end

local function try_reset_hwqos_user_rules(tblist)
    for k,v in pairs(hwqos_table.q_rate) do
        if v.own == 'user' then
            table.insert(tblist, string.format("qdma rate %s 0 0 0 0", k))
            table.insert(tblist, string.format("qdma sch %s 0", k))
            hwqos_table.q_rate[k].mac = nil
            hwqos_table.q_rate[k].q = nil
        end
    end

    table.insert(tblist, "[ -f /proc/sys/net/hwqos/m2q_ip ] && echo ff > /proc/sys/net/hwqos/m2q_ip && hwnat -F")
end

-- 清除所有的HWQOS用户
local function reset_hwqos_user_rules()
    local tblist={}

    try_reset_hwqos_user_rules(tblist)

    run_cmd_tblist(tblist, true)
end

-- 清空所有soft+hard QoS用户
local function reset_all_user_rules()
    if g_debug then logger(3,"=====reset all hw-qos/soft-qos users.") end

    reset_hwqos_user_rules()
    reset_softqos_user_rules()

    -- flush ipset 规则
    reset_ipset_list()

    UDF_Q_table={}
    UDF_softQ_table={}
    UDF_softQ_ipset={}
end

-- XXX: 用户定义数据
local function apply_UDF_hardQ_rules(bands)
    if g_debug then logger(3,"=====apply UDF HardQ rules.") end

    apply_q_rate_data(hwqos_table, bands, function(q)
                                            if q.own == 'user' and q.changed then
                                                q.changed = false
                                                return true
                                            end
                                            return false
                                        end)
end

local function apply_UDF_softQ_rules(bands)
    if g_debug then logger(3,"=====apply UDF SoftQ rules.") end

    -- 更新softqos的tc规则
    softqos_refresh_rules(bands)
    -- 将对应ip加入到hwnat禁止列表中
    update_ipset_list()

    -- 清除soft Q table
    UDF_softQ_table={}
    UDF_softQ_ipset={}
end


--设置主flow的配置
function apply_main_rules(bands)
    if g_debug then logger(3,"=====apply main rules.") end
    -- schedulers
    apply_sch_rate_data(bands)

    -- flow-Q
    apply_flow_rules(bands)

    -- guest-Q
    apply_guest_rules(bands)

    -- xq-Q apply later
    -- user-Q apply later
end

-- 清理qdisc规则
function qdisc_df.clean(devs)
    -- 清掉所有用户的限速配置
    reset_all_user_rules()
    -- 清理所有的rule规则
    reset_all_rule_template()

    -- 清除设备列表以便于重建
    clean_device_list()

    cfg.qos_type.changed = true

end

-- type(mask) must be number
local function if_ip_in_same_subnet(ipa, ipb, mask)
    if ipa==nil or ipb==nil or mask==nil then
        return false
    end

    local cidr_a = lip.IPv4(ipa)
    local cidr_b = lip.IPv4(ipb)

    if cidr_a and cidr_b then
        local neta = lip.cidr.network(cidr_a, mask)
        local netb = lip.cidr.network(cidr_b, mask)
        if neta and netb then
            local eq = lip.cidr.equal(neta, netb)
            return eq
        end
    end

    return false
end


-- 规则后更新device列表信息
local function update_device_list_post_rule()
    for _ip,_dev in pairs(device_list) do
        if _dev.net['new'] == '' then       -- 删除已经下线的设备
            device_list[_ip].net = nil
            device_list[_ip].limit = nil
            device_list[_ip] = nil
        else
            _dev.net['old']=_dev.net['new']
            _dev.net['new']=''
            _dev.limit['changed']=0
        end
    end
end

-- 规则前更新device列表信息
-- 假定： 同一mac可以有不同ip，但是所有的ip地址唯一，相同ip地址将被认为是一个设备
-- 只留存/更新有限速配置的设备
local function update_device_list_pre_rule()

    local ret=g_ubus:call("trafficd","hw",{})

    online_device_list={}

    -- 更新new ipmac 表
    for _,v in pairs(ret or {}) do
        local mac, wifi=v['hw'], false
        if string.find(v['ifname'],"wl",1) then
            wifi = true  -- wifi device
        end

        for _,ips in pairs(v['ip_list'] or {}) do
            local valid_ip = false
            -- 检查ip地址的在线状态by ageingtime
            if wifi and v['assoc'] == 1 then     -- wifi, assoc会在掉线后立即变成0
                valid_ip = true
            elseif not wifi and ips['ageing_timer'] <= service_cfg.online_timeout.wi then  -- wire
                valid_ip = true
            end

            if valid_ip then
                -- 判断主副网络
                local net_type = 'guest'  -- 默认先划到guest网络
                local ip,valid_ip,nid = ips['ip'], false, string.split(ips['ip'],'.')[4]
                if cfg.lan.ip and cfg.lan.mask then
                    local same_subnet = if_ip_in_same_subnet(ip, cfg.lan.ip, tonumber(cfg.lan.mask))

                    if same_subnet then     -- host网络
                        net_type = 'host'
                    end
                end

                online_device_list[ip]={mac=mac,UP={},DOWN={}}
                -- 获取设备的maxlimit限速
                local max_up,max_down=0,0
                if g_group_def[mac] then
                    max_up = math.ceil(g_group_def[mac]['max_grp_uplink'] or '0')
                    max_down = math.ceil(g_group_def[mac]['max_grp_downlink'] or '0')
                    online_device_list[ip][UP].max_per = max_up
                    online_device_list[ip][DOWN].max_per = max_down
                end

                -- 不需要单独做限速的设备(未设置限速，或者限速超出范围)
                if (max_up < 8 or max_up > math.ceil(cfg.bands.UP)) and
                    (max_down < 8 or max_down > math.ceil(cfg.bands.DOWN)) then
                    if device_list[ip] then
                        device_list[ip].net.new = ''   -- 需要删除此节点
                    end
                else
                    -- 如果未指定单方限速，则不限速
                    if max_up < 8 then max_up = 0 end
                    if max_down < 8 then max_down = 0 end
                    -- 更新device状态信息
                    if not device_list[ip] then  -- 新加入的设备
                        device_list[ip]={
                            mac=mac,
                            id=nid,     -- 如果nid为空，则不需要单独进行限速
                            ip=ip,
                            net={old='',new=net_type},  -- 初始化
                            limit={
                                UP=max_up,
                                DOWN=max_down,
                                changed=1,
                            },
                        }
                    else
                        local dev = device_list[ip]
                        dev.net['new'] = net_type
                        if dev.limit.UP ~= max_up or dev.limit.DOWN ~= max_down then
                            logger(3,"limit changed, mac: " .. mac .. ',ip: ' .. ip ..',UP:'
                                ..dev.limit.UP..'->'..max_up..',DOWN:'..dev.limit.DOWN..'->'..max_down)
                            device_list[ip]['limit']={      -- 更新如果最高限速条件改变
                                UP=max_up,
                                DOWN=max_down,
                                changed=1
                            }
                        end
                    end
                end
            end
        end
    end

end

-- 以下行速率为条件进行排序
local cmp_func=function(t, a, b)
    local ret = t[a].changed ~= 'del' and (t[b].changed == 'del'
                or (t[a].limit and (not t[b].limit
                or (t[a].limit.DOWN and (not t[b].limit.DOWN or t[a].limit.DOWN > t[b].limit.DOWN))
                --or (t[a].limit.UP and (not t[b].limit.UP or t[a].limit.UP > t[b].limit.UP))
                )))

    return ret
end

function spairs(t, order)
    -- collect the keys
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end

    -- if order function given, sort by it by passing the table and keys a, b,
    -- otherwise just sort the keys
    if order then
        table.sort(keys, function(a,b) return order(t, a, b) end)
    else
        table.sort(keys)
    end

    -- return the iterator function
    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return keys[i], t[keys[i]]
        end
    end
end

-- 更新对应的UDF_Q_table记录
local function apply_rule_for_single_device(act, dev)
    local tblist={}
    local mac=dev.mac

    if act == 'add' then
        if UDF_Q_table[mac] then
            logger(3, "error: mac " .. mac .. " to be added, but it's already exist.")
        else
            UDF_Q_table[mac]={
                mac=mac,
                ip=dev.ip,
                id=dev.id,
                limit=dev.limit,
                q={
                    UP=0,
                    DOWN=0,
                },
                changed='add',
            }
            logger(3, " + mac " .. mac ..',ip ' .. dev.ip)
        end
    elseif act == 'del' then
        if UDF_Q_table[mac] then
            UDF_Q_table[mac].changed = 'del'
            logger(3, " - mac " .. mac ..',ip ' .. dev.ip)
        else
            logger(3, "error: mac " .. mac .. " to be deleted, but it's not exist.")
        end
    elseif act == 'change' then
        if UDF_Q_table[mac] then
            UDF_Q_table[mac].ip = dev.ip
            UDF_Q_table[mac].limit = dev.limit
            UDF_Q_table[mac].changed = 'chg'
            logger(3, " ~ mac " .. mac ..',ip ' .. dev.ip)
        else
            logger(3, "error: mac " .. mac .. " to be changed, but it's not exist.")
        end
    else
        logger(3,'not supported action.')
    end

end

local function find_free_UDF_Q(q_data)
    local ret={}
    local num = 1
    for k,v in spairs(hwqos_table['q_rate'] or {}, function(t,a,b) return tonumber(a) > tonumber(b) end ) do
        if v.own == 'user' then
            if not v.mac or v.mac == '' then
                if q_data[num] then
                    ret[q_data[num]] = k
                    num = num + 1
                end

                -- 已经填满,则返回
                if not q_data[num] then
                    return ret
                end
            end
        end
    end
    if g_debug then logger(3,"*****NOT found enough free HWQOS Q") end
    return nil
end

local function assign_ip_to_hard_q(tblist, ip, id, dir, q)
    local tmp_id = id
    if dir == DOWN then
        tmp_id = tmp_id + 256
    end
    table.insert(tblist, string.format(
        "[ -f /proc/sys/net/hwqos/m2q_ip ] && echo %s:%s > /proc/sys/net/hwqos/m2q_ip ||:", tmp_id, q))
    refresh_hwnat_ip_list[ip] = 1
    if g_debug then logger(3,'assign ' .. ip .. ' '.. dir .. ' to Q' .. q) end
    return tmp_id
end

local function assign_ip_to_soft_q(tblist, ip, id, dir, q)
    refresh_hwnat_ip_list[ip] = 1
end

local function refresh_hwnat_for_changed_IPs()
    local tblist={}
    for k,v in pairs(refresh_hwnat_ip_list or {}) do
        table.insert(tblist, string.format("hwnat -E %s 255.255.255.255 >/dev/null 2>&1", k))
    end
    refresh_hwnat_ip_list={}

    run_cmd_tblist(tblist)
end

local function prepare_UDF_data(tblist)
    local changed = false
    local limit_queues = 0
    local flag_reset_all_qos = false

    --[[
    -- run only once to get total UDF queues
    if total_user_queues <= 0 then
        for k,v in pairs(hwqos_table['q_rate'] or {}) do
            if v.own == 'user' then
                total_user_queues = total_user_queues + 1
            end
        end
        logger(3,'total user_defined_hw_Q = ' .. total_user_queues)
    end
    --]]

    for k,v in pairs(UDF_Q_table or {}) do
        if v.changed ~= 'keep' then
            changed = true
        end
    end
    if not changed then return changed end

    if g_debug then logger(3, "update in progress.....") end

    -- prepare to reset hwqos all UDF queues
    try_reset_hwqos_user_rules(tblist)

    for k,v in spairs(UDF_Q_table or {}, cmp_func) do
        local Q_data=nil
        if v.changed == 'del' then
            for _,dir in pairs({UP, DOWN}) do
                if v.q and v.q[dir] ~= 0 then
                    -- clear hwqos classify
                    assign_ip_to_hard_q(tblist, v.ip, v.id, dir, 0)
                end
            end
            UDF_Q_table[k] = nil
        elseif v.changed == 'chg' or v.changed == 'add' or v.changed == 'keep' then
            for _,dir in pairs({UP, DOWN}) do
                if not v.limit[dir] or tonumber(v.limit[dir]) <= 0 then
                    if v.q and v.q[dir] ~= 0 then
                        -- clear hwqos classify
                        assign_ip_to_hard_q(tblist, v.ip, v.id, dir, 0)
                    end
                else
                    if not Q_data then Q_data = {} end
                    table.insert(Q_data,dir)
                    --logger(3,'********' .. v.ip .. dir .. ' into calc, limit: ' .. v.limit[dir])

                    -- 所有限速用户都要做softqos-限制,以防某些流某些情况下不走HWQOS而走了SOFTQOS
                    -- [这里是坑啊,无法完美解决问题]
                    if not UDF_softQ_table[v.mac] then
                        UDF_softQ_table[v.mac] ={}
                    end
                    UDF_softQ_table[v.mac][dir]=v.limit[dir]
                    UDF_softQ_table[v.mac].ip=v.ip
                    UDF_softQ_table[v.mac].id=v.id
                    --logger(3,"********" .. v.ip .. dir .. "," .. v.mac)

                end
            end
        end

        if Q_data then
            local free_Qs = find_free_UDF_Q(Q_data)
            if free_Qs then
                -- 获取到足够的HWQOS队列
                for dir,q in pairs(free_Qs) do
                    hwqos_table['q_rate'][q].mac = v.mac
                    hwqos_table['q_rate'][q].max_en = 1
                    hwqos_table['q_rate'][q].max_rate = v.limit[dir]
                    hwqos_table['q_rate'][q].sch=dir
                    hwqos_table['q_rate'][q].changed = true

                    UDF_Q_table[k].q[dir] = tostring(q)
                    assign_ip_to_hard_q(tblist, v.ip, v.id, dir, q)

                end
            else
                -- 未获取到足够的HWQOS队列, 则此IP转入soft-QoS
                for _,dir in pairs({UP,DOWN}) do
                    if g_debug then logger(3,string.format("%s, ip: %s, dir: %s, -->> into soft-queue.", v.mac, v.ip,  dir)) end

                    -- 转向记录softqos_ipset记录,这些ip不在用HWQOS做限制
                    if not UDF_softQ_ipset[v.mac] then
                        UDF_softQ_ipset[v.mac]={}
                    end
                    UDF_softQ_ipset[v.mac].ip=v.ip


                    if UDF_Q_table[k].q then
                        UDF_Q_table[k].q[dir] = nil
                    end
                    assign_ip_to_soft_q(tblist, v.ip, v.id, dir, 0)
                end
            end

            -- 更新UDF_Q_table表示此项已经处理完成
            UDF_Q_table[k].changed = 'keep'
        end
    end

    return changed

end

-- 根据限速规则已有基础规则上更新devices的限速规则（主规则不变）
local function apply_devices_rules(bands)

    -- 规则应用前更新设备列表
    update_device_list_pre_rule()

    for _ip,_dev in pairs(device_list) do
        if _dev.net.old == '' then      -- 全新的设备节点
            if _dev.net.new == 'host' then --暂时只支持主网络
                if _dev.limit.UP ~= 0 or _dev.limit.DOWN ~= 0 then  -- 需要进行限速
                    --主网络新增限速节点
                    apply_rule_for_single_device('add', _dev)
                end
            end
        elseif _dev.net.old == 'host' then      -- 设备以前是在主网络中
            if _dev.net.new == 'guest' then
                -- 1. 主网络删除限速节点
                apply_rule_for_single_device('del', _dev)
                -- 2. 访客网络增加节点（暂不支持访客网络，TODO）
            elseif _dev.net.new == 'host' then
                if _dev.limit.changed == 1 then     -- 需要更新设备的最高限速值
                    apply_rule_for_single_device('change', _dev)
                end
            else
                apply_rule_for_single_device('del', _dev)
            end
        else -- 设备以前是在访客网络中
            if _dev.net.new == 'host' then
                -- 1. 首先从访客网络中删除此节点（TODO）
                -- 2. 然后在添加到主网络中
                apply_rule_for_single_device('add', _dev)
            else
                -- 修改访客网络中节点的限速值（TOOD）
            end
        end
    end

    -- 生成user-defined-limit限速规则
    local tblist={}
    if prepare_UDF_data(tblist) then
        if tblist then
            run_cmd_tblist(tblist)
        end

        apply_UDF_hardQ_rules(bands)

        apply_UDF_softQ_rules(bands)

        -- 更新hwnat中已经存在的ip列表
        refresh_hwnat_for_changed_IPs()
    end

    -- 规则应用后更新设备列表
    update_device_list_post_rule()

    return true
end

-- 'host'模式htb下，每次都返回true，在apply里面进行changed检测
function qdisc_df.changed()
    return true
end

-- 根据bands变化，更新设备的默认预留带宽
-- 按照平均可以支持15个客户端来均分预留,最低预留(UP:5kb/s,DOWN:10kb/s)
local function update_rate_value(limit)
    local up,down= math.ceil(limit[UP]/15.0), math.ceil(limit[DOWN]/15.0)
    if up < 40 then up = 40.0 end
    if down < 80 then down = 80.0 end
    return {UP=up,DOWN=down}
end

-- 检查是否需要更新访客网络限速
local function check_if_need_update_guest_network(bands)
    local strlog,flag='', false
    if cfg.guest.changed == 1 then       -- guest限速变化
        strlog = strlog .. '/guest'
        cfg.guest.changed = 0
        flag = true
    end

    if strlog ~= '' then
        logger(3,'CHANGE: ' .. strlog)
    end

    if flag then
        apply_guest_rules(bands)

        local tblist={}
        softqos_update_xq_guest_rules('guest', tblist, bands, "replace")
        run_cmd_tblist(tblist);
    end
end

local function check_if_need_update_xq_network(bands)
    local strlog,flag='', false
    if cfg.xq.changed == 1 then       -- guest限速变化
        strlog = strlog .. '/xq'
        cfg.xq.changed = 0
        flag = true
    end

    if strlog ~= '' then
        logger(3,'CHANGE: ' .. strlog)
    end

    if flag then
        local tblist={}
        softqos_update_xq_guest_rules('xq', tblist, bands, "replace")
        run_cmd_tblist(tblist);
    end
end

local function check_if_hwqos_dismatch(cur_on)
    local status = run_cmd('cat /proc/sys/net/hwqos/enable 2>/dev/null')
    if status == "0" then
        return cur_on == true
    else
        return cur_on == false
    end
end

-- 检查是否需要更新整体限速结构
local function check_if_need_update_service_mainframe(clean_flag, origin_disc, devs, bands)
    local strlog,flag='', false

    if cfg.qos_type.changed then    -- 限速模式是否变化
        strlog = strlog .. '/qos type'
        cfg.qos_type.changed=false
        flag = true
    end

    if cfg.bands.changed then        --整体带宽值变化
        strlog = strlog .. '/bandwidth'
        cfg.bands.changed=false
        flag = true
    end

    if cfg.supress_host.changed then   -- 游戏优先压制host带宽
        strlog = strlog .. '/supress switch'
        cfg.supress_host.changed=false
        flag = true
    end

    rate_for_each=update_rate_value(bands)   -- 计算每个设备的预留rate

    if cfg.flow.changed then
        strlog = strlog .. '/service_prio'
        cfg.flow.changed=false
        flag=true
    end

    if check_if_hwqos_dismatch(cfg.enabled.flag ~= '0') then
        strlog = strlog .. '/hwqos dismatch'
        flag =true
    end

    if strlog ~= '' then
        logger(3,'CHANGE: ' .. strlog)
    end

    if clean_flag or flag then
        qdisc[THIS_QDISC].clean(nil)
        -- 更新主框架
        apply_main_rules(bands)

        softqos_refresh_main_rules(bands)
    end



    check_if_need_update_guest_network(bands)

    check_if_need_update_xq_network(bands)

    return flag
end

function qdisc_df.read_qos_config()

    -- 读取group-host的配置
    if not read_qos_group_config() then
        logger(3,'read_qos_group_config failed.')
        return false
    end

    -- 读取guest+xq的配置
    if not read_qos_guest_xq_config() then
        logger(3,'read_qos_guest_xq_config failed.')
        return false
    end

    return true
end

-- dataflow的qdisc规则应用
-- clean_flag: clean whole rules before applying new rule if true
function qdisc_df.apply(origin_qdisc, bands, devs, clean_flag)

    -- origin_qdisc来决定如何处理已经存在的qdisc
    local act,clevel='add','0'

    -- 判断old qdisc是否有效
    if origin_qdisc then
        if not qdisc[origin_qdisc] then
            logger(3, 'ERROR: qdisc `' .. origin_qdisc .. '` not found. ')
            return false
        end
    end

    -- qdisc未变化
    local _clean_flag = clean_flag
    if cfg.enabled.changed then
        cfg.enabled.changed = false
        if cfg.enabled.flag == '0' then
            qdisc_df.clean(nil)
            return true
        else
            _clean_flag = true
        end
    elseif cfg.enabled.flag == '0' then
        return true
    end

    -- 更新mainframe框架
    check_if_need_update_service_mainframe(_clean_flag, origin_disc, devs, cfg.bands)

    apply_devices_rules(bands)

    return true
end

function qdisc_df.update_counters(devs)
    if cfg.enabled.flag == '0' then
        return {}
    end

    local data={}
    for _ip,_dev in pairs(online_device_list) do
        local on_flag = 'on'
        if not g_group_def[_dev.mac] then
            on_flag = 'off'
        elseif g_group_def[_dev.mac].flag then
            on_flag = g_group_def[_dev.mac].flag
        elseif tonumber(g_group_def[_dev.mac]['max_grp_uplink'] or 0) <= 0 or tonumber(g_group_def[_dev.mac]['max_grp_downlink'] or 0) <= 0 then
            on_flag = 'off'
        end

        data[_ip]={
            MAC=_dev.mac,
            UP={min=0,min_per=0,min_cfg=0,max=0 .. 'Kbit',max_per=_dev.UP.max_per or 0,max_cfg=0},
            DOWN={min=0,min_per=0,min_cfg=0,max=0 .. 'Kbit',max_per=_dev.DOWN.max_per or 0,max_cfg=0},
            flag=on_flag,
        }
        if device_list[_ip] then
            data[_ip].UP.max = device_list[_ip].limit.UP or 0 .. 'Kbit'
            data[_ip].DOWN.max = device_list[_ip].limit.DOWN or 0 .. 'Kbit'
        end
    end

    return data
end
