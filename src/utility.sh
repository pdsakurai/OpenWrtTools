#!/bin/sh

function abort_when_a_function_is_undefined() {
    for function_name in ${@:?Missing: Function name/s}; do
        ! command -V "$function_name" &> /dev/null \
            && echo "Function $function_name doesn't exist" \
            && exit 1
    done
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

function uninstall_packages() {
    opkg remove --autoremove ${@:?Missing: packages}
    log "Done uninstaling packages."
}
