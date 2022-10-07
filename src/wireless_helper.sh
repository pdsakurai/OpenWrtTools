#!/bin/sh

source ${SOURCES_DIR:?Define ENV var:SOURCES_DIR}/logger_helper.sh "wireless_helper.sh"
source $SOURCES_DIR/uci_helper.sh
source $SOURCES_DIR/utility.sh

__resources_dir="${RESOURCES_DIR:?Define ENV var:RESOURCES_DIR}/wireless"

function __enable_802dot11r() {
    uci revert wireless
    set_uci_from_file "$( get_all_wifi_iface_uci )" "$__resources_dir/uci.wifi-iface.802.11r"
    commit_and_log_if_there_are_changes "wireless" "Done enabling 802.11r in all SSIDs."
}

function __enable_802dot11w() {
    uci revert wireless
    set_uci_from_file "$( get_all_wifi_iface_uci )" "$__resources_dir/uci.wifi-iface.802.11w"
    commit_and_log_if_there_are_changes "wireless" "Done enabling 802.11w in all SSIDs."
}

function __transmit_max_radio_power_always() {
    #Source: https://discord.com/channels/413223793016963073/792707384619040798/1026685744909123654
    local pkg="wireless-regdb.ipk"
    opkg install --force-reinstall "$__resources_dir/$pkg"

    uci revert wireless
    local uci_option
    for uci_option in $( uci show wireless | grep .txpower | cut -d= -f1 ); do
        uci -q delete $uci_option
    done
    commit_and_log_if_there_are_changes "wireless" "Wi-Fi radios are now transmitting at max power."
}

function __enable_routine_radios_restarting() {
    add_cron_job "$__resources_dir/cron" \
        && cp -f "$__resources_dir/restart_wifi_radios.sh" ~ \
        && log "Added cron job for restarting all Wi-Fi radios every 03:15H of the day."
}

function setup_wifi() {
    local are_there_changes

    __enable_802dot11r && are_there_changes=0
    __enable_802dot11w && are_there_changes=0
    __transmit_max_radio_power_always && are_there_changes=0
    __enable_routine_radios_restarting

    [ -n "$are_there_changes" ] \
        && restart_services wpad \
        && wifi
    log "Done setting up WiFi."
}