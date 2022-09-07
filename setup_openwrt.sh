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

function enable_irqbalance() {
    uci revert irqbalance
    uci set irqbalance.irqbalance.enabled='1'
    uci commit irqbalance
    service irqbalance enable
    service irqbalance start

    log "Done enabling and starting irqbalance."
}

function setup_unbound() {
    local -r domain="${1:?Missing: domain}"
    local port="1053"
    local -r dns_packet_size="1232"

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
                sysctl -w $config
                log "Changed default value of $param from $value_current to $value_new"
            fi
        done
    }

    local -r unbound_root_dir="/etc/unbound"
    local -r conf_server_fullfilepath="$unbound_root_dir/unbound_srv.conf"
    local -r conf_extended_fullfilepath="$unbound_root_dir/unbound_ext.conf"

    function apply_recommended_conf() {
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

    function apply_recommended_uci_settings() {
        local -r uci_ub_main="""
            enabled='1'
            manual_conf='0'
            localservice='1'
            validator='1'
            validator='1'
            listen_port='$port'

            rebind_localhost='0'
            rebind_protection='1'
            dns64='0'
            domain_insecure=''
            root_age='9'

            dhcp_link='none'
            domain='$domain'
            domain_type='static'
            add_local_fqdn='0'
            add_wan_fqdn='0'
            add_extra_dns='0'
        
            unbound_control='1'
            protocol='default'
            resource='large'
            recursion='aggressive'
            query_minimize='1'
            query_min_strict='0'
            edns_size='$dns_packet_size'
            ttl_min='0'
            rate_limit='0'
            extended_stats='1'
        """

        uci revert unbound.ub_main
        for uci_option in $uci_ub_main; do
            uci_option="$( printf $uci_option | xargs )"
            [ -n $uci_option ] && uci set unbound.ub_main.$uci_option
        done
        uci commit unbound.ub_main
        
        /etc/init.d/unbound restart
    }

    function use_unbound_in_dnsmasq() {
        local -r uci_dnsmasq="""
            domainneeded='1'
            authoritative='1'
            local='/$domain/'
            domain='$domain'
            rebind_protection='0'
            localservice='1'
            localise_queries='1'
            expandhosts='1'
            ednspacket_max='$dns_packet_size'
            cachesize='0'
        """

        uci revert dhcp
        for uci_option in $uci_dnsmasq; do
            uci_option="$( printf $uci_option | xargs )"
            [ -n $uci_option ] && uci set dhcp.@dnsmasq[0].$uci_option
        done
        uci -q delete dhcp.@dnsmasq[0].server
        uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#$port"
        uci -q delete dhcp.lan.dhcp_option
        uci add_list dhcp.lan.dhcp_option='option:dns-server,0.0.0.0'
        uci commit dhcp
    
        /etc/init.d/dnsmasq restart
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

        if [ -n "$( uci changes network )" ]; then
            uci commit network
            /etc/init.d/network restart
        fi
    }

    function redirect_dns_requests() {
        local -r name_prefix="Redirect DNS"

        function remove_old_redirections() {
            function get_old_redirects() {
                uci show firewall | grep "redirect.*name='$name_prefix" | cut -d. -f 2
            }

            for option in $( get_old_redirects ); do
                uci delete firewall.$option
            done
        }

        function redirect_dns_ports() {
            local -r dns_ports="53 5353"
            for port in $( printf $dns_ports ); do
                uci add firewall redirect
                firewall.@redirect[-1].target='DNAT'
                firewall.@redirect[-1].name="$name_prefix - port $port"
                firewall.@redirect[-1].src='lan'
                firewall.@redirect[-1].src_dport="$port"
            done
        }

        uci revert firewall
        remove_old_redirections
        redirect_dns_ports

        if [ -n "$( uci changes firewall )" ]; then
            uci commit firewall
            /etc/init.d/firewall restart
        fi
    }

    function block_encrypted_dns_requests() {
        function block_DoH() {
            local -r conf_server="""
#For blocking DNS-over-HTTPS
module-config: "respip validator iterator"
            """

            local -r conf_extended="""
rpz:
    name: DNS-over-HTTPS
    url: https://raw.githubusercontent.com/jpgpi250/piholemanual/master/DOH.rpz
    rpz-action-override: nodata
            """

            echo $conf_server | xargs >> "$conf_server_fullfilepath"
            echo $conf_extended | xargs >> "$conf_extended_fullfilepath"

            /etc/init.d/unbound restart
        }

        function block_DoT() {
            local -r name="Block DNS-over-TLS"
            function remove_old_rules() {
                function get_old_rules() {
                    uci show firewall | grep "rule.*name='$name" | cut -d. -f 2
                }

                for option in $( get_old_rules ); do
                    uci delete firewall.$option
                done
            }

            uci revert firewall

            remove_old_rules

            uci add firewall rule
            uci set firewall.@rule[-1].name="$name"
            uci set firewall.@rule[-1].proto='tcp'
            uci set firewall.@rule[-1].src='lan'
            uci set firewall.@rule[-1].dest='wan'
            uci set firewall.@rule[-1].dest_port='853'
            uci set firewall.@rule[-1].target='REJECT'

            if [ -n "$( uci changes firewall )" ]; then
                uci commit firewall
                /etc/init.d/firewall restart
            fi
        }

        block_DoH
        block_DoT
    }

    apply_recommended_conf
    apply_recommended_uci_settings
    use_unbound_in_dnsmasq
    use_unbound_in_wan
    redirect_dns_requests
    block_encrypted_dns_requests
}