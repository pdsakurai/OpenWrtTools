#!/bin/sh

readonly SOURCES_DIR="$( pwd )/src"
export SOURCES_DIR
source $SOURCES_DIR/logger_helper.sh "update_and_upgrade_all_packages.sh"

readonly UCI_OPTION_DNS_SERVER="dhcp.@dnsmasq[0].server"
readonly DNS_SERVERS_LIST=$( uci show $UCI_OPTION_DNS_SERVER | cut -f2 -d= )

function restore_dns_servers_list {
    uci delete $UCI_OPTION_DNS_SERVER
    for x in $DNS_SERVERS_LIST; do
        add_dns_server $x
    done
    uci commit
    service dnsmasq restart
    log "Done restoring DNS servers list"
}

function add_dns_server {
    local ip_address=${1:?Missing: DNS server\'s IP address}
    uci add_list $UCI_OPTION_DNS_SERVER="${ip_address//\'/}"
    log "Added DNS server: $ip_address"
}

function enable_backup_dns_server {
    add_dns_server "1.1.1.1"
    uci commit
    service dnsmasq restart
    log "Enabled backup DNS server"
}

function update_packages_list {
    opkg update
    log "Done updating packages lists."
}

function upgrade_packages {
    opkg list-upgradable | grep -v wireless-regdb | cut -f 1 -d ' ' | xargs -rt opkg upgrade
    log "Done upgrading packages."
}

enable_backup_dns_server
update_packages_list
upgrade_packages
restore_dns_servers_list