#!/bin/sh

readonly SOURCES_DIR="$( pwd )/src"
export SOURCES_DIR
source $SOURCES_DIR/logger_helper.sh "restart_dead_wan.sh"

readonly ip_version=${1:?Missing: IP version}
case "$ip_version" in
	ipv4)
		interface=wan
		target=9.9.9.9
		;;
	ipv6)
		interface=wan6
		target=2620:fe::fe
		;;
	*)
		log "Invalid IP version given: $ip_version"
		;;
esac

retry_left=3
is_successful=1
while [ $retry_left -gt 0 ]; do
	ping -${ip_version#ipv} -c1 -q -w18 $target &> /dev/null
	[ $? -ne 0 ] \
		&& retry_left=$(( retry_left - 1 )) \
		|| {
			is_successful=0
			retry_left=0
		}
done

if [ $is_successful -ne 0 ]; then
	log "$interface is down. Trying to recover by restarting it." 
	ifup $interface
fi

exit $is_successful