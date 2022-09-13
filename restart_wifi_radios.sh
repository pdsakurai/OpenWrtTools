#!/bin/sh

function log() {
    local tag="restart_wifi_radio.sh[$$]"
    logger -t "$tag" "$@"
    printf "$tag: $@\n"
}

function get_wifi_radios() {
    uci show wireless | grep wireless.*=wifi-device | sed 's/wireless.\(radio.*\)=wifi-device/\1/'
}

for radio in $( get_wifi_radios ); do
    log "Restarting Wi-Fi radio: $radio"
    wifi up $radio
    sleep 1m
done