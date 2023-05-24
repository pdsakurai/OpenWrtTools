#!/bin/sh

source ${SOURCES_DIR:?Define ENV var:SOURCES_DIR}/logger_helper.sh "ntp_helper.sh"
source $SOURCES_DIR/uci_helper.sh
source $SOURCES_DIR/utility.sh

__resources_dir="${RESOURCES_DIR:?Define ENV var:RESOURCES_DIR}/ntp"

function __redirect_NTP_queries() {
    copy_resource "$__resources_dir/nft.firewall" &> /dev/null
    setup_redirection_handling
    log "NTP traffic from LAN are now redirected."
}

function __apply_uci_options() {
    local uci_ntp="system.ntp"

    uci revert $uci_ntp
    set_uci_from_file "$uci_ntp" "$__resources_dir/uci.$uci_ntp"
    add_list_uci_from_file "$uci_ntp.interface" "$__resources_dir/uci.$uci_ntp.interface"
    add_list_uci_from_file "$uci_ntp.server" "$__resources_dir/uci.$uci_ntp.server"

    commit_and_log_if_there_are_changes "$uci_ntp" "Applied recommended UCI settings for NTP"
}

function setup_ntp_server() {
    __redirect_NTP_queries
    __apply_uci_options

    restart_services firewall sysntpd
    log "Done set-up for NTP server."
}
