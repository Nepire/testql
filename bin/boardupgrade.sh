#!/bin/sh
#

# R3 upgrade file

. /lib/upgrade/common.sh
. /lib/upgrade/libupgrade.sh

stop_service(){
	/etc/init.d/xunlei stop &
	/etc/init.d/noflushd stop &

	echo 3 > /proc/sys/vm/drop_caches
}

restore_service(){
	/etc/init.d/xunlei start
	/etc/init.d/noflushd start
}


board_prepare_upgrade() {
	stop_service
}

board_start_upgrade_led() {
	gpio l 8 0 4000 0 0 0 # blue: off
	gpio l 10 10 10 1 0 4000 # yellow: blink
	gpio l 6 0 4000 0 0 0 # red: off
}

board_system_upgrade() {
	local filename=$1
	uboot_mtd=$(grep Bootloader /proc/mtd | awk -F: '{print substr($1,4)}')
	crash_mtd=$(grep -m 1 crash /proc/mtd | awk -F: '{print substr($1,4)}')
	kernel0_mtd=$(grep kernel0 /proc/mtd | awk -F: '{print substr($1,4)}')
	kernel1_mtd=$(grep kernel1 /proc/mtd | awk -F: '{print substr($1,4)}')
	rootfs0_mtd=$(grep rootfs0 /proc/mtd | awk -F: '{print substr($1,4)}')
	rootfs1_mtd=$(grep rootfs1 /proc/mtd | awk -F: '{print substr($1,4)}')

	rootfs_mtd_current=$(($rootfs0_mtd+$(nvram get flag_boot_rootfs)))
	rootfs_mtd_target=$(($rootfs0_mtd+$rootfs1_mtd-$rootfs_mtd_current))
	kernel_mtd_current=$(($rootfs_mtd_current-2))
	kernel_mtd_target=$(($kernel0_mtd+$kernel1_mtd-$kernel_mtd_current))

	pipe_upgrade_uboot $uboot_mtd $filename
	pipe_upgrade_kernel $kernel_mtd_target $filename
	pipe_upgrade_rootfs_squashfs $rootfs_mtd_target $filename

	# back up etc
	rm -rf /data/etc_bak
	cp -prf /etc /data/etc_bak
}
