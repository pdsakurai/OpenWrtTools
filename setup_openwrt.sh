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
        kmod-usb-net-rndis \
        luci-app-banip \
        gawk grep sed coreutils-sort luci-app-simple-adblock \
        luci-app-unbound unbound-control \
        luci-app-wireguard
    log "Done restoring packages within $( end_timer "$timer" )"
}

function modify_simpleadblock() {
    local fullfilepath_script="/etc/init.d/simple-adblock"
    if [ ! -e "$fullfilepath_script" ]; then
        log "Cannot find file: $fullfilepath_script"
        return 1
    fi

    sed -i 's/\(local-zone\)*static/\1always_null/' "$fullfilepath_script"
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

function setup_unbound() {
    local -r dns_packet_size="1232"

    function apply_recommended_conf() {
    local -r unbound_root_dir="/etc/unbound"
    local -r conf_server_fullfilepath="$unbound_root_dir/unbound_srv.conf"
    local -r conf_extended_fullfilepath="$unbound_root_dir/unbound_ext.conf"

    local -r conf_server="""
# Performance tricks (Reference: https://nlnetlabs.nl/documentation/unbound/howto-optimise/)
num-threads: 2 #Number of CPU cores (not threads)
so-reuseport: yes
msg-cache-slabs: 2 #Power of 2 closest to num-threads (for all *-slabs)
rrset-cache-slabs: 2
infra-cache-slabs: 2
key-cache-slabs: 2
ratelimit-slabs: 2
ip-ratelimit-slabs: 2
msg-cache-size: 50m #Formula: rrset-cache-size/2 (Recommended: 50m)
rrset-cache-size: 100m
so-rcvbuf: 8m #Depends on: sysctl -w net.core.rmem_max=8000000
so-sndbuf: 8m #Depends on: sysctl -w net.core.wmem_max=8000000
#Without lib-event
#outgoing-range: 462 #Formula: 1024/num-threads - 50
#num-queries-per-thread: 256 #Formula: 1024/num-threads/2
#With lib-event
outgoing-range: 8192
num-queries-per-thread: 4096

# For improving cache-hit ratio (Reference: https://unbound.docs.nlnetlabs.nl/en/latest/topics/serve-stale.html)
prefetch: yes
serve-expired: yes
serve-expired-ttl: 86400 #1 day in seconds

# For privacy
qname-minimisation: yes
harden-glue: yes
harden-dnssec-stripped: yes
use-caps-for-id: no
hide-identity: yes
hide-version: yes
val-clean-additional: yes
harden-short-bufsize: yes
do-not-query-localhost: no
ignore-cd-flag: yes

# For less fragmentation (new default in 1.12.0)
            edns-buffer-size: $dns_packet_size

include: /var/lib/unbound/*.simple-adblock
"""

    local conf_extended="""
#DNS-over-TLS
forward-zone:
    name: "."
    forward-addr: 9.9.9.9@853#dns.quad9.net
    forward-addr: 149.112.112.112@853#dns.quad9.net
    forward-addr: 2620:fe::fe@853#dns.quad9.net
    forward-addr: 2620:fe::9@853#dns.quad9.net
    forward-first: no
    forward-tls-upstream: yes
    forward-no-cache: no
"""

        echo $conf_server | xargs > "$conf_server_fullfilepath"
        echo $conf_extended | xargs > "$conf_extended_fullfilepath"
    }

    apply_recommended_conf
}