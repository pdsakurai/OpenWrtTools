#!/bin/sh

readonly SOURCES_DIR="$( pwd )/src"
export SOURCES_DIR
source $SOURCES_DIR/logger_helper.sh "recover_lost_settings.sh"

function remove_tx_limiter_on_wifi_radios() {
    local url="https://github.com/pdsakurai/OpenWrtTools/raw/main/resources/wireless"
    local pkg="wireless-regdb.ipk"

    cd /tmp
    wget "$url/$pkg"
    opkg install --force-reinstall "$pkg"

    log_info "Removed TX limiter on Wi-Fi radios."
}; remove_tx_limiter_on_wifi_radios

function enable_service() {
    local service_name="${1:?Missing: service name}"

    [[ "$( service $service_name status )" =~ ^\(active\|running\) ]] \
        && log_warning "Service $service_name is already enabled." \
        && return 1

    service $service_name enable \
        && service $service_name start \
        && log_info "Service $service_name has been enabled."
}

for item in update_ddns update_doh_servers update_known_devices update_rrm_nr; do
    enable_service $item
done
