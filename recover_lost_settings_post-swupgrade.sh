#!/bin/sh

function prevent_reloading_simpleadblock_whenever_wan_reloads() {
    sed -i "s/\(procd_add.*trigger.*wan.*\)/#\1/" "/etc/init.d/simple-adblock"    
}; prevent_reloading_simpleadblock_whenever_wan_reloads

function distribute_rrm_nr_list() {
    service rrm_nr enable \
        && service rrm_nr start
}; distribute_rrm_nr_list