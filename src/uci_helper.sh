function __process_uci_from_file() {
    local uci_operation="${1:?Missing: UCI operation}"
    local uci_option="${2:?Missing: UCI option}"
    local uci_option_values_fullfilepath="${3:?Missing: UCI option values fullfilepath}"
    local line_cleaner_func="$4"

    [ "$uci_operation" == "add_list" ] && uci -q delete $uci_option
    while read uci_option_value; do
        uci_option_value="$( printf "$uci_option_value" | xargs )"
        [ -n "$line_cleaner_func" ] && uci_option_value="$( $line_cleaner_func "$uci_option_value" )"
        [ -n "$uci_option_value" ] && case $uci_operation in
            "add_list")
                uci add_list $uci_option="$uci_option_value"
                ;;
            "set")
                uci set $uci_option.$uci_option_value
                ;;
            *)
                log "Invalid UCI operation given: $uci_operation"
                exit 1
                ;;
        esac
    done < "$uci_option_values_fullfilepath"
}

function set_uci_from_file() {
    __process_uci_from_file "set" "$1" "$2" "$3"
}

function add_list_uci_from_file() {
    __process_uci_from_file "add_list" "$1" "$2" "$3"
}

function delete_firewall_entries() {
    local type=${1:?Missing: Firewall entry type}
    local name=${2:?Missing: Entry name}

    function search_entries() {
        uci show firewall | grep "$type.*name='$name" | cut -d. -f 2 | sort -r
    }

    for entry in $( search_entries ); do
        uci delete firewall.$entry
    done
}