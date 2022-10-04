#!/bin/sh

set -o errexit
set -o pipefail

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

function setup_ntp_server() {
    local resources_dir="$RESOURCES_DIR/ntp"

    function redirect_NTP_queries() {
        local firewall_fullfilepath="$resources_dir/firewall.redirect"
        local destination_dir="$( head -1 "$firewall_fullfilepath" | sed "s/\#\(.*\)/\1/" | xargs )"
        load_and_append_to_another_file "$firewall_fullfilepath" "$destination_dir/99-redirect-ntp.nft" \
            && log "NTP requests from LAN are now redirected."
    }; redirect_NTP_queries

    function apply_uci_options() {
        local uci_ntp="system.ntp"

        uci revert $uci_ntp
        set_uci_from_file "$uci_ntp" "$resources_dir/uci.$uci_ntp"
        add_list_uci_from_file "$uci_ntp.interface" "$resources_dir/uci.$uci_ntp.interface"
        add_list_uci_from_file "$uci_ntp.server" "$resources_dir/uci.$uci_ntp.server"

        commit_and_log_if_there_are_changes "$uci_ntp" "Applied recommended UCI settings for NTP"
    }; apply_uci_options

    restart_services firewall sysntpd
    log "Done set-up for NTP server."
}

function setup_wifi() {
    local are_there_changes=
    local resources_dir="$RESOURCES_DIR/wireless"

    function enable_802dot11r() {
        uci revert wireless
        set_uci_from_file "$( get_all_wifi_iface_uci )" "$resources_dir/uci.wifi-iface.802.11r"
        commit_and_log_if_there_are_changes "wireless" "Done enabling 802.11r in all SSIDs." \
            && are_there_changes=0
    }; enable_802dot11r

    function transmit_max_radio_power_always() {
        #Source: https://discord.com/channels/413223793016963073/792707384619040798/1026685744909123654
        local pkg="wireless-regdb.ipk"
        opkg install --force-reinstall $resources_dir/$pkg

        uci revert wireless
        for uci_option in $( uci show wireless | grep .txpower | cut -d= -f1 ); do
            uci delete $uci_option
        done
        commit_and_log_if_there_are_changes "wireless" "Wi-Fi radios are now transmitting at max power." \
            && are_there_changes=0
    }; transmit_max_radio_power_always

    add_cron_job "$resources_dir/cron" \
        && log "Added cron job for restarting all Wi-Fi radios every 03:15H of the day."

    [ -n "$are_there_changes" ] && restart_services network
    log "Done setting up WiFi"
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
    commit_and_log_if_there_are_changes "$uci_option" "Timezone is set to Asia/Manila."

    uci_option="uhttpd"
    uci revert $uci_option
    set_uci_from_file "$uci_option" "$RESOURCES_DIR/uci.$uci_option"
    commit_and_log_if_there_are_changes "$uci_option" "HTTP access is always redirected to HTTPS."
}

function setup_router() {
    local domain="${1:?Missing: Domain}"

    opkg update

    setup_ntp_server
    setup_irqbalance
    setup_usb_tether
    $( source $SOURCES_DIR/unbound_helper.sh \
            "$UNBOUND_CONF_SRV_FULLFILEPATH" \
            "$UNBOUND_CONF_EXT_FULLFILEPATH" \
            "$domain" \
        && setup )
    $( source $SOURCES_DIR/simpleadblock_helper.sh \
            "$UNBOUND_CONF_SRV_FULLFILEPATH" \
        && setup )
    setup_wifi
    setup_ipv6_dhcp_in_router
    setup_miscellaneous

    add_cron_job "$RESOURCES_DIR/cron.wan" \
        && log "Added cron job for restarting dead WAN interfaces."

    log "Completed setting up router."
}

function setup_dumb_ap() {
    opkg update

    setup_irqbalance
    setup_wifi
    setup_miscellaneous

    log "Completed setting up dumb AP."
}