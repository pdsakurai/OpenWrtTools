#!/bin/sh

readonly SSID="${1?Missing: SSID}"
readonly NEW_STATE="${2?Missing: New state for SSID [off/on]}"

function log_info() {
    local _toggle_ssid_sh="toggle_ssid_sh[$$]"
    logger -t "$_toggle_ssid_sh" "$@"
    printf "$_toggle_ssid_sh: $@\n"
}

function get_all_wifi_iface() {
    local wifi_iface
    local uci_string
    for uci_string in $( uci show wireless | grep $SSID | cut -d '=' -f 1 ); do
        uci_string="${uci_string#wireless.}"
        wifi_iface="${uci_string%.ssid} $wifi_iface"
    done

    printf "$wifi_iface"
}

function validate_SSID() {
    [ -z "$( get_all_wifi_iface )" ] \
        && log_info "SSID '$SSID' not found." \
        && exit 1
}

function get_new_state() {
    case $NEW_STATE in
        off|Off|OFF|0) printf 1 ;;
        on|On|ON|1)    printf 0 ;;
    esac
}

function validate_NEWSTATE() {
    [ -z "$( get_new_state )" ] \
        && log_info "Invalid new state [off/on]: $NEW_STATE" \
        && exit 1
}

function get_radio() {
    local wifi_iface="${1:?Missing wifi-iface}"
    local radio="$( uci show wireless | grep wireless.$wifi_iface.device | cut -d '=' -f 2 )"
    
    if [ -n "$radio" ]; then
        printf "${radio//\'/}"
        return 0
    fi

    log_info "Radio tagged to wifi-iface '$wifi_iface' not found."
    return 1
}

function apply_changes {
    local new_state="$( get_new_state )"
    for wifi_iface in $( get_all_wifi_iface ); do
        uci -q set wireless.$wifi_iface.disabled=$new_state
        uci commit wireless
        wifi reload $( get_radio "$wifi_iface" )
    done
    log_info "Successfully applied the new state '$NEW_STATE' for SSID '$SSID'."
}

validate_SSID
validate_NEWSTATE
apply_changes

exit 0