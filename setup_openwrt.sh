#!/bin/sh

readonly unbound_root_dir="/etc/unbound"
readonly conf_server_fullfilepath="$unbound_root_dir/unbound_srv.conf"
readonly resources_dir="$( pwd )/resources"

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
        gawk grep sed coreutils-sort luci-app-simple-adblock \
        luci-app-unbound unbound-control
    log "Done restoring packages within $( end_timer "$timer" )"
}

function setup_simpleadblock() {
    function use_always_null(){
        local fullfilepath_script="/etc/init.d/simple-adblock"
        if [ ! -e "$fullfilepath_script" ]; then
            log "Cannot find file: $fullfilepath_script"
            return 1
        fi

        sed -i 's/\(local-zone\)*static/\1always_null/' "$fullfilepath_script"
        log "Changed simple-adblock's script for unblock: local-zone from static to always_null."
    }

    function apply_recommended_uci_settings() {
        local uci_simpleadblock="simple-adblock.config"

        uci revert $uci_simpleadblock

        while read uci_option; do
            uci_option="$( printf $uci_option | xargs )"
            [ -n $uci_option ] && uci set $uci_simpleadblock.$uci_option
        done < "$resources_dir/$uci_simpleadblock"

        for item in blocked_domains_url blocked_hosts_url; do
            uci -q delete $uci_simpleadblock.$item
            while read uci_option; do
                uci_option="$( printf $uci_option | xargs )"
                [ -n $uci_option ] && uci add_list $uci_simpleadblock.$item="$uci_option"
            done < "$resources_dir/$uci_simpleadblock.$item"
        done

        uci commit $uci_simpleadblock
        log "Recommended UCI options applied for simple-adblock."
    }

    function integrate_with_unbound() {
        if [ $( grep -c simple-adblock "$conf_server_fullfilepath" ) -le 0 ]; then

            local conf_server="""#For integration with simple-adblock
include: /var/lib/unbound/*.simple-adblock"""

            printf "$conf_server\n\n" >> "$conf_server_fullfilepath"

            log "simple-adblock now integrated with unbound."
        fi
    }

    use_always_null
    apply_recommended_uci_settings
    integrate_with_unbound

    log "Restarting service: simple-adblock"
    service simple-adblock restart
}

function setup_irqbalance() {
    uci revert irqbalance
    uci set irqbalance.irqbalance.enabled='1'
    uci commit irqbalance
    service irqbalance enable
    service irqbalance start

    log "Done enabling and starting irqbalance."
}


function delete_firewall_entries() {
    local type=${1:?Missing: Firewall entry type}
    local name=${2:?Missing: Entry name}

    function search_entries() {
        uci show firewall | grep "$type.*name='$name" | cut -d. -f 2 | sort -r
    }

    for entry in $( search_entries ); do
        uci delete firewall.$entry
    done
}

