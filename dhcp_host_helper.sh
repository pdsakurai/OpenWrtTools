#!/bin/sh

function add() {
    local name=${1:?Missing: Name}
    local mac=${2:?Missing: MAC address}
    local ip=$3

    ( is_existing "$name" || is_existing "$mac" || ([ -n "$ip" ] && is_existing "$ip" )) \
        && printf "Cannot add duplicate." \
        && return 1

    uci revert dhcp

    uci add dhcp host
    uci set dhcp.host[-1].name="$name"
    uci set dhcp.host[-1].mac="$mac"
    uci set dhcp.host[-1].dns='1'
    [ -n "$ip" ] && uci set dhcp.host[-1].ip="$ip"

    uci commit dhcp
}

function is_existing() {
    local keyword=${1:?Missing: name, MAC address or IP address}

    local hit hits="$( uci show dhcp | grep dhcp\.@host | grep -F $keyword )"
    for hit in $hits; do
        hit=$( printf ${hit#*=} | xargs )
        [ "$hit" == "$keyword" ] && return 0
    done

    return 1
}

function show() {
    local entry entries="$( uci show dhcp | grep host.*name )"
    for entry in $entries; do
        local name=${entry#*=}
        name=$( printf $name | xargs )

        local index=${entry#*[}
        index=${index%]*}

        printf "[$(( index + 1 ))] $name\n"
    done
}

function delete() {
    local max_number=$( show | grep -c ^)
    [ $max_number -le 0 ] && printf "There's nothing to delete.\n" && return 0

    show
    printf "\nEnter # to delete: "
    read number_to_delete

    ([ $number_to_delete -le 0 ] || [ $number_to_delete -gt $max_number ]) && printf "Invalid number detected.\n" && return 1

    uci revert dhcp
    uci delete dhcp.@host[$(( $number_to_delete - 1 ))]
    uci commit dhcp

    printf "Successfully deleted.\n"
}