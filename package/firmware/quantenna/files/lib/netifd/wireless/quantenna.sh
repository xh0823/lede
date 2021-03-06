#!/bin/sh
. /lib/netifd/netifd-wireless.sh
. /lib/netifd/quantenna.sh

init_wireless_driver "$@"

# primarily to allow RPC API call debugging
quantenna_call() {
	logger "Calling qcsapi_sockrpc" $*
	qcsapi_sockrpc $*
}

quantenna_rfenable() {
	local enable=$1

	# compat: fw v36 req "wifi0" arg, v37 (and later?) does not
	case "$(quantenna_api_ver)" in
		v36)
			quantenna_call rfenable $(quantenna_primaryif) $enable
			;;
		*)
			quantenna_call rfenable $enable
			;;
	esac
}

quantenna_rfstatus() {
	# compat: fw v36 req "wifi0" arg, v37 (and later?) does not
	case "$(quantenna_api_ver)" in
		v36)
			quantenna_call rfstatus $(quantenna_primaryif)
			;;
		*)
			quantenna_call rfstatus
			;;
	esac
}

# mostly harmless if already done
quantenna_ready() {
	[ -n "$(quantenna_ifprefix)" ] || return 1
	[ "$(quantenna_call startprod)" = "complete" ] || return 1
	[ "$(quantenna_call is_startprod_done)" = "1" ] || return 1
	[ "$(quantenna_rfstatus)" = "On" ] || [ "$(quantenna_rfenable 1)" = "complete" ] || return 1
	return 0
}

quantenna_set_security_mode() {
	local ifname=$1
	[ "$(quantenna_call apply_security_config $ifname)" = "complete" ] || return 1
	return 0
}

quantenna_set_ssid_hidden() {
	local ifname=$1
	local hidden=${2:-0}
	local enable=1
	[ $hidden -gt 0 ] && enable=0
	[ "$(quantenna_call set_option $ifname SSID_broadcast $enable)" = "complete" ] || return 1
	return 0
}

quantenna_interface_enable() {
	local ifname=$1
	local enable=${2:-0}
	local updown=down
	[ $enable -gt 0 ] && updown=up
	
	ip link set $ifname $updown
	[ "$(quantenna_call enable_interface $ifname $enable)" = "complete" ] || return 1
	return 0
}

_ifname2vid() {
	echo "$((${1#$(quantenna_ifprefix)}+10))"
}

quantenna_interface_add() {
	local ifname="$1"
	local type="$2"
	local phy="$3"
	local vid=$(_ifname2vid $ifname)
	
	# maximum number of devs is 8
	[ $vid -lt 18 ] || return

	case "$type" in
		ap)
			[ "$ifname" = "$(quantenna_primaryif)" ] || [ "$(quantenna_call wifi_create_bss $ifname)" = "complete" ] || echo "failed to create $ifname"
			quantenna_set_security_mode $ifname || return 1
			[ "$(quantenna_call set_pmf $ifname 0)" = "complete" ] || return 1
		;;
		*)
			echo "$ifname: unsupported interface type '$type'"
			return
			;;
	esac

	# host local vlan dev
	ip link add link $phy name $ifname type vlan id $vid

	# bind quantenna vif to vlan
	[ "$(quantenna_call vlan_config $ifname enable $vid)" = "complete" ] || return 1
	[ "$(quantenna_call vlan_config $ifname bind $vid)" = "complete" ] || return 1

	# disable interface until configured
	quantenna_interface_enable $ifname 0
}

quantenna_interface_del() {
	local ifname="$1"
	local type="$2"
	local vid=$(_ifname2vid $ifname)
	
	quantenna_call vlan_config $ifname unbind $vid
	quantenna_call vlan_config $ifname disable $vid
	quantenna_interface_enable $ifname 0
	
	case "$type" in
		ap)
			[ "$ifname" = "$(quantenna_primaryif)" ] || quantenna_call wifi_remove_bss $ifname
		;;
		*)
			echo "$ifname: unsupported interface type '$type'"
			return
			;;
	esac
	
	ip link del $ifname
}
	
quantenna_set_ssid() {
	local ifname=$1
	local ssid=$2

	quantenna_call set_SSID $ifname $ssid
}

quantenna_set_macaddr() {
	local ifname=$1
	local mac=$2

	quantenna_call set_macaddr $ifname "$mac"
}

quantenna_set_encr() {
	local ifname=$1
	local encr=$2

	quantenna_call set_WPA_encryption_modes $ifname "$encr"
}

quantenna_set_auth() {
	local ifname=$1
	local auth=$2

	quantenna_call set_WPA_authentication_mode $ifname "$auth"
}

quantenna_set_key() {
	local ifname=$1
	local key=$2

	quantenna_call set_passphrase $ifname 0 "$key"
}

