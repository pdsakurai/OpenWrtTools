#!/bin/sh

if [ -n "$_wireguard_helper_sh" ]; then return; fi
readonly _wireguard_helper_sh="1"

#Configuration
readonly target_interface="wireguard"

#ASNs
readonly asn_facebook="32934"
readonly asn_google="15169"
readonly asn_pldt="9299"
readonly asn_smart="10139"

#Don't edit anything starting from this line
readonly target_uci_section="network.wireguard_$target_interface"
readonly target_uci_option="$target_uci_section.allowed_ips"

readonly file_previous_allowed_ips="wireguard_helper_allowed_ips.txt"


function are_the_same_files() {
    local file_1="${1:?Missing: File 1}"
    local file_2="${2:?Missing: File 2}"

    function is_existing() {
        [ -e "$1" ] && return 0 || return 1
    }

    function get_md5sum() {
        md5sum "$1" | cut -d ' ' -f 1
    }

    local md5sum_file_1=$( is_existing "$file_1" && get_md5sum "$file_1" )
    local md5sum_file_2=$( is_existing "$file_2" && get_md5sum "$file_2" )

    [ "$md5sum_file_1" == "$md5sum_file_2" ] && return 0 || return 1
}

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

    local new_file_name="${ip_subnets_file%/*}/$file_previous_allowed_ips"
    if are_the_same_files "$ip_subnets_file" "$new_file_name"; then
        printf "no changes made.\n"
    else
        local ip_subnet
        while read ip_subnet; do
            uci add_list $target_uci_option="$ip_subnet"
        done < "$ip_subnets_file"

        function apply_changes() {
            uci commit $target_uci_section
            ifdown $target_interface && ifup $target_interface
        }
        apply_changes
        mv "$ip_subnets_file" "$new_file_name"
        printf "done!\n"
    fi
}