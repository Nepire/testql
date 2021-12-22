#!/bin/sh
# Copyright (C) 2010-2012 OpenWrt.org

list_alldir(){  
	for file in `ls $1 | grep [^a-zA-Z]\.manifest$`  
	do  
		if [ -f $1/$file ];then
			accessUserdata=$(grep "access_userdata" $1/$file)
			if ([ "$2"x = "resourcePlugin"x ] && [ -z "$accessUserdata" ]) || ([ "$2"x = "nonResourcePlugin"x ] && [ -n "$accessUserdata" ]);then
				continue
			fi
			#is_supervisord=$(grep "is_supervisord" $1/$file | cut -d'=' -f2 | cut -d'"' -f2)
			#echo "is_supervisord is $is_supervisord"
			status=$(grep -n "^status " $1/$file | cut -d'=' -f2 | cut -d'"' -f2)
			echo "status is $status"
			plugin_id=$(grep "plugin_id" $1/$file | cut -d'=' -f2 | cut -d'"' -f2)
			echo "plugin_id is $plugin_id"

			record_path=/usr/share/datacenter/pluginrecord
			app_path=/userdisk/appdata
			init_file=init_files.record
			dst_path=${app_path}/${plugin_id}/${init_file}
			if [ ! -f ${dst_path} ];then
			    if [ -f ${record_path}/${plugin_id}.record ];then
			        cp ${record_path}/${plugin_id}.record ${dst_path}
				else
				    echo "${app_path}/${plugin_id}/" > ${dst_path}
				    echo "${dst_path}" >> ${dst_path}
			    fi
			fi
			if [ "$status"x = "5"x ];then
				pluginControllor -b $plugin_id >/dev/null 2>&1 &
			fi  
		fi  
	done  
}  
        
pluginControllor -u                      
list_alldir /userdisk/appdata/app_infos $1