quantenna_set_beacon() {
	local ifname=$1
	local type=$2

	quantenna_call set_beacon $ifname "$type"
}

# This will not work with hairpin_mode enabled
quantenna_fixup_vif() {
	echo "quantenna_fixup_vif: $(json_dump)"
	json_select data
	json_get_vars ifname
	json_select ..
	[ -r "/sys/class/net/$ifname/brport/hairpin_mode" ] && echo 0 > "/sys/class/net/$ifname/brport/hairpin_mode"
}

quantenna_setup_vif() {
	local name="$1"
	echo "quantenna_setup_vif: $(json_dump)"

	json_select config
	json_get_vars mode ssid macaddr enable key hidden
	json_select ..

# FIXME - mac addresses for VAPs will be auto-generated by Quantenna firmware - we need only managed the first one...
#	[ -n "$macaddr" ] || {
#		macaddr="$(mac80211_generate_mac $phy)"
#		macidx="$(($macidx + 1))"
#	}

	if_idx=$((${if_idx:--1} + 1))
	local ifname="$(quantenna_ifprefix)${if_idx}"
	set_default enable 1

	json_add_object data
	json_add_string ifname "$ifname"
	json_close_object
	
	json_select config
	wireless_vif_parse_encryption
	json_select ..

	quantenna_interface_add "$ifname" "$mode" "$phy" || return
	quantenna_set_ssid_hidden $ifname "$hidden"

	case "$auth_type" in
		none)
			quantenna_set_beacon $ifname Basic
			;;
		psk)
			quantenna_set_auth $ifname PSKAuthentication
			;;
		*)
			echo "unsupported auth_type: $auth_type"
		;;
	esac
	
	case "$wpa_cipher" in
		"TKIP")
			quantenna_set_beacon $ifname WPA
			quantenna_set_encr $ifname TKIPEncryption
			;;
		"CCMP")
			quantenna_set_beacon $ifname 11i
			quantenna_set_encr $ifname AESEncryption
			;;
		"CCMP TKIP")
			quantenna_set_beacon $ifname WPAand11i
			quantenna_set_encr $ifname TKIPandAESEncryption
			;;
		*)
			;;
	esac
		 
	[ -n "$key" ] && quantenna_set_key $ifname "$key"
	quantenna_set_ssid $ifname "$ssid"
	[ -n "$macaddr" ] && quantenna_set_macaddr $ifname "$macaddr"
	quantenna_interface_enable $ifname $enable

	wireless_add_vif "$name" "$ifname"
}

quantenna_cleanup_vif() {
	local name="$1"

	echo "quantenna_cleanup_vif ($name): $(json_dump)"
	json_select config
	json_get_vars mode 
	json_select ..

	json_select data
	json_get_vars ifname
	json_select ..

	quantenna_interface_del $ifname $mode
}

# will be evaled after _wdev_common_device_config(), which adds
#     config_add_string channel hwmode htmode noscan
drv_quantenna_init_device_config() {
	config_add_string phy
	config_add_int beacon_int
	echo "drv_quantenna_init_device_config"
}

# will be evaled after _wdev_common_iface_config(), which adds
#         config_add_string mode ssid encryption 'key:wpakey'
drv_quantenna_init_iface_config() {
	config_add_boolean enable hidden
	echo "drv_quantenna_init_iface_config"
}

drv_quantenna_setup() {
	json_select config
	echo "drv_quantenna_setup: $(json_dump)"
	json_get_vars phy channel htmode beacon_int
	json_select ..

	[ "$(quantenna_device)" = "$phy" ] || {
		echo "Could not find PHY for device '$1'"
		wireless_set_retry 0
		return 1
	}

	quantenna_ready || {
		echo "Failed to connect to Quantenna module"
		wireless_set_retry 1
		return 1
	}

	quantenna_call set_channel $(quantenna_primaryif) $channel

	case "$htmode" in
                VHT20|HT20)
			quantenna_call set_bw $(quantenna_primaryif) 20
			;;
                HT40*|VHT40)
			quantenna_call set_bw $(quantenna_primaryif) 40
			;;
                VHT80)
			quantenna_call set_bw $(quantenna_primaryif) 80
			;;
		*)
			quantenna_call set_bw $(quantenna_primaryif) 40
			;;
	esac

	[ -n "beacon_int" ] && quantenna_call set_beacon_interval $(quantenna_primaryif) $beacon_int

	# FIMXE: support all modes: ap, sta, adhoc, wds, monitor, mesh
	for_each_interface "ap" quantenna_setup_vif
	wireless_set_up
	for_each_interface "ap" quantenna_fixup_vif
}

drv_quantenna_teardown() {
	echo "$drv_quantenna_teardown: $(json_dump)"
	for_each_interface "ap" quantenna_cleanup_vif
	quantenna_rfenable 0
}

add_driver quantenna
