#!/bin/sh

__tag="${1:?Missing: Tag}"

function log() {
    local tag="$__tag[$$]"
    local text="${@:?Missing: Text to log}"
    logger "$tag" "$text"
    printf "$( date -Iseconds ) $tag: $text \n"
}
