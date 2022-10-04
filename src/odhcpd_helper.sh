#!/bin/sh

__sources_dir="${1:?Missing: Sources directory}"

source $__sources_dir/logger_helper.sh "odhcpd_helper.sh"
source $__sources_dir/uci_helper.sh
source $__sources_dir/utility.sh

__pkg="odhcpd"
__resources_dir="${2:?Missing:Resources directory}/$__pkg"

function uninstall() {
    uninstall_packages odhcpd
    install_packages dnsmasq odhcpd-ipv6only

    uci -q delete dhcp.odhcpd
    [ $( uci show dhcp | grep -Fc "dnsmasq[0]" ) -le 0 ] && uci add dhcp dnsmasq
    uci commit dhcp

    local domain="$( uci show unbound.@unbound[0].domain | cut -d= -f2 | xargs )"
    $( source $__sources_dir/unbound_helper.sh \
            "$__sources_dir" \
            "$__resources_dir/.." \
            "/tmp" \
            "/tmp" \
            "$domain" \
        && __apply_uci_options \
        && __use_unbound_in_dnsmasq )

    restart_services unbound odhcpd dnsmasq
    log "Done switching from odhcpd to dnsmasq."
}

#Local DNS becomes unreliable based on benchmark. There's at least 30% drop in reliability metric.
function setup() {
    uninstall_packages $__pkg-ipv6only
    install_packages $__pkg

    local uci_option="dhcp"
    uci revert $uci_option
    set_uci_from_file "$uci_option" "$__resources_dir/uci.$uci_option"
    uci -q delete $uci_option.@dnsmasq[0]
    uci commit $uci_option

    uci_option="unbound"
    uci revert $uci_option
    set_uci_from_file "$uci_option" "$__resources_dir/uci.$uci_option"
    uci commit $uci_option

    uninstall_packages dnsmasq

    restart_services unbound $__pkg
    log "Done switching from dnsmasq to $__pkg."
}