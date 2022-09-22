#!/bin/sh

source ./src/logger_helper.sh "setup_openwrt.sh"
source ./src/uci_helper.sh

UNBOUND_ROOT_DIR="/etc/unbound"
UNBOUND_CONF_SRV_FULLFILEPATH="$UNBOUND_ROOT_DIR/unbound_srv.conf"
UNBOUND_CONF_EXT_FULLFILEPATH="$UNBOUND_ROOT_DIR/unbound_ext.conf"
RESOURCES_DIR="$( pwd )/resources"

function restart_services() {
    for item in ${@:?Missing: Service/s}; do
        log "Restarting service: $item"
        service $item restart
    done
}

function install_packages() {
    opkg install ${@:?Missing: packages}
    log "Done installing packages."
}

function load_and_append_to_another_file() {
    local source_file="${1:?Missing: Source file}"
    local destination_file="${1:?Missing: Destionation file}"

    local expected_first_line="$( head -1 "$source_file" )"
    [ $( grep -xc "$expected_first_line" "$destination_file" ) -gt 0 ] && return 1

    printf "\n\n" >> "$destination_file"
    cat "$source_file" >> "$destination_file"
}

function setup_simpleadblock() {
    local resources_dir="$RESOURCES_DIR/simple-adblock"

    local script_fullfilepath="/etc/init.d/simple-adblock"
    [ ! -e "$script_fullfilepath" ] && log "Cannot find file: $script_fullfilepath" && exit 1

    function use_always_null(){
        sed -i 's/\(local-zone\)*static/\1always_null/' "$script_fullfilepath"
        log "Changed simple-adblock's script for unblock: local-zone from static to always_null."
    }; use_always_null

    function prevent_reloading_whenever_wan_reloads() {
        sed -i "s/\(procd_add.*trigger.*wan.*\)/#\1/" "$script_fullfilepath"
        log "Prevented reloading simple-adblock whenever wan reloads."
    }; prevent_reloading_whenever_wan_reloads

    function apply_uci_options() {
        local uci_option="simple-adblock.config"
        local uci_options_fullfilepath="$resources_dir/uci.$uci_option"

        uci revert $uci_option
        set_uci_from_file "$uci_option" "$uci_options_fullfilepath"
        for uci_option_suffix in blocked_domains_url blocked_hosts_url; do
            add_list_uci_from_file "$uci_option.$uci_option_suffix" "$uci_options_fullfilepath.$uci_option_suffix"
        done
        uci commit $uci_option

        log "Recommended UCI options applied for simple-adblock."
    }; apply_uci_options

    function integrate_with_unbound() {
        load_and_append_to_another_file "$resources_dir/unbound_srv.conf" "$UNBOUND_CONF_SRV_FULLFILEPATH" \
            && log "simple-adblock now integrated with unbound."
    }; integrate_with_unbound

    function add_cron_job() {
        local cronjob="/etc/crontabs/root"
        touch "$cronjob"

        load_and_append_to_another_file "$resources_dir/cron" "$cronjob" \
            && log "Added cronjob for refreshing simple-adblock's blocklist every 03:30H of Monday."
    }; add_cron_job

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

function setup_unbound() {
    local domain="${1:?Missing: Domain}"
    local port="${2:-1053}"

    local dns_packet_size="1232"
    local resources_dir="$RESOURCES_DIR/unbound"

    function clean_uci_option() {
        local uci_option="$1"
        uci_option="$( printf "$uci_option" | sed s/\$domain/$domain/ )"
        uci_option="$( printf "$uci_option" | sed s/\$dns_packet_size/$dns_packet_size/ )"
        printf "$uci_option" | sed s/\$port/$port/
    }

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
        done < "$resources_dir/sysctl.conf"
    }; modify_sysctlconf

    function apply_baseline_conf() {
        local is_there_change=
        load_and_append_to_another_file "$resources_dir/unbound_srv.conf" "$UNBOUND_CONF_SRV_FULLFILEPATH" \
            && is_there_change="true" \
            && sed -i s/\$dns_packet_size/$dns_packet_size/ "$UNBOUND_CONF_SRV_FULLFILEPATH"
        [ -n $"is_there_change" ] \
            && load_and_append_to_another_file "$resources_dir/unbound_ext.conf" "$UNBOUND_CONF_EXT_FULLFILEPATH" \
            log "Baseline configuration applied for unbound."
    }; apply_baseline_conf

    function apply_uci_options() {
        local uci_unbound="unbound.@unbound[0]"
        uci revert $uci_unbound
        set_uci_from_file "$uci_unbound" "$resources_dir/uci.$uci_unbound" "clean_uci_option"
        uci commit $uci_unbound
        log "Recommended UCI options applied for unbound."
    }; apply_uci_options

    function use_unbound_in_dnsmasq() {
        local uci_dnsmasq="dhcp.@dnsmasq[0]"
        uci revert $uci_dnsmasq
        set_uci_from_file "$uci_dnsmasq" "$resources_dir/uci.$uci_dnsmasq" "clean_uci_option"
        add_list_uci_from_file "$uci_dnsmasq.server" "$resources_dir/uci.$uci_dnsmasq.server" "clean_uci_option"
        uci commit $uci_dnsmasq

        local uci_dhcp="dhcp.lan.dhcp_option"
        uci revert $uci_dhcp
        add_list_uci_from_file "$uci_dhcp" "$resources_dir/uci.$uci_dhcp"
        uci commit $uci_dhcp

        log "dnsmasq now uses unbound."
    }; use_unbound_in_dnsmasq

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

        uci revert firewall
        delete_firewall_entries "$type" "$name_prefix"
        function redirect_dns_ports() {
            local dns_ports="53 5353"
            for port in $dns_ports; do
                uci add firewall $type
                uci set firewall.@$type[-1].target='DNAT'
                uci set firewall.@$type[-1].name="$name_prefix - port $port"
                uci set firewall.@$type[-1].src='lan'
                uci set firewall.@$type[-1].src_dport="$port"
            done
        }; redirect_dns_ports
        uci commit firewall
        log "DNS requests from LAN are now redirected to unbound."
    }

    function block_encrypted_dns_requests() {
        function block_DoH_and_DoT_by_DNS() {
            printf "\n\n" >> "$UNBOUND_CONF_SRV_FULLFILEPATH"
            cat "$RESOURCES_DIR/firewall.unbound_srv.conf" >> "$UNBOUND_CONF_SRV_FULLFILEPATH"

            printf "\n\n" >> "$UNBOUND_CONF_EXT_FULLFILEPATH"
            cat "$RESOURCES_DIR/firewall.unbound_ext.conf" >> "$UNBOUND_CONF_EXT_FULLFILEPATH"
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
            server="$( printf "$server" | xargs )"
            [ -n "$server" ] && uci add_list $uci_ntp.server="$server"
        done
        uci commit $uci_ntp

        log "Applied recommended UCI settings for NTP"
    }

    redirect_NTP_queries
    apply_uci_options

    log "Done set-up for NTP server."

    restart_services firewall sysntpd
}