function setup_unbound() {
    local domain="${1:?Missing: domain}"
    local port="${2:-1053}"

    local dns_packet_size="1232"

    function modify_sysctlconf() {
        function read_sysctl_value() {
            local param="${1:?Missing: parameter}"
            sysctl "$param" 2> /dev/null | cut -d= -f2 | xargs
        }

        local fullfilepath_conf="/etc/sysctl.conf"
        while read config; do
            local param=$( printf "$config" | cut -d= -f1 )

            local value_new=$( printf "$config" | cut -d= -f2 )
            local value_current=$( read_sysctl_value "$param" )
            if [ -n "$value_current" ] && [ "$value_current" -lt "$value_new" ]; then
                echo "$config" >> "$fullfilepath_conf"
                sysctl -w $config
                log "Changed default value of $param from $value_current to $value_new"
            fi
        done < "$resources_dir/unbound.sysctl.conf"
    }

    local conf_extended_fullfilepath="$unbound_root_dir/unbound_ext.conf"

    function apply_recommended_conf() {
        local conf_server="""# Performance tricks (Reference: https://nlnetlabs.nl/documentation/unbound/howto-optimise/)
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

#Overriding the OpenWrt config by using the default
outgoing-num-tcp: 10
incoming-num-tcp: 10
msg-buffer-size: 65552
infra-cache-numhosts: 10000
harden-large-queries: no
ratelimit-size: 4m
ip-ratelimit-size: 4m
cache-max-ttl: 86400
cache-max-negative-ttl: 3600
val-bogus-ttl: 60"""

        local conf_extended="""#DNS-over-TLS
forward-zone:
    name: "."
    forward-addr: 9.9.9.9@853#dns.quad9.net
    forward-addr: 149.112.112.112@853#dns.quad9.net
    forward-addr: 2620:fe::fe@853#dns.quad9.net
    forward-addr: 2620:fe::9@853#dns.quad9.net
    forward-first: no
    forward-tls-upstream: yes
    forward-no-cache: no"""

        printf "$conf_server\n\n" > "$conf_server_fullfilepath"
        printf "$conf_extended\n\n" > "$conf_extended_fullfilepath"

        log "Recommended configuration applied for unbound."
    }

    function clean_uci_option() {
        local uci_option=${1:?Missing: UCI option}
        uci_option="$( printf $uci_option | xargs )"
        uci_option="$( printf $uci_option | sed s/\$domain/$domain/ )"
        uci_option="$( printf $uci_option | sed s/\$dns_packet_size/$dns_packet_size/ )"
        printf $uci_option | sed s/\$port/$port/
    }

    function apply_recommended_uci_settings() {
        local uci_unbound="unbound.@unbound[0]"
        uci revert $uci_unbound

        while read uci_option; do
            uci_option="$( clean_uci_option $uci_option )"
            [ -n $uci_option ] && uci set $uci_unbound.$uci_option
        done < "$resources_dir/unbound.uci"

        uci commit $uci_unbound
        log "Recommended UCI options applied for unbound."
    }

    function use_unbound_in_dnsmasq() {
        uci revert dhcp

        while read uci_option; do
            uci_option="$( clean_uci_option $uci_option )"
            [ -n $uci_option ] && uci set dhcp.@dnsmasq[0].$uci_option
        done < "$resources_dir/unbound.dnsmasq.uci"

        uci -q delete dhcp.@dnsmasq[0].server
        uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#$port"
        uci -q delete dhcp.lan.dhcp_option
        uci add_list dhcp.lan.dhcp_option='option:dns-server,0.0.0.0'

        uci commit dhcp
        log "dnsmasq now uses unbound."
    }

    function use_unbound_in_wan() {
        function get_all_wan() {
            uci show network | grep .*wan.*=interface | cut -d= -f1 | cut -d. -f2
        }

        uci revert network
        for wan in $( get_all_wan ); do
            uci -q delete network.$wan.dns
            uci add_list network.$wan.dns="127.0.0.1"
            uci add_list network.$wan.dns="::1"
            uci set network.$wan.peerdns="0"
        done

        uci commit network
        log "WAN interfaces now use unbound."
    }

    function redirect_dns_requests() {
        local name_prefix="Redirect DNS"
        local type="redirect"


        function redirect_dns_ports() {
            local dns_ports="53 5353"
            for port in $dns_ports; do
                uci add firewall $type
                uci set firewall.@$type[-1].target='DNAT'
                uci set firewall.@$type[-1].name="$name_prefix - port $port"
                uci set firewall.@$type[-1].src='lan'
                uci set firewall.@$type[-1].src_dport="$port"
            done
        }

        uci revert firewall
        delete_firewall_entries "$type" "$name_prefix"
        redirect_dns_ports
        uci commit firewall
        log "DNS requests from LAN are now redirected to unbound."
    }

    function block_encrypted_dns_requests() {
        function block_DoH() {
            local conf_server="""#For blocking DNS-over-HTTPS
module-config: \"respip validator iterator\""""

            local conf_extended="""#For blocking DNS-over-HTTPS
rpz:
    name: Restrict_DoT/DoH
    url: https://raw.githubusercontent.com/jpgpi250/piholemanual/master/DOH.rpz
    zonefile: Restrict_DoT_and_DoH.rpz
    rpz-log: yes
    rpz-log-name: Restrict_DoT/DoH
    rpz-action-override: nxdomain
    rpz-signal-nxdomain-ra: yes"""

            printf "$conf_server\n\n" >> "$conf_server_fullfilepath"
            printf "$conf_extended\n\n" >> "$conf_extended_fullfilepath"
        }

        function block_DoT() {
            local name="Block DNS-over-TLS"
            local type="rule"

            uci revert firewall

            delete_firewall_entries "$type" "$name"

            uci add firewall rule
            uci set firewall.@$type[-1].name="$name"
            uci set firewall.@$type[-1].proto='tcp'
            uci set firewall.@$type[-1].src='lan'
            uci set firewall.@$type[-1].dest='wan'
            uci set firewall.@$type[-1].dest_port='853'
            uci set firewall.@$type[-1].target='REJECT'

            uci commit firewall
        }

        block_DoH
        block_DoT
        log "DNS queries over HTTPS and TLS are now blocked."
    }

    modify_sysctlconf
    apply_recommended_conf
    apply_recommended_uci_settings
    use_unbound_in_dnsmasq
    use_unbound_in_wan
    redirect_dns_requests
    block_encrypted_dns_requests

    log "Done set-up for unbound."

    local services_to_restart="firewall unbound dnsmasq network"
    for item in $services_to_restart; do
        log "Restarting service: $item"
        service $item restart
    done
}


