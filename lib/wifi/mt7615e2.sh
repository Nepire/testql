#!/bin/sh
append DRIVERS "mt7615e2"

. /lib/wifi/ralink_common.sh

prepare_mt7615e2() {
	prepare_ralink_wifi mt7615e2
}

scan_mt7615e2() {
	scan_ralink_wifi mt7615e2 mt7615e
}

disable_mt7615e2() {
	iwpriv wl1 set hw_nat_register=0
	disable_ralink_wifi mt7615e2
}

enable_mt7615e2() {
	enable_ralink_wifi mt7615e2 mt7615e
	iwpriv wl1 set hw_nat_register=1
}

detect_mt7615e2() {
#	detect_ralink_wifi mt7602e mt76x2e
	ssid=`nvram get wl1_ssid`
	cd  /sys/module/
	[ -d $module ] || return
        [ -e /etc/config/wireless ] && return
         cat <<EOF
config wifi-device      mt7615e2
         option type 'mt7615e2'
         option vendor 'ralink'
         option hwband '2_4G'
         option autoch '2'
         option radio '1'
         option hwmode '11ng'
         option country 'CN'
         option region '1'
         option aregion '0'
         option channel '0'
         option bw '0'
         option txpwr 'max'
         option txbf '0'

config wifi-iface
        option device   'mt7615e2'
        option ifname   'wl1'
        option network  'lan'
        option mode     'ap'
        option ssid     '$ssid'
        option encryption 'none'

config wifi-iface 'miwifi_ready'
        option disabled '0'
        option device 'mt7615e2'
        option ifname 'wl2'
        option network  'ready'
        option mode 'ap'
        option ssid 'miwifi_ready'
	option hidden '1'
        option dynbcn '1'
        option encryption 'none'
	option rssithreshold '-20'

config wifi-iface
        option device 'mt7615e2'
        option ifname 'apcli0'
        option network 'lan'
        option mode 'sta'
        option ssid '$ssid'
        option encryption 'none'
        option disabled '1'

config wifi-iface 'guest_2G'
        option disabled '1'
        option device 'mt7615e2'
        option ifname 'wl3'
        option network 'guest'
        option mode 'ap'

EOF

}

