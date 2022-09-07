#!/bin/sh

readonly unbound_root_dir="/etc/unbound"
readonly conf_server_fullfilepath="$unbound_root_dir/unbound_srv.conf"

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
        luci-app-unbound unbound-control \
        luci-app-wireguard
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

        local options="""
            config_update_enabled='0'
            verbosity='2'
            force_dns='0'
            led='none'
            dns='unbound.adb_list'
            compressed_cache='1'
            enabled='1'
            parallel_downloads='1'
            debug='0'
        """
        uci revert $uci_simpleadblock
        for uci_option in $options; do
            uci_option="$( printf $uci_option | xargs )"
            [ -n $uci_option ] && uci set $uci_simpleadblock.$uci_option
        done

        local blocked_hosts_url="""
            https://www.github.developerdan.com/hosts/lists/dating-services-extended.txt
            http://sbc.io/hosts/alternates/gambling/hosts
            https://www.github.developerdan.com/hosts/lists/hate-and-junk-extended.txt
        """
        uci -q delete $uci_simpleadblock.blocked_hosts_url
        for uci_option in $blocked_hosts_url; do
            uci_option="$( printf $uci_option | xargs )"
            [ -n $uci_option ] && uci add_list $uci_simpleadblock.blocked_hosts_url="$uci_option"
        done

        local blocked_domains_url="""
            'https://dbl.oisd.nl/'
            'https://dbl.oisd.nl/nsfw/'
            'https://s3.amazonaws.com/lists.disconnect.me/simple_malvertising.txt'
            'https://www.stopforumspam.com/downloads/toxic_domains_whole.txt'
        """
        uci -q delete $uci_simpleadblock.blocked_domains_url
        for uci_option in $blocked_domains_url; do
            uci_option="$( printf $uci_option | xargs )"
            [ -n $uci_option ] && uci add_list $uci_simpleadblock.blocked_domains_url="$uci_option"
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

function setup_unbound() {
    local domain="${1:?Missing: domain}"
    local port="${2:-1053}"

    local dns_packet_size="1232"

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
edns-buffer-size: $dns_packet_size"""

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

    function apply_recommended_uci_settings() {
        local uci_ub_main="""
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
        log "Recommended UCI options applied for unbound."
    }

    function use_unbound_in_dnsmasq() {
        local uci_dnsmasq="""
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

        function remove_old_redirections() {
            function get_old_redirects() {
                uci show firewall | grep "redirect.*name='$name_prefix" | cut -d. -f 2 | sort -r
            }

            for option in $( get_old_redirects ); do
                uci delete firewall.$option
            done
        }

        function redirect_dns_ports() {
            local dns_ports="53 5353"
            for port in $dns_ports; do
                uci add firewall redirect
                uci set firewall.@redirect[-1].target='DNAT'
                uci set firewall.@redirect[-1].name="$name_prefix - port $port"
                uci set firewall.@redirect[-1].src='lan'
                uci set firewall.@redirect[-1].src_dport="$port"
            done
        }

        uci revert firewall
        remove_old_redirections
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
    name: DNS-over-HTTPS
    url: https://raw.githubusercontent.com/jpgpi250/piholemanual/master/DOH.rpz
    rpz-action-override: nodata"""

            printf "$conf_server\n\n" >> "$conf_server_fullfilepath"
            printf "$conf_extended\n\n" >> "$conf_extended_fullfilepath"
        }

        function block_DoT() {
            local name="Block DNS-over-TLS"
            function remove_old_rules() {
                function get_old_rules() {
                    uci show firewall | grep "rule.*name='$name" | cut -d. -f 2 | sort -r
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
        function remove_old_redirections() {
            function get_old_redirects() {
                uci show firewall | grep "redirect.*name='$name" | cut -d. -f 2 | sort -r
            }

            for option in $( get_old_redirects ); do
                uci delete firewall.$option
            done
        }

        uci revert firewall
        remove_old_redirections
    
        uci add firewall redirect
        uci set firewall.@redirect[-1].target='DNAT'
        uci set firewall.@redirect[-1].name="$name"
        uci set firewall.@redirect[-1].proto='udp'
        uci set firewall.@redirect[-1].src='lan'
        uci set firewall.@redirect[-1].src_dport='123'

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

function setup_router(){
    setup_ntp_server
    restore_packages
    setup_irqbalance
    setup_unbound
    setup_simpleadblock

    log "Completed setting up router."
}
