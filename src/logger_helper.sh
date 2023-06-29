#!/bin/sh

[ -n "$_logger_helper_sh" ] \
    && return \
    || readonly _logger_helper_sh="_logger_helper_sh[$$]"

__tag="${1:?Missing: Tag}"

function log() {
    local level="info" tag text time_now="$( date -Iseconds )"
    case "$#" in
        1)
            tag="$__tag"
            text="$1"
            ;;
        2)
            tag="$1"
            text="$2"
            ;;
        3)
            level="$1"
            tag="$2"
            text="$3"
            ;;
        *)
            echo "Unexpected number of variables: $#"
            exit 1
            ;;
    esac
    tag="$tag[$$]"
    logger -t "$tag" -pdaemon.$level "$text"
    printf "$time_now $level $tag: $text\n"
}

function log_info() {
    log "info" "$__tag" "$@"
}

function log_warning() {
    log "warning" "$__tag" "$@"
}

function log_error() {
    log "err" "$__tag" "$@"
}