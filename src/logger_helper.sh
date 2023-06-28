#!/bin/sh

[ -n "$_logger_helper_sh" ] \
    && return \
    || readonly _logger_helper_sh="_logger_helper_sh[$$]"

__tag="${1:?Missing: Tag}"

function log() {
    local tag text time_now="$( date -Iseconds )"
    case "$#" in
        1)
            tag="$__tag"
            text="$1"
            ;;
        2)
            tag="$1"
            text="$2"
            ;;
        *)
            echo "Unexpected number of variables: $#"
            exit 1
            ;;
    esac
    tag="$tag[$$]"
    logger -t "$tag" "$text"
    printf "$time_now $tag: $text\n"
}
