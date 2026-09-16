# shellcheck shell=dash
# shellcheck disable=SC3043 # busybox ash has `local`; podkop's own script relies on it
# shellcheck disable=SC2016 # single-quoted jq filters use jq's own $vars, not the shell's
# podkop-sub: podkop itself - its uci sections, its clash api, which node runs

# an apply the core makes for itself keeps what it knows; only the user's own apply clears it
APPLY_KEEP=1

# empty when the user has not picked one yet; such a section is never touched
section_mode() {
    case "$(uci -q get "podkop-sub.$1.mode")" in
        selector) echo selector ;;
        urltest) echo urltest ;;
    esac
}

# single-quote a value for the generated backup script
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# uci returns a list space-separated; links never contain spaces, that is what sanitize_link is for
uci_list() {
    local v
    # shellcheck disable=SC2046
    for v in $(uci -q get "podkop.$1.$2"); do printf '%s\n' "$v"; done
}

current_links() {
    if [ "$(uci -q get "podkop.$1.proxy_config_type")" = urltest ]; then
        uci_list "$1" urltest_proxy_links
    else
        uci_list "$1" selector_proxy_links
    fi
}

backup_section() {
    local s="$1" o v tmp
    [ -f "$BACKUP_DIR/$s.uci" ] && return 0
    tmp="$BACKUP_DIR/$s.uci.$$"
    : > "$tmp"
    for o in connection_type proxy_config_type proxy_string; do
        if v=$(uci -q get "podkop.$s.$o"); then
            printf 'uci set podkop.%s.%s=%s\n' "$s" "$o" "$(shq "$v")" >> "$tmp"
        else
            printf 'uci -q delete podkop.%s.%s\n' "$s" "$o" >> "$tmp"
        fi
    done
    for o in selector_proxy_links urltest_proxy_links; do
        printf 'uci -q delete podkop.%s.%s\n' "$s" "$o" >> "$tmp"
        uci_list "$s" "$o" | while IFS= read -r v; do
            printf 'uci add_list podkop.%s.%s=%s\n' "$s" "$o" "$(shq "$v")" >> "$tmp"
        done
    done
    mv "$tmp" "$BACKUP_DIR/$s.uci"
}

rollback_section() {
    [ -f "$BACKUP_DIR/$1.uci" ] || return 0
    sh "$BACKUP_DIR/$1.uci"
}

forget_section() {
    rm -f "$BACKUP_DIR/$1.uci"
    state_apply --arg s "$1" 'del(.sections[$s])'
}

# remember which node the selector points at, by name, before the list is overwritten
remember_choice() {
    local s="$1" i link name
    [ "$(section_mode "$s")" = selector ] || return 0
    i=$(selector_index "$s")
    [ "$i" -gt 0 ] || return 0
    link=$(current_links "$s" | sed -n "${i}p")
    [ -n "$link" ] || return 0
    name=$(link_name "$link")
    # a node check failed over to is ours, not his: recording it would lose what to come back to
    [ "$name" = "$(sec_state "$s" failover)" ] && return 0
    state_apply --arg s "$s" --arg n "$name" \
        '.sections[$s] = ((.sections[$s] // {}) + {selected: $n})'
}

write_section() {
    local s="$1" f="$2" mode list other l
    backup_section "$s"
    if [ -n "$APPLY_KEEP" ]; then
        remember_choice "$s"
    else
        forget_choice "$s"
    fi
    mode=$(section_mode "$s")
    if [ "$mode" = urltest ]; then
        list=urltest_proxy_links
        other=selector_proxy_links
    else
        list=selector_proxy_links
        other=urltest_proxy_links
    fi
    uci set "podkop.$s.connection_type=proxy"
    uci set "podkop.$s.proxy_config_type=$mode"
    uci -q delete "podkop.$s.proxy_string"
    uci -q delete "podkop.$s.$other"
    # rewriting an identical list still counts as a uci change, so compare first
    [ "$(uci_list "$s" "$list")" = "$(cat "$f")" ] && return 0
    uci -q delete "podkop.$s.$list"
    while IFS= read -r l; do
        [ -n "$l" ] && uci add_list "podkop.$s.$list=$l"
    done < "$f"
}

