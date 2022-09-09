#!/bin/sh

readonly unbound_root_dir="/etc/unbound"
readonly unbound_conf_srv_fullfilepath="$unbound_root_dir/unbound_srv.conf"
readonly unbound_conf_ext_fullfilepath="$unbound_root_dir/unbound_ext.conf"
readonly resources_dir="$( pwd )/resources"

function log() {
    local _setup_openwrt_sh="_setup_openwrt_sh[$$]"
    logger -t "$_setup_openwrt_sh" "$@"
    printf "$_setup_openwrt_sh: $@\n"
}

function restart_services() {
    local services="$@"
    for item in ${@:?Missing: Service/s}; do
        log "Restarting service: $item"
        service $item restart
    done
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
        [ ! -e "$fullfilepath_script" ] && log "Cannot find file: $fullfilepath_script" && return 1
        sed -i 's/\(local-zone\)*static/\1always_null/' "$fullfilepath_script"
        log "Changed simple-adblock's script for unblock: local-zone from static to always_null."
    }

    function apply_uci_options() {
        local uci_simpleadblock="simple-adblock.uci"

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
        if [ $( grep -c simple-adblock "$unbound_conf_srv_fullfilepath" ) -le 0 ]; then
            printf "\n\n" >> "$unbound_conf_srv_fullfilepath"
            cat "$resources_dir/simple-adblock.unbound_srv.conf" >> "$unbound_conf_srv_fullfilepath"
            log "simple-adblock now integrated with unbound."
        fi
    }

    use_always_null
    apply_uci_options
    integrate_with_unbound
    restart_services simple-adblock
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
            sysctl "${1:?Missing: parameter}" 2> /dev/null | cut -d= -f2 | xargs
        }

        while read config; do
            local param=$( printf "$config" | cut -d= -f1 )

            local value_new=$( printf "$config" | cut -d= -f2 )
            local value_current=$( read_sysctl_value "$param" )
            if [ -n "$value_current" ] && [ "$value_current" -lt "$value_new" ]; then
                echo "$config" >> "/etc/sysctl.conf"
                sysctl -w $config
                log "Changed default value of $param from $value_current to $value_new"
            fi
        done < "$resources_dir/unbound.sysctl.conf"
    }

    function apply_baseline_conf() {
        sed s/\$dns_packet_size/$dns_packet_size/ "$resources_dir/unbound.unbound_srv.conf" > "$unbound_conf_srv_fullfilepath"
        cp -f "$resources_dir/unbound.unbound_ext.conf" "$unbound_conf_ext_fullfilepath"
        log "Baseline configuration applied for unbound."
    }

    function load_uci_from_file() {
        local uci_option_prefix="${1:?Missing: UCI option prefix}"
        local uci_option_suffix_filename="${2:?Missing: Filename}"

        while read uci_option_suffix; do
            uci_option_suffix="$( printf $uci_option_suffix | xargs )"
            uci_option_suffix="$( printf $uci_option_suffix | sed s/\$domain/$domain/ )"
            uci_option_suffix="$( printf $uci_option_suffix | sed s/\$dns_packet_size/$dns_packet_size/ )"
            uci_option_suffix="$( printf $uci_option_suffix | sed s/\$port/$port/ )"
            [ -n $uci_option_suffix ] && uci set $uci_option_prefix.$uci_option_suffix
        done < "$resources_dir/$uci_option_suffix_filename"
    }

    function apply_uci_options() {
        local uci_unbound="unbound.@unbound[0]"
        uci revert $uci_unbound
        load_uci_from_file "$uci_unbound" "unbound.uci"
        uci commit $uci_unbound
        log "Recommended UCI options applied for unbound."
    }

    function use_unbound_in_dnsmasq() {
        local uci_dnsmasq="dhcp.@dnsmasq[0]"
        uci revert $uci_dnsmasq
        load_uci_from_file "$uci_dnsmasq" "unbound.dnsmasq.uci"
        uci -q delete $uci_dnsmasq.server
        uci add_list $uci_dnsmasq.server="127.0.0.1#$port"
        uci commit $uci_dnsmasq

        local uci_dhcp="dhcp.$domain.dhcp_option"
        uci revert $uci_dhcp
        uci -q delete $uci_dhcp
        uci add_list $uci_dhcp='option:dns-server,0.0.0.0'
        uci commit $uci_dhcp
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
        function block_DoH_and_DoT_by_DNS() {
            printf "\n\n" >> "$unbound_conf_srv_fullfilepath"
            cat "$resources_dir/firewall.unbound_srv.conf" >> "$unbound_conf_srv_fullfilepath"

            printf "\n\n" >> "$unbound_conf_ext_fullfilepath"
            cat "$resources_dir/firewall.unbound_ext.conf" >> "$unbound_conf_ext_fullfilepath"
        }

        function block_DoT_by_firewall() {
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

        block_DoH_and_DoT_by_DNS
        block_DoT_by_firewall
        log "DNS queries over HTTPS and TLS are now blocked."
    }

    modify_sysctlconf
    apply_baseline_conf
    apply_uci_options
    use_unbound_in_dnsmasq
    use_unbound_in_wan
    redirect_dns_requests
    block_encrypted_dns_requests

    log "Done set-up for unbound."

    restart_services firewall unbound dnsmasq network
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

    function apply_uci_options() {
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
    apply_uci_options

    log "Done set-up for NTP server."

    restart_services firewall sysntpd
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
    log "Used odhcpd with unbound, instead of dnsmasq."

    restart_services unbound odhcp
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