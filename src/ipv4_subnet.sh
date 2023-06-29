#!/bin/sh

[ -n "$_ipv4_subnet_sh" ] \
    && return \
    || readonly _ipv4_subnet_sh="ipv4_subnet_sh[$$]"

source ${SOURCES_DIR:?Define ENV var:SOURCES_DIR}/utility.sh; abort_when_a_function_is_undefined "whois bc sort cut tr printf grep"
source $SOURCES_DIR/temp_file.sh

function convert_ipv4_address() {
    local input="${1:?Missing: IP address}" #Slash notation is OK too
    local convert="${2:?Missing: Converter function}"
    input="${input%/*}"

    local output octet
    for octet in ${input//./ }; do
        output="$output$( $convert "$octet" )."
    done
    printf "${output%.*}"
}

function convert_ipv4_address_decimal_to_binary() {
    function dec2bin() {
        printf "%08d" "$( printf "obase=2;$1\n" | bc )"
    }
    convert_ipv4_address "$1" "dec2bin"
}

function convert_ipv4_address_binary_to_decimal() {
    function bin2dec() {
        printf "ibase=2;$1\n" | bc
    }
    convert_ipv4_address "$1" "bin2dec"
}

function get_ipv4_subnets_by_asn() {
    whois --host whois.radb.net -- "-i origin AS${1:?Missing: ASN}" \
        | grep ^route: \
        | tr -s ' ' \
        | cut -d ' ' -f 2
}

function clear_file() {
    printf "" > "${1:?Mising: File to clear}"
}

function merge_ipv4_subnets() {
    local output_file="${1:?Missing: Output file}"
    local asns="${2:?Missing: List of ASNs, delimited by a whitespace}"

    clear_file "$output_file"
    local asn
    for asn in $asns; do
        get_ipv4_subnets_by_asn "$asn" >> "$output_file"
    done
}

function translate_ipv4_subnets() {
    local output_file="${1:?Missing: Output file}"
    local input_file="${2:?Missing: File containing the human-readable IPv4 subnets list}"

    clear_file "$output_file"
    local ipv4_subnet
    while read ipv4_subnet; do
        printf "$( convert_ipv4_address_decimal_to_binary "$ipv4_subnet" )/${ipv4_subnet#*/}\n" >> "$output_file"
    done < "$input_file"
}

function sort_ipv4_subnets() {
    sort "${2:?Missing: File containing the IPv4 subnets}" > "${1:?Missing: Output file}"
}

function optimize_ipv4_subnets() {
    local output_file="${1:?Missing: Output file}"
    local input_file="${2:?Missing: File containing translated IPv4 subnets}"

    local superset superset_mask subset

    function is_a_subset() {
        return $( printf "$superset != ${subset:0:$superset_mask}\n" | bc )
    }

    clear_file "$output_file"
    local ipv4_subnet
    while read ipv4_subnet; do
        subset="${ipv4_subnet//./}"

        if [ -z $superset ] || ! is_a_subset ; then
            superset_mask="${ipv4_subnet#*/}"
            superset="${subset:0:$superset_mask}"
            printf "$( convert_ipv4_address_binary_to_decimal "$ipv4_subnet" )/$superset_mask\n" >> "$output_file"
        fi
    done < "$input_file"
}

function get_ipv4_subnets() {
    local output_file="${1:?Missing: Output file}"
    local asns="${2:?Missing: List of ASNs, delimited by a whitespace}"

    local merged_file=$( create_temp_file )
    merge_ipv4_subnets "$merged_file" "$asns"

    local translated_file=$( create_temp_file )
    translate_ipv4_subnets "$translated_file" "$merged_file"

    local sorted_file="$merged_file"
    sort_ipv4_subnets "$sorted_file" "$translated_file"

    optimize_ipv4_subnets "$output_file" "$sorted_file"
}