#!/bin/sh

function restore_packages() {
    opkg update && opkg install \
        irqbalance \
        kmod-usb-net-rndis \ #For Android-tethering
        luci-app-banip \
        gawk grep sed coreutils-sort luci-app-simple-adblock \
        luci-app-unbound unbound-control \
        luci-app-sqm \
        luci-app-wireguard
}

function modify_simpleadblock() {
    local fullfilepath_script="/etc/init.d/simple-adblock"
    sed 's/\(local-zone\)*static/\1always_null/' "$fullfilepath_script"
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
        fi
    done
}
