#!/bin/sh

source ${SOURCES_DIR:?Define ENV var:SOURCES_DIR}/logger_helper.sh "unbound_helper.sh"
source $SOURCES_DIR/uci_helper.sh
source $SOURCES_DIR/utility.sh

__pkg="unbound"
__resources_dir="${RESOURCES_DIR:?Define ENV var:RESOURCES_DIR}/$__pkg"
__unbound_srv_conf_fullfilepath="${1:?Missing: unbound_srv.conf fullfilepath}"
__unbound_ext_conf_fullfilepath="${2:?Missing: unbound_ext.conf fullfilepath}"
__domain="${3:?Missing: Domain}"

function __update_domain() {
    printf "$1" | sed s/\$domain/$__domain/
}

function __modify_sysctlconf() {
    function read_sysctl_value() {
        local value="$( sysctl "${1:?Missing: parameter}" 2> /dev/null | cut -d= -f2 )"
        trim_whitespaces "$value"
    }

    local config
    while read config; do
        local param=$( printf "$config" | cut -d= -f1 )

        local value_new=$( printf "$config" | cut -d= -f2 )
        local value_current=$( read_sysctl_value "$param" )
        if [ -n "$value_current" ] && [ "$value_current" -lt "$value_new" ]; then
            echo "$config" >> "/etc/sysctl.conf"
            sysctl -w $config
            log "Changed default value of $param from $value_current to $value_new"
        fi
    done < "$__resources_dir/sysctl.conf"
}

function __apply_baseline_conf() {
    local is_there_change=
    load_and_append_to_another_file "$__resources_dir/${__pkg}_srv.conf" "$__unbound_srv_conf_fullfilepath" \
        && is_there_change="true"
    [ -n $"is_there_change" ] \
        && load_and_append_to_another_file "$__resources_dir/${__pkg}_ext.conf" "$__unbound_ext_conf_fullfilepath" \
        log "Baseline configuration applied for $__pkg."
}

function __apply_uci_options() {
    local uci_unbound="$__pkg.@$__pkg[0]"
    uci revert $uci_unbound
    set_uci_from_file "$uci_unbound" "$__resources_dir/uci.$uci_unbound" "__update_domain"
    uci commit $uci_unbound
    log "Recommended UCI options applied for $__pkg."
}

function __use_unbound_in_dnsmasq() {
    local uci_dnsmasq="dhcp.@dnsmasq[0]"
    uci revert $uci_dnsmasq
    set_uci_from_file "$uci_dnsmasq" "$__resources_dir/uci.$uci_dnsmasq" "__update_domain"
    uci commit $uci_dnsmasq

    local uci_dhcp="dhcp.lan.dhcp_option"
    uci revert $uci_dhcp
    add_list_uci_from_file "$uci_dhcp" "$__resources_dir/uci.$uci_dhcp"
    uci commit $uci_dhcp

    log "dnsmasq now uses $__pkg."
}

function __use_unbound_in_wan() {
    local uci_option="$( uci show network | grep .*wan.*=interface | cut -d= -f1 )"

    uci revert network
    set_uci_from_file "$uci_option" "$__resources_dir/uci.network.interface"
    uci delete ${uci_option}.dns

    uci commit network
    log "WAN interfaces now use $__pkg."
}

function __redirect_dns_requests() {
    copy_resource "$__resources_dir/nft.handle_dns_traffic" &> /dev/null
    setup_redirection_handling
    log "DNS traffic from LAN are now redirected."
}

function __block_external_access() {
    copy_resource "$__resources_dir/nft.block_access_to_dnsmasq_and_unbound" &> /dev/null \
        && log "External access to unbound is now blocked."
}

function __block_encrypted_dns_requests() {
    function block_DoH_and_DoT_by_DNS() {
        load_and_append_to_another_file "$__resources_dir/${__pkg}_srv.conf.firewall" "$__unbound_srv_conf_fullfilepath"
        load_and_append_to_another_file "$__resources_dir/${__pkg}_ext.conf.firewall" "$__unbound_ext_conf_fullfilepath"
    }; block_DoH_and_DoT_by_DNS

    function block_DoH_by_firewall() {
        copy_resource "$__resources_dir/nft.set_doh_servers_ipv4" \
            && copy_resource "$__resources_dir/nft.set_doh_servers_ipv6" \
            && copy_resource "$__resources_dir/nft.handle_https_traffic" \
            && copy_resource "$__resources_dir/nft.chain_block_doh_traffic" \
            && copy_resource "$__resources_dir/service.update_doh_servers.bin" \
            && copy_resource "$__resources_dir/service.update_doh_servers.initscript" \
            && service update_doh_servers enable \
            && log "DoH is now blocked via firewall."
    }; block_DoH_by_firewall

    function block_DoT_by_firewall() {
        copy_resource "$__resources_dir/nft.block_dot_traffic" \
            && log "DoT is now blocked via firewall."
    }; block_DoT_by_firewall

    log "DNS queries over HTTPS and TLS are now blocked."
}

function __block_3rd_parties_by_DNS() {
    load_and_append_to_another_file "$__resources_dir/${__pkg}_srv.conf.firewall" "$__unbound_srv_conf_fullfilepath"
    load_and_append_to_another_file "$__resources_dir/${__pkg}_ext.conf.firewall.3rdParties" "$__unbound_ext_conf_fullfilepath"
    log "3rd parties (e.g. ads, trackers) are now blocked via DNS."
}

function setup_unbound() {
    install_packages \
        luci-app-$__pkg \
        $__pkg-control

    __modify_sysctlconf
    __apply_baseline_conf
    __apply_uci_options
    __use_unbound_in_dnsmasq
    __use_unbound_in_wan
    __redirect_dns_requests
    __block_external_access
    __block_encrypted_dns_requests
    __block_3rd_parties_by_DNS

    log "Done set-up for $__pkg."
    restart_services firewall $__pkg dnsmasq network update_doh_servers
}
