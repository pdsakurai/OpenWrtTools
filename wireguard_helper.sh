#!/bin/sh

if [ -n "$_wireguard_helper_sh" ]; then return; fi
readonly _wireguard_helper_sh="1"

#Configuration
readonly target_interface="wireguard"

#ASNs
readonly asn_facebook="32934"
readonly asn_google="15169"
readonly asn_pldt="9299"

#Don't edit anything starting from this line
readonly target_uci_section="network.wireguard_$target_interface"
readonly target_uci_option="$target_uci_section.allowed_ips"

function reroute_traffic_by_asn() {
    local asns=${1:?Missing: ASNs, delimited by whitespace}
    printf "Rerouting traffic..."

    function reset_allowed_ips() {
        uci -q revert $target_uci_option
        uci -q delete $target_uci_option
    }
    reset_allowed_ips
    
    . ./temp_file.sh
    create_temp_file
    local ip_subnets_file=$( get_last_created_temp_file )

    $( . ./ipv4_subnet.sh; get_ipv4_subnets "$ip_subnets_file" "$asns" )

    local ip_subnet
    while read ip_subnet; do
        uci add_list $target_uci_option="$ip_subnet"
    done < "$ip_subnets_file"

    function apply_changes() {
        uci commit $target_uci_section
        ifdown $target_interface && ifup $target_interface
    }
    apply_changes
    printf "done!\n"
}