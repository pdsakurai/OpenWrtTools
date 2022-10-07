#!/bin/sh

source ${SOURCES_DIR:?Define ENV var:SOURCES_DIR}/logger_helper.sh "dawn_helper.sh"
source $SOURCES_DIR/uci_helper.sh
source $SOURCES_DIR/utility.sh

__pkg="dawn"
__resources_dir="${RESOURCES_DIR:?Define ENV var:RESOURCES_DIR}/$__pkg"

function __apply_recommended_uci_options() {
    install_packages luci-app-$__pkg
    local broadcast_address="$( ip address | grep inet.*br-lan | sed 's/.*brd \(.*\) scope.*/\1/' )"

    function clean_uci_option() {
        printf "$1" | sed s/\$broadcast_address/$broadcast_address/
    }
    uci revert $__pkg
    set_uci_from_file "$__pkg" "$__resources_dir/uci.dawn" "clean_uci_option"
    commit_and_log_if_there_are_changes "$__pkg" "$__pkg is now broadcasting via $broadcast_address"
}

#Reference: https://openwrt.org/docs/guide-user/network/wifi/dawn
function setup_dawn() {
    $( source $SOURCES_DIR/wireless_helper.sh && __enable_802dot11k_and_802dot11v )
    __apply_recommended_uci_options \
        && restart_services wpad umdns $__pkg \
        && wifi
    log "Done setting up $__pkg."
}

function __remove_uci_options() {
    uci -q delete $__pkg
    uninstall_packages luci-app-$__pkg
    commit_and_log_if_there_are_changes "$__pkg" "Removed UCI options for $__pkg."
}

function uninstall_dawn() {
    __remove_uci_options \
        && restart_services wpad \
        && wifi
    log "Done uninstalling $__pkg."
}
