#!/bin/sh

[ -n "$_prerequisite_checking_sh" ] \
    && return \
    || readonly _prerequisite_checking_sh="prerequisite_checking_sh[$$]"

source ${SOURCES_DIR:?Define ENV var:SOURCES_DIR}/logger_helper.sh "prerequisite_checking.sh"

function abort_if_missing_executable() {
    local files="${1:?Missing: Files to check delimited by a whitespace}"
    local common_directory="${2%/}/"

    local file has_error="false"
    for file in $files; do
        file="$common_directory$file"
        [ ! -x "$file" ] && log "Missing pre-requisite: $file\n" && has_error="true"
    done

    [ "$has_error" == "true" ] && log "Aborting...\n" && exit $SIGABRT
}