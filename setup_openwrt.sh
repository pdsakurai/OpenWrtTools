#!/bin/sh

source ./src/logger_helper.sh "setup_openwrt.sh"
source ./src/uci_helper.sh

UNBOUND_ROOT_DIR="/etc/unbound"
UNBOUND_CONF_SRV_FULLFILEPATH="$UNBOUND_ROOT_DIR/unbound_srv.conf"
UNBOUND_CONF_EXT_FULLFILEPATH="$UNBOUND_ROOT_DIR/unbound_ext.conf"
RESOURCES_DIR="$( pwd )/resources"
CUSTOM_FIREWALL_RULES_DIR="/etc/nftables.d"

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

function add_cron_job() {
    local source_file="${1:?Missing: File containing cronjobs}"
    local cronjob="/etc/crontabs/root"
    touch "$cronjob"
    load_and_append_to_another_file "$source_file" "$cronjob" || return 1
}

function load_and_append_to_another_file() {
    local source_file="${1:?Missing: Source file}"
    local destination_file="${2:?Missing: Destination file}"

    touch "$destination_file"
    local expected_first_line="$( head -1 "$source_file" )"
    [ $( grep -xc "$expected_first_line" "$destination_file" ) -gt 0 ] && return 1

    [ -n "$( head -1 "$destination_file" )" ] && printf "\n\n" >> "$destination_file"
    cat "$source_file" >> "$destination_file"
}

function setup_simpleadblock() {
    local pkg="simple-adblock"

    install_packages \
        gawk \
        grep \
        sed \
        coreutils-sort \
        luci-app-$pkg

    local resources_dir="$RESOURCES_DIR/$pkg"
    local script_fullfilepath="/etc/init.d/$pkg"
    [ ! -e "$script_fullfilepath" ] && log "Cannot find file: $script_fullfilepath" && exit 1

    function use_always_null(){
        sed -i 's/\(local-zone\)*static/\1always_null/' "$script_fullfilepath"
        log "Changed $pkg's script for unblock: local-zone from static to always_null."
    }; use_always_null

    function prevent_reloading_whenever_wan_reloads() {
        sed -i "s/\(procd_add.*trigger.*wan.*\)/#\1/" "$script_fullfilepath"
        log "Prevented reloading $pkg whenever wan reloads."
    }; prevent_reloading_whenever_wan_reloads

    function apply_uci_options() {
        local uci_option="$pkg.config"
        local uci_options_fullfilepath="$resources_dir/uci.$uci_option"

        uci revert $uci_option
        set_uci_from_file "$uci_option" "$uci_options_fullfilepath"
        for uci_option_suffix in blocked_domains_url blocked_hosts_url; do
            add_list_uci_from_file "$uci_option.$uci_option_suffix" "$uci_options_fullfilepath.$uci_option_suffix"
        done
        uci commit $uci_option

        log "Recommended UCI options applied for $pkg."
    }; apply_uci_options

    function integrate_with_unbound() {
        load_and_append_to_another_file "$resources_dir/unbound_srv.conf" "$UNBOUND_CONF_SRV_FULLFILEPATH" \
            && log "$pkg now integrated with unbound."
    }; integrate_with_unbound

    add_cron_job "$resources_dir/cron" \
        && log "Added cron job for refreshing $pkg's blocklist every 03:30H of Monday."

    service $pkg enable
    restart_services $pkg
}

function setup_irqbalance() {
    local pkg="irqbalance"

    install_packages $pkg

    uci revert $pkg
    set_uci_from_file "$pkg" "$RESOURCES_DIR/$pkg/uci.$pkg"
    uci commit $pkg

    service $pkg enable
    restart_services $pkg

    log "Done setting up $pkg."
}