# sing-box loads one config, so every group returns at once: wait for the first, not for each
# <section to watch for> <tries> - ~3 minutes, a live router regularly needs more than half of one
wait_for_group() {
    local s="$1" try=0
    while [ "$try" -lt "$2" ]; do
        "$PODKOP" clash_api get_proxies 2> /dev/null |
            jq -e --arg g "$s-out" '.proxies[$g]' > /dev/null 2>&1 && return 0
        try=$((try + 1))
        sleep 2
    done
    return 1
}

# the node the selector must end on: while a failover is in effect it is ours, not the user's pick
restore_target() {
    local n
    n=$(sec_state "$1" failover)
    [ -n "$n" ] || n=$(sec_state "$1" selected)
    printf '%s' "$n"
}

# only a selector section with a node to put back is worth waiting for
needs_restore() {
    [ "$(section_mode "$1")" = urltest ] && return 1
    [ -n "$(restore_target "$1")" ]
}

# put the selector back on the node that should carry the traffic, by name
restore_choice() {
    local s="$1" f="$2" want n
    needs_restore "$s" || return 0
    want=$(restore_target "$s")

    # the long wait already happened once in restore_nodes; this is only the per-group tail
    wait_for_group "$s" 5 || {
        log "$s: proxy group did not come back, keeping podkop's default"
        return 0
    }

    n=$(link_index "$f" "$want")
    [ "$n" -gt 0 ] || return 0
    "$PODKOP" clash_api set_group_proxy "$s-out" "$s-$n-out" > /dev/null 2>&1 ||
        log "$s: could not select $s-$n-out"
}

# apply hands over <dir>, which is ours to read and to remove
restore_nodes() {
    local dir="${1:-}" f s found='' waited=''
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    for f in "$dir"/sec.*; do
        [ -f "$f" ] || continue
        found=1
        s=${f##*/sec.}
        needs_restore "$s" || continue
        # one wait for podkop to come back, not one per section: three of them meant nine minutes
        if [ -z "$waited" ]; then
            waited=1
            wait_for_group "$s" "$RESTORE_WAIT"
        fi
        restore_choice "$s" "$f"
    done
    # only a handoff directory from apply is ever removed
    [ -n "$found" ] && rm -rf "$dir"
    return 0
}

# the clash API answers only while podkop and sing-box are both up
clash_up() {
    "$PODKOP" clash_api get_proxies 2> /dev/null | jq -e 'has("proxies")' > /dev/null 2>&1
}

# sets PING_MS; a tag podkop never wrote answers "Resource not found", which is not a delay
ping_node() {
    local d
    PING_MS=''
    d=$("$PODKOP" clash_api get_proxy_latency "$1-$2-out" "$3" 2> /dev/null |
        jq -r '.delay // 0' 2> /dev/null)
    case "$d" in '' | *[!0-9]*) return 1 ;; esac
    [ "$d" -gt 0 ] || return 1
    # shellcheck disable=SC2034 # read by probe_indexes in health.sh
    PING_MS=$d
}

# <links file> <node name> - its 1-based position, which is podkop's <section>-<i>-out index
link_index() {
    local i=0 l
    [ -n "$2" ] || {
        printf '0'
        return 0
    }
    while IFS= read -r l; do
        i=$((i + 1))
        if [ "$(link_name "$l")" = "$2" ]; then
            printf '%s' "$i"
            return 0
        fi
    done < "$1"
    printf '0'
}

# the node index the selector points at; 0 for a urltest group, direct-out or nothing
selector_index() {
    local now i
    now=$("$PODKOP" clash_api get_proxies 2> /dev/null |
        jq -r --arg g "$1-out" '.proxies[$g].now // ""' 2> /dev/null)
    i=${now#"$1"-}
    i=${i%-out}
    case "$i" in '' | *[!0-9]*) printf '0' ;; *) printf '%s' "$i" ;; esac
}

forget_failover() { state_apply --arg s "$1" 'del(.sections[$s].failover)'; }

# a save & apply is the user redoing his choice, so what we knew about the old one is void
forget_choice() { state_apply --arg s "$1" 'del(.sections[$s].selected, .sections[$s].failover)'; }

# move the selector ourselves, and record that this node is ours and not the user's choice
select_node() {
    local s="$1" i="$2" name="$3"
    "$PODKOP" clash_api set_group_proxy "$s-out" "$s-$i-out" > /dev/null 2>&1 || {
        log "$s: could not switch to $(safe_name "$name")"
        return 1
    }
    log "$s: switched to $(safe_name "$name")"
    state_apply --arg s "$s" --arg n "$name" \
        '.sections[$s] = ((.sections[$s] // {}) + {failover: $n})'
}
