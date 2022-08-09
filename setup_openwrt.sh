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
