#!/bin/sh

[ -n "$_timer_helper_sh" ] \
    && return \
    || readonly _timer_helper_sh="timer_helper_sh[$$]"

function get_current_time() {
    date +%s
}

function start_timer() {
    . ./temp_file.sh
    local file=$( create_temp_file )
    get_current_time > "$file"
    printf "$file"
}

function end_timer() {
    local file="${1:?Missing: time ID}"

    local end_time=$( get_current_time )
    local start_time=$( cat "$file" )

    printf "$(( $end_time - $start_time )) second/s"
}