function switch_back_to_dnsmasq() {
    opkg remove odhcpd
    install_packages dnsmasq odhcpd-ipv6only

    uci -q delete dhcp.odhcpd
    [ $( uci show dhcp | grep -Fc "dnsmasq[0]" ) -le 0 ] && uci add dhcp dnsmasq
    uci commit dhcp

    local domain="$( uci show unbound.@unbound[0].domain | cut -d= -f2 | xargs )"
    setup_unbound "$domain"

    restart_services odhcpd
    log "Done restoring dnsmasq."
}

function switch_to_odhcpd() {
    opkg remove odhcpd-ipv6only
    install_packages odhcpd
    uci revert dhcp
    uci set dhcp.lan.dhcpv4="server"
    uci set dhcp.lan.dhcpv6="server"
    uci set dhcp.lan.ra='server'
    uci set dhcp.lan.ra_management='1'
    uci set dhcp.odhcpd.maindhcp="1"
    uci set dhcp.odhcpd.leasefile="/var/lib/odhcpd/dhcp.leases"
    uci set dhcp.odhcpd.leasetrigger="/usr/lib/unbound/odhcpd.sh"
    uci -q delete dhcp.@dnsmasq[0]
    uci commit dhcp

    local uci_option="unbound.@unbound[0]"
    uci revert $uci_option
    uci set $uci_option.add_local_fqdn="3"
    uci set $uci_option.add_wan_fqdn="1"
    uci set $uci_option.dhcp4_slaac6="1"
    uci set $uci_option.dhcp_link="odhcpd"
    uci set $uci_option.listen_port="53"
    uci commit $uci_option

    opkg remove dnsmasq
    log "Used odhcpd with unbound, instead of dnsmasq."

    restart_services unbound odhcpd
}

