#!/bin/sh

_temp_file_sh_temp_files=""

function create_temp_file() {
    _temp_file_sh_temp_files="$( mktemp ) $_temp_file_sh_temp_files"
}

function get_last_created_temp_file() {
    printf "${_temp_file_sh_temp_files%% *}"
}

function _temp_file_delete_temp_files() {
    local file
    for file in $_temp_file_sh_temp_files; do
        rm "$file"
    done
    _temp_file_sh_temp_files=""
}

trap _temp_file_delete_temp_files EXIT