function setup_unbound() {
    local domain="${1:?Missing: Domain}"
    local port="${2:-1053}"

    local pkg="unbound"
    install_packages \
        luci-app-$pkg \
        $pkg-control

    local dns_packet_size="1232"
    local resources_dir="$RESOURCES_DIR/$pkg"

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
        load_and_append_to_another_file "$resources_dir/${pkg}_srv.conf" "$UNBOUND_CONF_SRV_FULLFILEPATH" \
            && is_there_change="true" \
            && sed -i s/\$dns_packet_size/$dns_packet_size/ "$UNBOUND_CONF_SRV_FULLFILEPATH"
        [ -n $"is_there_change" ] \
            && load_and_append_to_another_file "$resources_dir/${pkg}_ext.conf" "$UNBOUND_CONF_EXT_FULLFILEPATH" \
            log "Baseline configuration applied for $pkg."
    }; apply_baseline_conf

    function apply_uci_options() {
        local uci_unbound="$pkg.@$pkg[0]"
        uci revert $uci_unbound
        set_uci_from_file "$uci_unbound" "$resources_dir/uci.$uci_unbound" "clean_uci_option"
        uci commit $uci_unbound
        log "Recommended UCI options applied for $pkg."
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

        log "dnsmasq now uses $pkg."
    }; use_unbound_in_dnsmasq

    function use_unbound_in_wan() {
        local uci_option="$( uci show network | grep .*wan.*=interface | cut -d= -f1 )"

        uci revert network
        set_uci_from_file "$uci_option" "$resources_dir/uci.network.interface"
        add_list_uci_from_file "$( printf "$uci_option" | sed "s/\(.*\)/\1.dns/" )" "$resources_dir/uci.network.interface.dns"

        uci commit network
        log "WAN interfaces now use $pkg."
    }; use_unbound_in_wan

    function redirect_dns_requests() {
        load_and_append_to_another_file "$resources_dir/firewall.redirect" "$CUSTOM_FIREWALL_RULES_DIR/99-redirect-dns.nft" \
            && log "DNS requests from LAN are now redirected."
    }; redirect_dns_requests

    function block_encrypted_dns_requests() {
        function block_DoH_and_DoT_by_DNS() {
            load_and_append_to_another_file "$resources_dir/${pkg}_srv.conf.firewall" "$UNBOUND_CONF_SRV_FULLFILEPATH"
            load_and_append_to_another_file "$resources_dir/${pkg}_ext.conf.firewall" "$UNBOUND_CONF_EXT_FULLFILEPATH"
        }; block_DoH_and_DoT_by_DNS

        function block_DoT_by_firewall() {
            local firewall_uci_fullfilepath="$resources_dir/uci.firewall.block-dns-over-tls"
            local name="$( grep "name=" "$firewall_uci_fullfilepath" | cut -d= -f2 | xargs )"
            local type="rule"

            uci revert firewall
            delete_firewall_entries "$type" "$name"

            uci add firewall rule
            local uci_option="firewall.@$type[-1]"
            set_uci_from_file "$uci_option"

            uci commit firewall
        }; block_DoT_by_firewall

        log "DNS queries over HTTPS and TLS are now blocked."
    }; block_encrypted_dns_requests

    log "Done set-up for $pkg."
    restart_services firewall $pkg dnsmasq network
}

function setup_ntp_server() {
    local resources_dir="$RESOURCES_DIR/ntp"

    function redirect_NTP_queries() {
        load_and_append_to_another_file "$resources_dir/firewall.redirect" "$CUSTOM_FIREWALL_RULES_DIR/99-redirect-ntp.nft" \
            && log "NTP requests from LAN are now redirected."
    }; redirect_NTP_queries

    function apply_uci_options() {
        local uci_ntp="system.ntp"

        uci revert $uci_ntp
        set_uci_from_file "$uci_ntp" "$resources_dir/uci.$uci_ntp"
        add_list_uci_from_file "$uci_ntp.interface" "$resources_dir/uci.$uci_ntp.interface"
        add_list_uci_from_file "$uci_ntp.server" "$resources_dir/uci.$uci_ntp.server"

        commit_and_log_if_there_are_changes "$uci_ntp" "Applied recommended UCI settings for NTP"
    }; apply_uci_options

    restart_services firewall sysntpd
    log "Done set-up for NTP server."
}

function switch_from_odhcpd_to_dnsmasq() {
    opkg remove odhcpd
    install_packages dnsmasq odhcpd-ipv6only

    uci -q delete dhcp.odhcpd
    [ $( uci show dhcp | grep -Fc "dnsmasq[0]" ) -le 0 ] && uci add dhcp dnsmasq
    uci commit dhcp

    local domain="$( uci show unbound.@unbound[0].domain | cut -d= -f2 | xargs )"
    setup_unbound "$domain"

    restart_services odhcpd
    log "Done switching from odhcpd to dnsmasq."
}

