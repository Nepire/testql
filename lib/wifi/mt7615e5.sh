#!/bin/sh
append DRIVERS "mt7615e5"

. /lib/wifi/ralink_common.sh

prepare_mt7615e5() {
	prepare_ralink_wifi mt7615e5
}

scan_mt7615e5() {
	scan_ralink_wifi mt7615e5 mt7615e
}

disable_mt7615e5() {
	iwpriv wl0 set hw_nat_register=0
	disable_ralink_wifi mt7615e5
}

enable_mt7615e5() {
	enable_ralink_wifi mt7615e5 mt7615e
	iwpriv wl0 set hw_nat_register=1
}

detect_mt7615e5() {
#	detect_ralink_wifi mt7612e mt76x2e
	ssid=`nvram get wl0_ssid`
	cd /sys/module/
	[ -d $module ] || return
	[ -e /etc/config/wireless ] && return
	 cat <<EOF
config wifi-device      mt7615e5
	 option type 'mt7615e5'
         option vendor 'ralink'
         option hwband '5G'
         option autoch '2'
         option radio '1'
         option hwmode '11ac'
         option channel '0'
         option bw '0'
         option country 'CN'
         option region '1'
         option aregion '0'
         option channel '0'
         option bw '0'
         option txpwr 'max'
         option txbf '3'

config wifi-iface
        option device   mt7615e5
        option ifname   wl0
        option network  lan
        option mode     ap
        option ssid     $ssid
        option encryption 'none'

config wifi-iface
        option device 'mt7615e5'
        option ifname 'apclii0'
        option network 'lan'
        option mode 'sta'
        option ssid $ssid
        option encryption 'none'
        option disabled '1'
EOF

}


