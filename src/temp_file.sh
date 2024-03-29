#!/bin/sh

[ -n "$_temp_file_sh" ] \
    && return \
    || readonly _temp_file_sh="temp_file_sh[$$]"

source ${SOURCES_DIR:?Define ENV var:SOURCES_DIR}/logger_helper.sh "temp_file.sh"

readonly _temporary_directory="/tmp/temp_file_sh_PID$$"
mkdir -p "$_temporary_directory"
log "Created directory: $_temporary_directory"

function _temp_file_delete_temp_files() {
    rm -rf "$_temporary_directory"
    log "Removed directory: $_temporary_directory"
}
trap _temp_file_delete_temp_files EXIT

function create_temp_file() {
    mktemp -p "$_temporary_directory"
}
