#!/bin/sh

source ${SOURCES_DIR:?Define ENV var:SOURCES_DIR}/logger_helper.sh "simpleadblock_helper.sh"
source $SOURCES_DIR/uci_helper.sh
source $SOURCES_DIR/utility.sh

__pkg="simple-adblock"
__script_fullfilepath="/etc/init.d/$__pkg"
__resources_dir="${RESOURCES_DIR:?Define ENV var:RESOURCES_DIR}/$__pkg"
__unbound_srv_conf_fullfilepath="${1:?Missing: Fullfilepath for unbound_src.conf}"


function __use_always_null(){
    sed -i 's/\(local-zone\)*static/\1always_null/' "$__script_fullfilepath"
    log "Changed $__pkg's script for unblock: local-zone from static to always_null."
}

function __prevent_reloading_whenever_wan_reloads() {
    sed -i "s/\(^[[:blank:]]*\)\(procd_add.*trigger.*wan.*\)/\1#\2/" "$__script_fullfilepath"
    log "Prevented reloading $__pkg whenever wan reloads."
}

function __apply_uci_options() {
    local uci_option="$__pkg.config"
    local uci_options_fullfilepath="$__resources_dir/uci.$uci_option"

    uci revert $uci_option
    set_uci_from_file "$uci_option" "$uci_options_fullfilepath"
    local uci_option_suffix
    for uci_option_suffix in allowed_domain blocked_domains_url blocked_hosts_url; do
        add_list_uci_from_file "$uci_option.$uci_option_suffix" "$uci_options_fullfilepath.$uci_option_suffix"
    done
    uci commit $uci_option

    log "Recommended UCI options applied for $__pkg."
}

function __integrate_with_unbound() {
    load_and_append_to_another_file "$__resources_dir/unbound_srv.conf" "$__unbound_srv_conf_fullfilepath" \
        && log "$__pkg now integrated with unbound."
}

function setup_simpleadblock() {
    install_packages \
        gawk \
        grep \
        sed \
        coreutils-sort \
        luci-app-$__pkg

    [ ! -e "$__script_fullfilepath" ] && log "Cannot find file: $__script_fullfilepath" && exit 1

    __use_always_null
    __prevent_reloading_whenever_wan_reloads
    __apply_uci_options
    __integrate_with_unbound

    add_cron_job "$__resources_dir/cron" \
        && log "Added cron job for refreshing $__pkg's blocklist every 03:30H of Monday."

    service $__pkg enable
    restart_services $__pkg
}
