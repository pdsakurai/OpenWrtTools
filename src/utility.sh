#!/bin/sh

function is_function_defined() {
    command -V "${1:?Missing: Function name/s}" &> /dev/null
}

function abort_when_a_function_is_undefined() {
    local function_name
    for function_name in ${@:?Missing: Function name/s}; do
        local log_text="Function $function_name doesn't exist"
        ! is_function_defined "$function_name" \
            && ( is_function_defined "log" && log "$log_text" || echo "$log_text" ) \
            && exit 1
    done
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

    printf "$destination_file"
}

function include_in_backup_list() {
    [ -e "${1:?Missing: File/directory to backup}" ] \
        && trim_whitespaces "$1" >> "/etc/sysupgrade.conf" \
        || return 1
}
