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

function __enable_802dot11k_and_802dot11v() {
    uninstall_packages wpad-basic-wolfssl
    install_packages wpad-wolfssl

    uci revert wireless
    local wifi_iface_uci="$( get_all_wifi_iface_uci )"
    set_uci_from_file "$wifi_iface_uci" "$__resources_dir/uci.wifi-iface.802.11k"
    set_uci_from_file "$wifi_iface_uci" "$__resources_dir/uci.wifi-iface.802.11v"
    commit_and_log_if_there_are_changes "wireless" "Done enabling 802.11k and 802.11v in all SSIDs."

    function install_rrm_nr_distributor() {
        local pkg="umdns"
        install_packages $pkg \
            && service $pkg enable \
            && service $pkg start
        
        local destination source_url="https://raw.githubusercontent.com/simonyiszk/openwrt-rrm-nr-distributor/main"
        destination="/usr/bin/rrm_nr" \
            && wget -O "$destination" "$source_url/bin" > /dev/null \
            && chmod +x "$destination"
        
        destination="/etc/init.d/rrm_nr" \
            && wget -O "$destination" "$source_url/initscript" > /dev/null \
            && chmod +x "$destination" \
            && $destination enable \
            && $destination start

        log "Neighbour reports under 802.11k are ready for syncing across APs."
    }; install_rrm_nr_distributor
}

function __remove_802dot11k_and_802dot11v_uci_options() {
    function uninstall_rrm_nr_distributor() {
        local destination="/etc/init.d/rrm_nr"
        $destination stop
        $destination disable
        rm "$destination"
        rm "/usr/bin/rrm_nr"
        uninstall_packages umdns
    }; uninstall_rrm_nr_distributor

    uci revert wireless
    
    local uci_option_prefix wifi_feature uci_option_suffix
    for uci_option_prefix in $( get_all_wifi_iface_uci ); do
        for wifi_feature in "802.11k" "802.11v"; do
            for uci_option_suffix in "$__resources_dir/uci.wifi-iface.$wifi_feature"; do
                uci_option_suffix="$( printf "$uci_option_suffix" | cut -d= -f1 )"
                uci_option_suffix="$( trim_whitespaces "$uci_option_suffix" )"
                [ -n "$uci_option_suffix" ] && uci -q delete $uci_option_prefix.$uci_option_suffix
            done
        done
    done
    commit_and_log_if_there_are_changes "wireless" "Removed UCI options for 802.11k and 802.11v in all SSIDs."

    uninstall_packages wpad-wolfssl
    install_packages wpad-basic-wolfssl
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
        && cp -f "$SOURCES_DIR/../restart_wifi_radios.sh" "~" \
        && log "Added cron job for restarting all Wi-Fi radios every 03:15H of the day."
}

function setup_wifi() {
    local are_there_changes

    __enable_802dot11r && are_there_changes=0
    __enable_802dot11k_and_802dot11v && are_there_changes=0
    __transmit_max_radio_power_always && are_there_changes=0
    __enable_routine_radios_restarting

    [ -n "$are_there_changes" ] \
        && restart_services wpad \
        && wifi
    log "Done setting up WiFi."
}