#Local DNS becomes unreliable based on benchmark. There's at least 30% drop in reliability metric.
function switch_from_dnsmasq_to_odhcpd() {
    local pkg="odhcpd"
    local resources_dir="$RESOURCES_DIR/$pkg"

    opkg remove $pkg-ipv6only
    install_packages $pkg

    local uci_option="dhcp"
    uci revert $uci_option
    set_uci_from_file "$uci_option" "$resources_dir/uci.$uci_option"
    uci -q delete $uci_option.@dnsmasq[0]
    uci commit $uci_option

    uci_option="unbound"
    uci revert $uci_option
    set_uci_from_file "$uci_option" "$resources_dir/uci.$uci_option"
    uci commit $uci_option

    opkg remove dnsmasq

    restart_services unbound $pkg
    log "Done switching from dnsmasq to $pkg."
}

function setup_wifi() {
    local are_there_changes=
    local resources_dir="$RESOURCES_DIR/wireless"

    function enable_802dot11r() {
        uci revert wireless
        set_uci_from_file "$( get_all_wifi_iface_uci )" "$resources_dir/uci.wifi-iface.802.11r"
        commit_and_log_if_there_are_changes "wireless" "Done enabling 802.11r in all SSIDs." \
            && are_there_changes=0
    }; enable_802dot11r

    function transmit_max_radio_power_always() {
        #Source: https://discord.com/channels/413223793016963073/792707384619040798/1018010444918693898
        local pkg="wireless-regdb_2022.06.06-1_all.ipk"
        opkg install --force-reinstall $resources_dir/$pkg

        uci revert wireless
        for uci_option in $( uci show wireless | grep .txpower | cut -d= -f1 ); do
            uci delete $uci_option
        done
        commit_and_log_if_there_are_changes "wireless" "Wi-Fi radios are now transmitting at max power." \
            && are_there_changes=0
    }; transmit_max_radio_power_always

    add_cron_job "$resources_dir/cron" \
        && log "Added cron job for restarting all Wi-Fi radios every 03:15H of the day."

    [ -n "$are_there_changes" ] && restart_services network
    log "Done setting up WiFi"
}

#Reference: https://openwrt.org/docs/guide-user/network/wifi/dawn
function setup_dawn() {
    local are_there_changes=
    local pkg="dawn"
    local resources_dir="$RESOURCES_DIR/$pkg"

    function enable_802dot11k_and_802dot11v() {
        opkg remove wpad-basic-wolfssl
        install_packages wpad-wolfssl
        uci revert wireless
        local wifi_iface_uci="$( get_all_wifi_iface_uci )"
        set_uci_from_file "$wifi_iface_uci" "$resources_dir/uci.wireless.wifi-iface.802.11k"
        set_uci_from_file "$wifi_iface_uci" "$resources_dir/uci.wireless.wifi-iface.802.11v"
        commit_and_log_if_there_are_changes "wireless" "Done enabling 802.11k and 802.11v in all SSIDs." \
            && are_there_changes=0
    }; enable_802dot11k_and_802dot11v

    function apply_recommended_uci_options() {
        install_packages luci-app-$pkg
        local broadcast_address="$( ip address | grep inet.*br-lan | sed 's/.*brd \(.*\) scope.*/\1/' )"

        function clean_uci_option() {
            printf "$1" | sed s/\$broadcast_address/$broadcast_address/
        }
        uci revert $pkg
        set_uci_from_file "$pkg" "$resources_dir/uci.dawn" "clean_uci_option"
        commit_and_log_if_there_are_changes "$pkg" "$pkg is now broadcasting via $broadcast_address" \
            && are_there_changes=0
    }; apply_recommended_uci_options

    [ -n "$are_there_changes" ] && restart_services network $pkg
    log "Done setting up $pkg."
}

function setup_usb_tether() {
    install_packages kmod-usb-net-rndis
    log "Done setting up support for Android USB-tethered internet connection."
}

function setup_ipv6_dhcp_in_router() {
    local uci_option="dhcp.lan"
    local resources_dir="$RESOURCES_DIR/ipv6"
    uci revert $uci_option
    set_uci_from_file "$uci_option" "$resources_dir/uci.$uci_option"
    uci_option="dhcp.lan.ra_flags"
    add_list_uci_from_file "$uci_option" "$resources_dir/uci.$uci_option"
    uci commit $uci_option

    log "Done setting up IPv6 DHCP."
    restart_services network
}

function setup_router() {
    opkg update

    setup_ntp_server
    setup_irqbalance
    setup_usb_tether
    setup_unbound
    setup_simpleadblock
    setup_wifi
    setup_ipv6_dhcp_in_router

    log "Completed setting up router."
}

function setup_dumb_ap() {
    opkg update

    setup_irqbalance
    setup_wifi

    log "Completed setting up dumb AP."
}