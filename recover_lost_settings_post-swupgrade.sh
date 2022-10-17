#!/bin/sh

source /root/src/logger_helper.sh "recover_lost_settings.sh"

function modify_simpleadblock_script() {
    local script_fullfilepath="/etc/init.d/simple-adblock"
    # function use_always_null() {
    #     sed -i 's/\(local-zone\)*static/\1always_null/' "$script_fullfilepath"
    #     log "Changed simple-adblock's script for unblock: local-zone from static to always_null."
    # }; use_always_null

    function prevent_reloading_simpleadblock_whenever_wan_reloads() {
        sed "s/\(procd_add.*trigger.*wan.*\)/#\1/" "$script_fullfilepath" | grep procd_add.
        log "Prevented reloading simple-adblock whenever wan reloads."
    }; prevent_reloading_simpleadblock_whenever_wan_reloads
}; modify_simpleadblock_script

function remove_tx_limiter_on_wifi_radios() {
    local url="https://github.com/pdsakurai/OpenWrtTools/raw/main/resources/wireless"
    local pkg="wireless-regdb.ipk"

    cd /tmp
    wget "$url/$pkg"
    opkg install --force-reinstall "$pkg"

    log "Removed TX limiter on Wi-Fi radios."
}; remove_tx_limiter_on_wifi_radios

function distribute_rrm_nr_list() {
    service rrm_nr enable \
        && service rrm_nr start
    log "Re-enabled and started service: rrm_nr"
}; distribute_rrm_nr_list
