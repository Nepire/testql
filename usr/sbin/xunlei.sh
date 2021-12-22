#!/bin/sh /etc/rc.common

deviceId=`/usr/bin/matool --method idForVendor --params adaccf1f-8b8c-edcb-d533-770099d2ef20`
idForVendor=$deviceId
PIPE_PATH="/tmp/thunder/etm_hubble_report.pipe"

if [ -n "$idForVendor" ];then
	/usr/sbin/etm --system_path=/tmp/thunder --disk_cfg=/etc/config/thunder/thunder_mounts.cfg --etm_cfg=/etc/config/thunder/etm.ini --log_cfg=/etc/config/thunder/log.ini --deviceid=$deviceId --hardwareid=$idForVendor --pid_file=/var/run/xunlei.pid --license=16022400010000053000595txyl2jgthhdf1j8r0xn --import_v1v2_mode=2 --hubble_report_pipe_path=$PIPE_PATH --partnerid=595
fi

