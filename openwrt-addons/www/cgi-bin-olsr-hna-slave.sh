#!/bin/sh
. /tmp/loader

knowing_hna_already()
{
	local funcname="knowing_hna_already"
	local netaddr="$1"
	local netmask="$( _net cidr2mask "$2" )"
	local i=0

	while true; do
		case "$( uci get olsrd.@Hna4[$i].netaddr)/$( uci get olsrd.@Hna4[$i].netmask )" in
			"$netaddr/$netmask")
				_log do $funcname daemon info "already know: $netaddr/$netmask"
				return 0
			;;
			"/")
				_log do $funcname daemon info "new hna: $netaddr/$netmask"
				return 1
			;;
		esac

		i=$(( $i + 1 ))
	done
}

hna_add()
{
	local netaddr="$1"
	local netmask="$( _net cidr2mask "$2" )"
	local token="$( uci add olsrd Hna4 )"

	uci set olsrd.$token.netaddr="$netaddr"
	uci set olsrd.$token.netmask="$netmask"
}

add_static_routes()
{
	local ip="$1"
	local netaddr="$2"
	local netmask="$3"
	local dev="$4"

	rm "/tmp/OLSR/isneigh_$ip"
	ip route add $netaddr/$netmask via $ip dev $dev metric 1 onlink
}

device_forbidden()
{
	local ip="$1"

	case "$CONFIG_PROFILE" in
		elephant*)
			case "$ip" in
				10.63.75.33|10.63.76.33)
					return 0
				;;
			esac
		;;
		boltenhagen*|marinabh*|fparkssee*)
			return 0
		;;
		leonardo*)
			[ "$NODENUMBER" = 6 ] && return 0
		;;
		ejbw*)
			return 0

			case "$NODENUMBER" in
				100|101)
					return 0
				;;
			esac
		;;
	esac

	return 1
}

_http header_mimetype_output "text/plain"

[ -e "/tmp/LOCK_OLSRSLAVE" ] && {
	[ $( _file age "/tmp/LOCK_OLSRSLAVE" sec ) -gt 3600 ] || {
		_log do htmlout daemon info "sending LOCKED to $REMOTE_ADDR"
		echo "LOCKED"
		exit 0
	}
}

trap "rm /tmp/LOCK_OLSRSLAVE; exit" HUP INT QUIT TERM EXIT
touch "/tmp/LOCK_OLSRSLAVE"


  if device_forbidden "$REMOTE_ADDR"; then
	ERROR="NEVER"
elif _olsr uptime is_short; then
	ERROR="SHORT_OLSR_UPTIME"
else
	eval $( _http query_string_sanitize )		# ?netaddr=...&netmask=...&version=...

	if _sanitizer do "$version" numeric check; then
		RTABLE="$( ip route list exact $netaddr/$netmask | fgrep " via $REMOTE_ADDR " )" || {
			knowing_hna_already "$netaddr" "$netmask" && {
				RTABLE="$( ip route list exact $REMOTE_ADDR | fgrep " via $REMOTE_ADDR " )"
			}
		}

		test $version -ge $FFF_PLUS_VERSION || {
			RTABLE="slave_version_to_low:$version"
			ERROR="$RTABLE"
		}
	else
		RTABLE='error_in_version'
		ERROR="$RTABLE"
	fi

	case "$RTABLE" in
		'slave_version_to_low'*|'error_in_version')
			dev2slave=
		;;
		*" dev $LANDEV "*)
			dev2slave="$LANDEV"
			for DEV in $WANDEV $WIFIDEV; do {
				CHECK_IP="$( _net dev2ip $DEV )" && break
			} done
		;;
		*" dev $WANDEV "*)
			dev2slave="$WANDEV"
			for DEV in $LANDEV $WIFIDEV; do {
				CHECK_IP="$( _net dev2ip $DEV )" && break
			} done
		;;
		*)
			_log do cannot_find_your_hna daemon info "netaddr: $netaddr netmask: $netmask remote_addr: $REMOTE_ADDR = '$( ip route list exact $netaddr/$netmask )'"
			ERROR="CANNOT_FIND_YOUR_HNA"
		;;
	esac

	[ -n "$dev2slave" ] && {
		ERROR="OK $CHECK_IP"

		knowing_hna_already "$netaddr" "$netmask" || {
			hna_add "$netaddr" "$netmask"
			add_static_routes "$REMOTE_ADDR" "$netaddr" "$netmask" "$dev2slave"
			_olsr daemon restart "becoming hna-master for $REMOTE_ADDR: $netaddr/$netmask"
		}
	}
fi

echo "${ERROR:=ERROR}"
_log do htmlout daemon info "errorcode: $ERROR for IP: $REMOTE_ADDR"

rm "/tmp/LOCK_OLSRSLAVE"
trap - HUP INT QUIT TERM EXIT
