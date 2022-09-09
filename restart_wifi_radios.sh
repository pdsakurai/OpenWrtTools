#!/bin/sh

function log() {
    local tag="restart_wifi_radio.sh[$$]"
    logger -t "$tag" "$@"
    printf "$tag: $@\n"
}

function get_wifi_radios() {
    uci show wireless | grep wireless.*=wifi-device | sed 's/wireless.\(radio.*\)=wifi-device/\1/'
}

log "Restarting Wi-Fi radios..."

for radio in $( get_wifi_radios ); do
    wifi reload $radio
    sleep 1m
done

log "Done restarting Wi-Fi radios."