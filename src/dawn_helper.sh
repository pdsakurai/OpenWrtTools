#!/bin/sh

source ${1:?Missing: Sources directory}/logger_helper.sh "dawn_helper.sh"
source $1/uci_helper.sh
source $1/utility.sh

__are_there_changes=
__pkg="dawn"
__resources_dir="${2:?Missing:Resources directory}/$__pkg"

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

function uninstall_dawn() {
    __are_there_changes=

    __remove_uci_options
    __remove_802dot11k_and_802dot11v_uci_options

    [ -n "$__are_there_changes" ] && wifi
    log "Done uninstalling $__pkg."
}
