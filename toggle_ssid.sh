#!/bin/sh

readonly SOURCES_DIR="$( pwd )/src"
export SOURCES_DIR
source $SOURCES_DIR/logger_helper.sh "toggle_ssid.sh"

readonly SSID="${1?Missing: SSID}"
readonly NEW_STATE="${2?Missing: New state for SSID [off/on]}"

function get_all_wifi_iface() {
    local wifi_iface uci_string
    for uci_string in $( uci show wireless | grep $SSID ); do
        local found_ssid="$( printf "$uci_string" | cut -d '=' -f 2 | xargs 2> /dev/null )"
        if [ "$SSID" == "$found_ssid" ]; then
            uci_string="$( printf "$uci_string" | cut -d '=' -f 1 )"
            uci_string="${uci_string#wireless.}"
            wifi_iface="${uci_string%.ssid} $wifi_iface"
        fi
    done

    printf "$wifi_iface"
}

function validate_SSID() {
    [ -z "$( get_all_wifi_iface )" ] \
        && log "SSID '$SSID' not found." \
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
        && log "Invalid new state [off/on]: $NEW_STATE" \
        && exit 1
}

function get_radio() {
    local wifi_iface="${1:?Missing wifi-iface}"
    local radio="$( uci show wireless | grep wireless.$wifi_iface.device | cut -d '=' -f 2 )"
    
    if [ -n "$radio" ]; then
        printf "${radio//\'/}"
        return 0
    fi

    log "Radio tagged to wifi-iface '$wifi_iface' not found."
    return 1
}

function apply_changes {
    local wifi_iface new_state="$( get_new_state )"
    for wifi_iface in $( get_all_wifi_iface ); do
        uci -q set wireless.$wifi_iface.disabled=$new_state
        uci commit wireless
        wifi reload $( get_radio "$wifi_iface" )
        sleep 1m
    done
    log "Successfully applied the new state '$NEW_STATE' for SSID '$SSID'."
}

validate_SSID
validate_NEWSTATE
apply_changes

exit 0