function setup_ntp_server() {
    function redirect_NTP_queries() {
        local name="Redirect NTP, port 123"
        local type="redirect"

        uci revert firewall
        delete_firewall_entries "$type" "$name"
    
        uci add firewall $type
        uci set firewall.@$type[-1].target='DNAT'
        uci set firewall.@$type[-1].name="$name"
        uci set firewall.@$type[-1].proto='udp'
        uci set firewall.@$type[-1].src='lan'
        uci set firewall.@$type[-1].src_dport='123'

        uci commit firewall
    }

    function apply_recommended_uci_settings() {
        local uci_ntp="system.ntp"
        uci revert $uci_ntp

        uci set $uci_ntp.enabled='1'
        uci set $uci_ntp.enable_server='1'

        uci -q delete $uci_ntp.interface
        uci add_list $uci_ntp.interface="lan"

        local servers="""
            ph.pool.ntp.org
            0.asia.pool.ntp.org
            1.asia.pool.ntp.org
            2.asia.pool.ntp.org
            3.asia.pool.ntp.org
        """
        uci -q delete $uci_ntp.server
        for server in $servers; do
            server="$( printf $server | xargs )"
            [ -n $server ] && uci add_list $uci_ntp.server="$server"
        done
        uci commit $uci_ntp

        log "Applied recommended UCI settings for NTP"
    }

    redirect_NTP_queries
    apply_recommended_uci_settings

    log "Done set-up for NTP server."

    local services_to_restart="firewall sysntpd"
    for item in $services_to_restart; do
        log "Restarting service: $item"
        service $item restart
    done
}


function transmit_max_radio_power_always() {
    local pkg="wireless-regdb_2022.06.06-1_all.ipk"
    local pkg_url="https://cdn.discordapp.com/attachments/792707384619040798/1010520144650457169/wireless-regdb_2022.06.06-1_all.ipk"
    local dir="/tmp"

    wget -P $dir -O $pkg $pkg_url
    opkg install --force-reinstall $dir/$pkg

    uci revert wireless
    for uci_option in $( uci show wireless | grep .txpower | cut -d= -f1 ); do
        uci delete $uci_option
    done

    if [ -n "$( uci changes wireless )" ]; then
        uci commit wireless
        wifi
        log "Wi-Fi radios are now transmitting at max power."
    fi
}

function switch_to_odhcpd() {
    opkg remove odhcpd-ipv6only
    opkg install odhcpd
    uci set dhcp.lan.dhcpv4="server"
    uci set dhcp.odhcpd.maindhcp="1"
    uci set dhcp.odhcpd.leasefile="/var/lib/odhcpd/dhcp.leases"
    uci set dhcp.odhcpd.leasetrigger="/usr/lib/unbound/odhcpd.sh"
    uci -q delete dhcp.@dnsmasq[0]
    uci commit dhcp

    uci set unbound.ub_main.add_local_fqdn="3"
    uci set unbound.ub_main.add_wan_fqdn="1"
    uci set unbound.ub_main.dhcp4_slaac6="1"
    uci set unbound.ub_main.dhcp_link="odhcpd"
    uci set unbound.ub_main.listen_port="53"
    uci commit unbound

    opkg remove dnsmasq
    service unbound restart
    service odhcpd restart

    log "Used odhcpd with unbound, instead of dnsmasq."
}

function setup_router() {
    setup_ntp_server
    restore_packages
    setup_irqbalance
    setup_unbound
    setup_simpleadblock
    transmit_max_radio_power_always
    switch_to_odhcpd

    log "Completed setting up router."
}