function commit_and_log_if_there_are_changes() {
    local uci_option="${1:?Missing: UCI option}"
    local log_text="${2:?Missing: Log text}"

    [ -z "$( uci changes $uci_option )" ] && return 1

    uci commit $uci_option
    log "$log_text"
    return 0
}

function setup_wifi() {
    local are_there_changes=

    function get_all_wifi_iface_uci() {
        uci show wireless | grep wireless.*=wifi-iface | sed s/=.*//
    }

    function enable_802dot11r() {
        uci revert wireless
        for uci_option_prefix in $( get_all_wifi_iface_uci ); do
            uci set $uci_option_prefix.ieee80211r='1'
            uci set $uci_option_prefix.reassociation_deadline='20000'
            uci set $uci_option_prefix.ft_over_ds='0'
            uci set $uci_option_prefix.ft_psk_generate_local='1'
            uci set $uci_option_prefix.mobility_domain='ACED'
        done
        commit_and_log_if_there_are_changes "wireless" "Done enabling 802.11r in all SSIDs." \
            && are_there_changes=0
    }; enable_802dot11r

    function transmit_max_radio_power_always() {
        #Source: https://discord.com/channels/413223793016963073/792707384619040798/1018010444918693898
        local pkg="wireless-regdb_2022.06.06-1_all.ipk"
        local pkg_url="https://raw.githubusercontent.com/pdsakurai/OpenWrtTools/main/resources/$pkg"
        local dir="/tmp"

        wget -P $dir -O $pkg $pkg_url
        opkg install --force-reinstall $dir/$pkg

        uci revert wireless
        for uci_option in $( uci show wireless | grep .txpower | cut -d= -f1 ); do
            uci delete $uci_option
        done
        commit_and_log_if_there_are_changes "wireless" "Wi-Fi radios are now transmitting at max power." \
            && are_there_changes=0
    }; transmit_max_radio_power_always

    [ -n "$are_there_changes" ] && restart_services network
    log "Done setting up WiFi"
}

function setup_dawn() {
    local are_there_changes=

    function enable_802dot11k_and_802dot11v() {
        opkg remove wpad-basic-wolfssl
        install_packages wpad-wolfssl

        for uci_option_prefix in $( get_all_wifi_iface_uci ); do
            uci revert $uci_option_prefix
            while read uci_option_suffix; do
                uci_option_suffix="$( printf "$uci_option_suffix" | xargs )"
                [ -n "$uci_option_suffix" ] && uci set $uci_option_prefix.$uci_option_suffix
            done < "$RESOURCES_DIR/dawn/uci.wireless.wifi-iface"
        done
        commit_and_log_if_there_are_changes "wireless" "Done enabling 802.11k and 802.11v in all SSIDs." \
            && are_there_changes=0
    }; enable_802dot11k_and_802dot11v

    function apply_recommended_uci_options() {
        install_packages luci-app-dawn
        local broadcast_address="$( ip address | grep inet.*br-lan | sed 's/.*brd \(.*\) scope.*/\1/' )"
        local uci_option="dawn.@network[0]"
        uci revert $uci_option
        [ -n "$broadcast_address" ] && uci set $uci_option.broadcast_ip="$broadcast_address"
        commit_and_log_if_there_are_changes "$uci_option" "dawn is now broadcasting via $broadcast_address" \
            && are_there_changes=0
    }; apply_recommended_uci_options

    [ -n "$are_there_changes" ] && restart_services network dawn
    log "Done setting up dawn"
}

function setup_router() {
    setup_ntp_server
    install_packages \
        irqbalance \
        kmod-usb-net-rndis \
        gawk grep sed coreutils-sort luci-app-simple-adblock \
        luci-app-unbound unbound-control
    setup_irqbalance
    setup_unbound
    setup_simpleadblock
    setup_wifi
    # switch_to_odhcpd #Local DNS becomes unreliable based on benchmark. There's at least 30% drop in reliability metric.

    log "Completed setting up router."
}

function setup_dumb_ap() {
    install_packages irqbalance
    setup_irqbalance
    setup_wifi

    log "Completed setting up dumb AP."
}