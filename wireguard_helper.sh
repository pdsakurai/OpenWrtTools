#!/bin/sh

[ -n "$_wireguard_helper_sh" ] \
    && return \
    || readonly _wireguard_helper_sh="wireguard_helper_sh[$$]"

#Configuration
readonly target_interface="${1:?Missing: Target Wireguard interface}"
readonly target_peer="${2:?Missing: Target peer based on UCI section}"

#ASNs
readonly asn_facebook="32934"
readonly asn_google="15169"
readonly asn_pldt="9299"
readonly asn_smart="10139"

readonly SOURCES_DIR="$( pwd )/src"
export SOURCES_DIR
source $SOURCES_DIR/logger_helper.sh "wireguard_helper.sh"
source $SOURCES_DIR/temp_file.sh
source $SOURCES_DIR/timer_helper.sh
source $SOURCES_DIR/ipv4_subnet.sh

readonly target_uci_section="network.$target_peer"
readonly target_uci_option="$target_uci_section.allowed_ips"

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
    local other_ip_addresses=$2
    
    local ip_subnets_file=$( create_temp_file )
    local timer=$( start_timer )
    log "Started retrieving IPv4 subnets for ASNs: ${asns// /,}"
    $( get_ipv4_subnets "$ip_subnets_file" "$asns" )
    timer=$( end_timer "$timer" )
    log "Done retrieving IPv4 subnets within $timer."

    timer=$( start_timer )
    log "Started re-routing traffic."
    local file_previous_allowed_ips="/tmp/wireguard_helper_allowed_ips.txt"
    if are_the_same_files "$ip_subnets_file" "$file_previous_allowed_ips"; then
        log "Same set of IP subnets produced. No changes made."
    elif [ $( wc -l "$ip_subnets_file" | cut -d' ' -f1 ) -le 0 ]; then
        log "No IP subnets found. No changes made."
    else
        function reset_allowed_ips() {
            uci -q revert $target_uci_option
            uci -q delete $target_uci_option
        }
        reset_allowed_ips

        local ip_subnet
        for ip_subnet in $other_ip_addresses; do
            uci add_list $target_uci_option="$ip_subnet"
        done

        while read ip_subnet; do
            uci add_list $target_uci_option="$ip_subnet"
        done < "$ip_subnets_file"

        function apply_changes() {
            uci commit $target_uci_section
            ifup $target_interface
        }
        apply_changes
        mv "$ip_subnets_file" "$file_previous_allowed_ips"
        timer=$( end_timer "$timer" )
        log "Done re-routing traffic within $timer."
    fi
}