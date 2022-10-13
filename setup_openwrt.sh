#!/bin/sh

# set -o errexit
# set -o pipefail

ROOT_DIR="$( pwd )"
RESOURCES_DIR="$ROOT_DIR/resources"
SOURCES_DIR="$ROOT_DIR/src"

export RESOURCES_DIR
export SOURCES_DIR

UNBOUND_ROOT_DIR="/etc/unbound"
UNBOUND_CONF_SRV_FULLFILEPATH="$UNBOUND_ROOT_DIR/unbound_srv.conf"
UNBOUND_CONF_EXT_FULLFILEPATH="$UNBOUND_ROOT_DIR/unbound_ext.conf"

source $SOURCES_DIR/logger_helper.sh "setup_openwrt.sh"
source $SOURCES_DIR/uci_helper.sh
source $SOURCES_DIR/utility.sh

function setup_irqbalance() {
    local pkg="irqbalance"

    install_packages $pkg

    uci revert $pkg
    set_uci_from_file "$pkg" "$RESOURCES_DIR/uci.$pkg"
    uci commit $pkg

    service $pkg enable
    restart_services $pkg

    log "Done setting up $pkg."
}

function setup_usb_tether() {
    install_packages kmod-usb-net-rndis
    log "Done setting up support for Android USB-tethered internet connection."
}

function setup_ipv6_dhcp_in_router() {
    local uci_option="dhcp.lan"
    local resources_dir="$RESOURCES_DIR/ipv6"
    uci revert $uci_option
    set_uci_from_file "$uci_option" "$resources_dir/uci.$uci_option"
    uci_option="dhcp.lan.ra_flags"
    add_list_uci_from_file "$uci_option" "$resources_dir/uci.$uci_option"
    uci commit $uci_option

    log "Done setting up IPv6 DHCP."
    restart_services network
}

function setup_miscellaneous() {
    local uci_option="system"
    uci revert $uci_option
    set_uci_from_file "$uci_option" "$RESOURCES_DIR/uci.$uci_option"
    commit_and_log_if_there_are_changes "$uci_option" "Timezone is set to Asia/Manila." \
        && restart_services sysntpd

    uci_option="uhttpd"
    uci revert $uci_option
    set_uci_from_file "$uci_option" "$RESOURCES_DIR/uci.$uci_option"
    commit_and_log_if_there_are_changes "$uci_option" "HTTP access is always redirected to HTTPS." \
        && restart_services $uci_option
    
    uci_option="firewall"
    uci revert $uci_option
    set_uci_from_file "$uci_option" "$RESOURCES_DIR/uci.$uci_option"
    commit_and_log_if_there_are_changes "$uci_option" "Enabled Routing/NAT offloading." \
        && restart_services $uci_option

    local destination="/root/src"
    mkdir -p "$destination/"
    cp -f "$SOURCE_DIR/logger_helper.sh" "$destination/"

    function secure_ssh_access() {
        function get_all_instances() {
            uci show dropbear | grep "=dropbear" | sed "s/dropbear.\(.*\)=dropbear/\1/"
        }

        local uci_option="dropbear"
        uci revert $uci_option
        for instance in $( get_all_instances ); do
            set_uci_from_file "$uci_option.$instance" "$RESOURCES_DIR/uci.$uci_option"
        done
        commit_and_log_if_there_are_changes "$uci_option" "SSH access accessible only thru LAN interface." \
            && restart_services dropbear
    }; secure_ssh_access

    install_packages luci-app-attendedsysupgrade

    function add_backup_files() {
        local backup_list="/etc/sysupgrade.conf"
        echo "/etc/nftables.d/" >> "$backup_list"
        echo "/usr/share/nftables.d/" >> "$backup_list"
        echo "/root/" >> "$backup_list"
    }; add_backup_files
}

function block_unknown_devices() {
    [ $( uci show dhcp | grep -c "\.mac=" ) -le 0 ] \
        && log "Add one static lease first." \
        && return 1

    local pkg="block_unknown_devices"
    local resources_dir="$RESOURCES_DIR/$pkg"

    local service_file=$( copy_resource "$resources_dir/service" )
    [ $? -eq 0 ] && chmod +x "$service_file"

    copy_resource "$resources_dir/block_requests_for_router_services.nft" > /dev/null
    copy_resource "$resources_dir/block_trespassers.nft" > /dev/null
    local set_file="$( copy_resource "$resources_dir/set_known_devices.nft" )"
    [ $? -eq 0 ] && sed -i "s/\$SET_FILE/${set_file//\//\\\/}/" "$service_file"

    service $pkg enable && service $pkg start
    restart_services firewall
    log "Unknown devices are now blocked. Make sure to assign static leases to new devices."
}

function setup_router() {
    local domain="${1:?Missing: Domain}"

    opkg update
    upgrade_all_packages

    $( source $SOURCES_DIR/ntp_helper.sh && setup_ntp_server ) 2> /dev/null
    setup_irqbalance
    setup_usb_tether
    $( source $SOURCES_DIR/unbound_helper.sh \
            "$UNBOUND_CONF_SRV_FULLFILEPATH" \
            "$UNBOUND_CONF_EXT_FULLFILEPATH" \
            "$domain" \
        && setup_unbound ) 2> /dev/null
    $( source $SOURCES_DIR/wireless_helper.sh && setup_wifi )
    setup_ipv6_dhcp_in_router
    setup_miscellaneous

    add_cron_job "$RESOURCES_DIR/cron.wan" \
        && cp -f "$ROOT_DIR/restart_dead_wan.sh" "/root/" \
        && log "Added cron job for restarting dead WAN interfaces."

    $( source $SOURCES_DIR/simpleadblock_helper.sh \
            "$UNBOUND_CONF_SRV_FULLFILEPATH" \
        && setup_simpleadblock ) 2> /dev/null

    log "Completed setting up router."
}

function setup_dumb_ap() {
    opkg update
    upgrade_all_packages

    setup_irqbalance
    $( source $SOURCES_DIR/wireless_helper.sh && setup_wifi )
    setup_miscellaneous

    log "Completed setting up dumb AP."
}