#!/bin/sh

function is_function_defined() {
    command -V "${1:?Missing: Function name/s}" &> /dev/null
}

function abort_when_a_function_is_undefined() {
    local function_name has_error log_text
    for function_name in ${@:?Missing: Function name/s}; do
        ! is_function_defined "$function_name" && {
            has_error=true
            log_text="Function $function_name doesn't exist."
            is_function_defined "log_error" && log_error "$log_text" || echo "$log_text"
        }
    done

    [ "$has_error" == "true" ] && {
        log_text="Aborting..."
        is_function_defined "log_error" && log_error "$log_text" || echo "$log_text"
        exit $SIGABRT
    }
}

function add_cron_job() {
    load_and_append_to_another_file \
        "${1:?Missing: File containing cron jobs}" \
        "/etc/crontabs/root"
}

function load_and_append_to_another_file() {
    local source_file="${1:?Missing: Source file}"
    local destination_file="${2:?Missing: Destination file}"

    mkdir -p "${destination_file%/*}"
    touch "$destination_file"
    local expected_first_line="$( head -1 "$source_file" )"
    [ $( grep -xc "$expected_first_line" "$destination_file" ) -gt 0 ] && return 1

    [ -n "$( head -1 "$destination_file" )" ] && printf "\n\n" >> "$destination_file"
    cat "$source_file" >> "$destination_file"
}

function restart_services() {
    local item
    for item in ${@:?Missing: Service/s}; do
        is_function_defined "log" && log "Restarting service: $item"
        service $item restart
    done
}

function install_packages() {
    opkg install ${@:?Missing: packages}
    is_function_defined "log" && log "Done installing packages."
}

function uninstall_packages() {
    opkg remove --autoremove ${@:?Missing: packages}
    is_function_defined "log" && log "Done uninstaling packages."
}

function trim_whitespaces() {
    printf "${1:?Missing: Text}" | sed -e "s/[[:space:]]*$//" -e "s/^[[:space:]]*//"
}

function upgrade_all_packages() {
    opkg list-upgradable | cut -f 1 -d ' ' | xargs -rt opkg upgrade
}

function copy_resource() {
    local source_file="${1:?Missing: Resource file}"
    local destination_file="$( head -1 "$source_file" )"

    local header="#Destination file: "
    local header_count="$( printf "$destination_file" | grep -c "$header" )"
    [ $header_count -ne 1 ] \
        && ( is_function_defined "log" && log "Cannot copy resource file ($source_file) without the destination file header." ) \
        && return 1

    destination_file="$( printf "$destination_file" | sed "s/$header//" )"
    cp -f "$source_file" "$destination_file"
    sed -i "1d" "$destination_file"

    include_in_backup_list "$destination_file"
    printf "$destination_file"
}

function include_in_backup_list() {
    local item="$( trim_whitespaces "${1:?Missing: File/directory to backup}" )"
    local backup_list="/etc/sysupgrade.conf"

    [ -e "$item" ] || return 1
    [ $( grep -xc "$item" "$backup_list" ) -le 0 ]  || return 1
    
    echo "$item" >> "$backup_list"
}

function get_lan_ipv4_address() {
    ubus call network.interface.lan status | jsonfilter -e '$["ipv4-address"][0].address'
}

function get_lan_ipv6_address() {
    ubus call network.interface.lan status | jsonfilter -e '$["ipv6-prefix-assignment"][*]["local-address"].address' | grep -P ^f\(c\|d\)
}

function setup_redirection_handling() {
    local resources_dir="${RESOURCES_DIR:?Define ENV var:RESOURCES_DIR}"
    copy_resource "$resources_dir/nft.chain_handle_redirection" &> /dev/null

    local type=
    for type in 4 6; do
        local ip_address=$( get_lan_ipv${type}_address )
        sed -i "s/\$LAN_IPV${type}_ADDRESS/$ip_address/" "$file"
    done
}

function get_lan_cidr() {
    local ip_address=$( ubus call network.interface.lan status | jsonfilter -e '$["ipv4-address"][0].address' )
    local mask=$( ubus call network.interface.lan status | jsonfilter -e '$["ipv4-address"][0].mask' )
    echo $ip_address/$mask
}