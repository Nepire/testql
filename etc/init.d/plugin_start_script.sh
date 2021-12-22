#!/bin/sh /etc/rc.common
# Copyright (C) 2010-2012 OpenWrt.org

START=98
STOP=20

start()
{
	netmode=$(uci get xiaoqiang.common.NETMODE)
	if [ "$netmode"x != "lanapmode"x ] && [ "$netmode"x != "wifiapmode"x ]
	then
		copy_plugin_chroot_file
		sync
		# decrese current priority and throw myself to mem cgroup
		# so all plugins inherit those attributes
		renice -n+10 -p $$
		echo $$ > /dev/cgroup/mem/group1/tasks
		/usr/sbin/plugin_start_impl_standalone_hd.sh nonResourcePlugin &
	fi
}

stop()
{
	/usr/sbin/plugin_stop_impl_standalone_hd.sh
}
