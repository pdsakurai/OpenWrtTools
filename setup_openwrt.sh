#!/bin/sh

function log() {
    local _setup_openwrt_sh="_setup_openwrt_sh[$$]"
    logger -t "$_setup_openwrt_sh" "$@"
    printf "$_setup_openwrt_sh: $@\n"
}

function restore_packages() {
    . ./timer_helper.sh
    local timer="$( start_timer )"
    log "Restoring packages..."
    opkg update && opkg install \
        irqbalance \
        kmod-usb-net-rndis \ #For Android-tethering
        luci-app-banip \
        gawk grep sed coreutils-sort luci-app-simple-adblock \
        luci-app-unbound unbound-control \
        luci-app-sqm \
        luci-app-wireguard
    log "Done restoring packages within $( end_timer "$timer" )"
}

function modify_simpleadblock() {
    local fullfilepath_script="/etc/init.d/simple-adblock"
    if [ ! -e $"fullfilepath_script" ]; then
        log "Cannot find file: $fullfilepath_script"
        return 1
    fi

    sed 's/\(local-zone\)*static/\1always_null/' "$fullfilepath_script"
    log "Changed simple-adblock's script for unblock: local-zone from static to always_null."
}

function modify_sysctlconf() {
    function read_sysctl_value() {
        local param="${1:?Missing: parameter}"
        sysctl "$param" 2> /dev/null | cut -d= -f2 | xargs
    }

    #For unbound
    local for_unbound="""
        net.core.rmem_max=8000000
        net.core.wmem_max=8000000
        net.ipv4.tcp_max_syn_backlog=256
        net.core.somaxconn=256
    """
    local config
    local fullfilepath_conf="/etc/sysctl.conf"
    for config in $for_unbound; do
        local param=$( printf "$config" | cut -d= -f1 )

        local value_new=$( printf "$config" | cut -d= -f2 )
        local value_current=$( read_sysctl_value "$param" )
        if [ -n "$value_current" ] && [ "$value_current" -lt "$value_new" ]; then
            echo "$config" >> "$fullfilepath_conf"
            log "Changed default value of $param from $value_current to $value_new"
        fi
    done
}

function enable_irqbalance() {
    uci revert irqbalance
    uci set irqbalance.irqbalance.enabled='1'
    uci commit irqbalance
    service irqbalance enable
    service irqbalance start

    log "Done enabling and starting irqbalance."
}