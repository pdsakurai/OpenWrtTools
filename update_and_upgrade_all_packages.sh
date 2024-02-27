#!/bin/sh

readonly SOURCES_DIR="$( pwd )/src"
export SOURCES_DIR
source $SOURCES_DIR/logger_helper.sh "update_and_upgrade_all_packages.sh"

opkg update
log "Done updating package lists."

opkg list-upgradable | grep -v wireless-regdb | cut -f 1 -d ' ' | xargs -rt opkg upgrade
log "Done upgrading packages."