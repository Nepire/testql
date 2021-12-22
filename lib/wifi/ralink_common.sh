# this file will be included in 
# 	/lib/wifi/mt{chipname}.sh

sync_uci_with_dat() {
	echo "sync_uci_with_dat($1,$2,$3,$4)" >> /tmp/mt76xx.sh.log
	local device="$1"
	local datpath="$2"
	local BdCountryCode
	local NvCountryCode
	BdCountryCode=`bdata get CountryCode`
	NvCountryCode=`nvram get CountryCode`

	if [ "$BdCountryCode" = "US" ]; then
                uci set wireless.$device.country=US
                uci commit wireless
        else
                if [ $NvCountryCode ]; then
                        uci set wireless.$device.country=$NvCountryCode
                        uci commit wireless
                else
                        uci set wireless.$device.country=CN
                        uci commit wireless
                fi
        fi

#	if [  "$CountryCode" = "TW" ]; then
#		uci set wireless.$device.country=TW
#		uci set wireless.$device.rdregion=FCC
#		uci set wireless.$device.region=0
#		uci set wireless.$device.aregion=3
#		uci commit wireless
#	elif [  "$CountryCode" = "HK" ]; then
#		uci set wireless.$device.country=HK
#               uci set wirelees.$device.rdregion=CE
#		uci set wireless.$device.region=1
#		uci set wireless.$device.aregion=7
#		uci commit wireless
#	elif [  "$CountryCode" = "US" ]; then
#		uci set wireless.$device.country=US
#               uci set wirelees.$device.rdregion=FCC
#		uci set wireless.$device.region=0
#		uci set wireless.$device.aregion=9
#		uci commit wireless
#	else
#		uci set wireless.$device.country=CN
#		uci set wireless.$device.rdregion=CE
#		uci set wireless.$device.region=1
#		uci set wireless.$device.aregion=4
#		uci commit wireless
#	fi
	uci2dat -d $device -f $datpath > /tmp/uci2dat_$device.log
}



# $1=device, $2=module
reinit_wifi() {
	echo "reinit_wifi($1,$2,$3,$4)" >> /tmp/mt76xx.sh.log
	local device="$1"
	local module="$2"
	config_get vifs "$device" vifs
	for vif in $vifs; do
		config_get ifname $vif ifname
		ifconfig $ifname down
	done

	# some changes will lead to reinstall driver. (mbssid eg)
	echo "rmmod $module" >>/dev/null
	rmmod $module
	echo "insmod $module" >> /tmp/mt76xx.sh.log
	insmod $module
	for vif in $vifs; do
		config_get ifname $vif ifname
		config_get disabled $vif disabled
		if [ "$disabled" == "1" ]; then
			continue
		else
			ifconfig $ifname up
		fi
	done
}

prepare_ralink_wifi() {
	echo "prepare_ralink_wifi($1,$2,$3,$4)" >> /tmp/mt76xx.sh.log
	local device=$1
	config_get channel $device channel
	config_get ssid $2 ssid
	config_get mode $device mode
	config_get ht $device ht
	config_get country $device country
	config_get regdom $device regdom

	# HT40 mode can be enabled only in bgn (mode = 9), gn (mode = 7)
	# or n (mode = 6).
	HT=0
	[ "$mode" = 6 -o "$mode" = 7 -o "$mode" = 9 ] && [ "$ht" != "20" ] && HT=1

	# In HT40 mode, a second channel is used. If EXTCHA=0, the extra
	# channel is $channel + 4. If EXTCHA=1, the extra channel is
	# $channel - 4. If the channel is fixed to 1-4, we'll have to
	# use + 4, otherwise we can just use - 4.
	EXTCHA=0
	[ "$channel" != auto ] && [ "$channel" -lt "5" ] && EXTCHA=1
	
}

wifi_service_stop() {
	echo "run wifi_service_stop"
}

scan_ralink_wifi() {
	local device="$1"
	local module="$2"
	echo "scan_ralink_wifi($1,$2,$3,$4)" > /tmp/mt76xx.sh.log
	sync_uci_with_dat $device /etc/wireless/$device/$device.dat
}

disable_ralink_wifi() {
	echo "disable_ralink_wifi($1,$2,$3,$4)" >> /tmp/mt76xx.sh.log
	local device="$1"
	set_wifi_down "$device"
	config_get vifs "$device" vifs
	for vif in $vifs; do
		config_get ifname $vif ifname
		ifconfig $ifname down
	done
}

enable_ralink_wifi() {
	echo "enable_ralink_wifi($1,$2,$3,$4)" >> /tmp/mt76xx.sh.log
	local device="$1" dmode channel radio
	local module="$2"
	#reinit_wifi $device $module
	config_get dmode $device mode
	config_get channel $device channel
	config_get radio $device radio
	config_get vifs "$device" vifs
	config_get disabled "$device" disabled
	config_get country $device country
	if [ -f /etc/wireless/"$device"/singlesku/"$country"_SingleSKU.dat ];then
		cp /etc/wireless/"$device"/singlesku/"$country"_SingleSKU.dat /etc/wireless/"$device"/SingleSKU.dat
	else
		cp /etc/wireless/"$device"/singlesku/CN_SingleSKU.dat /etc/wireless/"$device"/SingleSKU.dat
	fi
	[ "$disabled" == "1" ] && return
	for vif in $vifs; do
		local ifname encryption key ssid mode hidden enctype
		config_get ifname $vif ifname
		config_get mode $vif mode
		config_get disabled $vif disabled
		apmode=`uci get xiaoqiang.common.NETMODE 2> /dev/null`
		if [ "$apmode" == "wifiapmode" -o "$apmode" == "lanapmode" ]; then
			if [ "$ifname" == "wl2" -o "$ifname" == "wl3" ]; then
				continue
			fi
		fi

#maybe no use
		[ "$mode" == "sta" ] && {
			iwpriv $ifname set ApCliAutoConnect=1
			iwpriv $ifname set ApCliEnable=1
		}

                if [ "$disabled" == "1" ]; then
                        continue
                else
                        ifconfig $ifname up
                fi

		local net_cfg bridge
		net_cfg="$(find_net_config "$vif")"
		[ -z "$net_cfg" ] || {
			bridge="$(bridge_interface "$net_cfg")"
			config_set "$vif" bridge "$bridge"
			start_net "$ifname" "$net_cfg"
		}
		set_wifi_up "$vif" "$ifname"
	done
}

detect_ralink_wifi() {
	echo "detect_ralink_wifi($1,$2,$3,$4)" >> /tmp/mt76xx.sh.log
	local channel ssid
	local device="$1"
	local module="$2"
	local ifname
	cd /sys/module/
	[ -d $module ] || return
	config_get channel $device channel
	[ -z "$channel" ] || return
	case "$device" in
		mt7628 | mt7602 | mt7603e )
			ifname="wl1"
			ssid=`nvram get wl1_ssid`
			hwband="2_4G"
			hwmode="11ng"
			;;
		mt7610e | mt7612 )
			ifname="wl0"
			ssid=`nvram get wl0_ssid`
			hwband="5G"
			hwmode="11ac"
			;;
		* )
			echo "device $device not recognized!! " >> /tmp/mt76xx.sh.log
			;;
	esac					
}
