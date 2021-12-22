#!/bin/sh

klogger() {
	local msg1="$1"
	local msg2="$2"

	if [ "$msg1" = "-n" ]; then
		echo -n "$msg2" >> /dev/kmsg 2>/dev/null
	else
		echo "$msg1" >> /dev/kmsg 2>/dev/null
	fi

	return 0
}

hndmsg() {
	if [ -n "$msg" ]; then
		echo "$msg"
		echo "$msg" >> /dev/kmsg 2>/dev/null

		echo $log > /proc/sys/kernel/printk
		stty intr ^C
		exit 1
	fi
}

uperr() {
	exit 1
}

pipe_upgrade_generic() {
	local package=$1
	local segment_name=$2
	local mtd_dev=mtd$3
	local ret=0

	mkxqimage -c $package -f $segment_name
	if [ $? -eq 0 ]; then
		klogger -n "Burning $segment_name to $mtd_dev ..."

		exec 9>&1

		local pipestatus0=`( (mkxqimage -x $package -f $segment_name -n || echo $? >&8) | \
			mtd write - /dev/$mtd_dev ) 8>&1 >&9`
		if [ -z "$pipestatus0" -a $? -eq 0 ]; then
			ret=0
		else
			ret=1
		fi
		exec 9>&-
	fi

	return $ret
}

pipe_upgrade_uboot() {
	if [ $1 ]; then
		pipe_upgrade_generic $2 uboot.bin $1
		if [ $? -eq 0 ]; then
			klogger "Done"
		else
			klogger "Error"
			uperr
		fi
	fi
}

pipe_upgrade_crash() {
	if [ $1 ]; then
		pipe_upgrade_generic $2 crash.bin $1
		if [ $? -eq 0 ]; then
			klogger "Done"
		else
			klogger "Error"
			uperr
		fi
	fi
}

pipe_upgrade_kernel() {
	if [ $1 ]; then
		pipe_upgrade_generic $2 uImage.bin $1
		if [ $? -eq 0 ]; then
			klogger "Done"
		else
			klogger "Error"
			uperr
		fi
	fi
}

pipe_upgrade_rootfs_squashfs() {
	if [ $1 ]; then
		pipe_upgrade_generic $2 root.squashfs $1
		if [ $? -eq 0 ]; then
			klogger "Done"
		else
			klogger "Error"
			uperr
		fi
	fi
}

upgrade_uboot() {
	local mtd_dev=mtd$1

	if [ -f uboot.bin -a $1 ]; then
		klogger -n "Burning uboot image to $mtd_dev ..."
		mtd write uboot.bin /dev/$mtd_dev
		if [ $? -eq 0 ]; then
			klogger "Done"
		else
			klogger "Error"
			uperr
		fi
	fi
}

upgrade_crash() {
	local mtd_dev=mtd$1

	if [ -f crash.bin -a $1 ]; then
		klogger -n "Burning crash image to $mtd_dev ..."
		mtd write crash.bin /dev/$mtd_dev
		if [ $? -eq 0 ]; then
			klogger "Done"
		else
			klogger "Error"
			uperr
		fi
	fi
}

upgrade_kernel() {
	local mtd_dev=mtd$1

	if [ -f uImage.bin -a $1 ]; then
		klogger -n "Burning kernel image to $mtd_dev ..."
		mtd write uImage.bin /dev/$mtd_dev
		if [ $? -eq 0 ]; then
			klogger "Done"
		else
			klogger "Error"
			uperr
		fi
	fi
}

# $1=mtd device name
# $2=src file name
upgrade_mtd_generic() {
	local mtd_dev="$1"
	local src_file="$2"

	if [ -f "$src_file" -a $mtd_dev ]; then
		klogger -n "Burning "$src_file" to $mtd_dev ..."
		mtd write "$src_file" $mtd_dev
		if [ $? -eq 0 ]; then
			klogger "Done"
		else
			klogger "Error"
			uperr
		fi
	fi
}

