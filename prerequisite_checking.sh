#!/bin/sh

if [ -n "$_prerequisite_checking_sh" ]; then return; fi
readonly _prerequisite_checking_sh="1"

function abort_if_missing_executable() {
    local files="${1:?Missing: Files to check delimited by a whitespace}"
    local common_directory="${2%/}/"

    local has_error="false"
    local file
    for file in $files; do
        file="$common_directory$file"
        [ ! -x "$file" ] && printf "[$0] Missing pre-requisite: $file\n" && has_error="true"
    done

    [ "$has_error" == "true" ] && printf "[$0] Aborting...\n" && exit $SIGABRT
}