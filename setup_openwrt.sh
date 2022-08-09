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
