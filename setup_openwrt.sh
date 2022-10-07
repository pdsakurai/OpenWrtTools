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

    cp -f "$ROOT_DIR/restart_dead_wan.sh" ~
    add_cron_job "$RESOURCES_DIR/cron.wan" \
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