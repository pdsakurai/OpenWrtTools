#!/bin/sh

source ${SOURCES_DIR:?Define ENV var:SOURCES_DIR}/logger_helper.sh "dawn_helper.sh"
source $SOURCES_DIR/uci_helper.sh
source $SOURCES_DIR/utility.sh

__are_there_changes=
__pkg="dawn"
__resources_dir="${RESOURCES_DIR:?Define ENV var:RESOURCES_DIR}/$__pkg"

function __enable_802dot11k_and_802dot11v() {
    uninstall_packages wpad-basic-wolfssl
    install_packages wpad-wolfssl
    uci revert wireless
    local wifi_iface_uci="$( get_all_wifi_iface_uci )"
    set_uci_from_file "$wifi_iface_uci" "$resources_dir/uci.wireless.wifi-iface.802.11k"
    set_uci_from_file "$wifi_iface_uci" "$resources_dir/uci.wireless.wifi-iface.802.11v"
    commit_and_log_if_there_are_changes "wireless" "Done enabling 802.11k and 802.11v in all SSIDs." \
        && are_there_changes=0
}

function __apply_recommended_uci_options() {
    install_packages luci-app-$pkg
    local broadcast_address="$( ip address | grep inet.*br-lan | sed 's/.*brd \(.*\) scope.*/\1/' )"

    function clean_uci_option() {
        printf "$1" | sed s/\$broadcast_address/$broadcast_address/
    }
    uci revert $pkg
    set_uci_from_file "$pkg" "$resources_dir/uci.dawn" "clean_uci_option"
    commit_and_log_if_there_are_changes "$pkg" "$pkg is now broadcasting via $broadcast_address" \
        && are_there_changes=0
}

#Reference: https://openwrt.org/docs/guide-user/network/wifi/dawn
function setup() {
    __are_there_changes=

    __enable_802dot11k_and_802dot11v
    __apply_recommended_uci_options

    [ -n "$are_there_changes" ] && restart_services network $pkg
    log "Done setting up $pkg."
}

function __remove_uci_options() {
    uci -q delete $__pkg
    uninstall_packages luci-app-$__pkg
    commit_and_log_if_there_are_changes "$__pkg" "Removed UCI options for $__pkg." \
        && __are_there_changes=0
}

function __remove_802dot11k_and_802dot11v_uci_options() {
    uci revert wireless
    for uci_option_prefix in $( get_all_wifi_iface_uci ); do
        for wifi_feature in "802.11k" "802.11v"; do
            for uci_option_suffix in "$__resources_dir/uci.wireless.wifi-iface.$wifi_feature"; do
                uci_option_suffix="$( printf "$uci_option_suffix" | cut -d= -f1 | xargs )"
                [ -n "$uci_option_suffix" ] && uci -q delete $uci_option_prefix.$uci_option_suffix
            done
        done
    done
    commit_and_log_if_there_are_changes "wireless" "Removed UCI options for 802.11k and 802.11v in all SSIDs." \
        && __are_there_changes=0

    uninstall_packages wpad-wolfssl
    install_packages wpad-basic-wolfssl
}

function uninstall() {
    __are_there_changes=

    __remove_uci_options
    __remove_802dot11k_and_802dot11v_uci_options

    [ -n "$__are_there_changes" ] && wifi
    log "Done uninstalling $__pkg."
}
