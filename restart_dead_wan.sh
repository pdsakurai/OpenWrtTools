#!/bin/sh

source ./src/logger_helper.sh "restart_dead_wan.sh"

readonly ip_version=${1:?Missing: IP version}
case "$ip_version" in
	ipv4)
		interface=wan
		;;
	ipv6)
		interface=wan6
		;;
	*)
		log "Invalid IP version given: $ip_version"
		;;
esac

ping -${ip_version#ipv} -c1 -q -w5 -I $interface google.com > /dev/null 2> /dev/null
if [ $? -ne 0 ]; then
	log "$interface is down. Trying to recover by restarting it." 
	ifup $interface
fi

