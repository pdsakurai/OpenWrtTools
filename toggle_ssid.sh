#!/bin/sh

readonly SSID="${1?Missing: SSID}"
readonly NEW_STATE="${2?Missing: New state for SSID [off/on]}"

function log_info() {
    local _toggle_ssid_sh="toggle_ssid_sh[$$]"
    logger -t "$_toggle_ssid_sh" "$@"
    printf "$_toggle_ssid_sh: $@\n"
}

#To do, make a loop for multiple SSID hits
function validate_SSID {
    readonly WIRELESS_SSID_UCI_STRING="$( uci show wireless | grep $SSID | cut -d '=' -f 1 )"
    [ -z "$WIRELESS_SSID_UCI_STRING" ] && log_info "SSID '$SSID' not found." && exit 1

    readonly RADIO="$( uci show wireless | grep ${WIRELESS_SSID_UCI_STRING/ssid/device} | cut -d '=' -f 2 | cut -d "'" -f 2 )"
    [ -z "$RADIO" ] && log_info "Radio tagged to SSID '$SSID' not found." && exit 1
}

function validate_NEWSTATE {
    case $NEW_STATE in
        off|Off|OFF|0) new_state=1 ;;
        on|On|ON|1)    new_state=0 ;;
        *)             log_info "Invalid provided new state [off/on] for SSID; provided: $NEW_STATE" && exit 1 ;;
    esac
}

function apply_changes {
    uci -q set ${WIRELESS_SSID_UCI_STRING/ssid/disabled}=$new_state
    uci commit wireless
    wifi reload $RADIO
    log_info "Successfully applied the new state '$NEW_STATE' for SSID '$SSID'."
}

validate_SSID
validate_NEWSTATE
apply_changes

exit 0