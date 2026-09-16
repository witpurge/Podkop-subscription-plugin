# shellcheck shell=dash
# shellcheck disable=SC3043 # busybox ash has `local`; podkop's own script relies on it
# shellcheck disable=SC2016 # single-quoted jq filters use jq's own $vars, not the shell's
# podkop-sub: keeping the traffic on a node that answers

# <count> <index to try first> <index to try last> - every index once, 0 meaning no preference
probe_order() {
    local i=1
    [ "$2" -ge 1 ] && [ "$2" -le "$1" ] && [ "$2" != "$3" ] && printf '%s ' "$2"
    while [ "$i" -le "$1" ]; do
        [ "$i" = "$2" ] || [ "$i" = "$3" ] || printf '%s ' "$i"
        i=$((i + 1))
    done
    [ "$3" -ge 1 ] && [ "$3" -le "$1" ] && printf '%s ' "$3"
    return 0
}

# <section> <links file> <timeout> <max failures> <index...> - sets PROBE_WIN and PROBE_TRIED
probe_indexes() {
    local s="$1" f="$2" to="$3" maxf="$4" i name
    shift 4
    PROBE_WIN=0
    PROBE_TRIED=0
    for i in "$@"; do
        name=$(link_name "$(sed -n "${i}p" "$f")")
        PROBE_TRIED=$((PROBE_TRIED + 1))
        if ping_node "$s" "$i" "$to"; then
            log "$s: $(safe_name "$name") answered in $PING_MS ms"
            PROBE_WIN=$i
            return 0
        fi
        log "$s: $(safe_name "$name") did not answer"
        [ "$PROBE_TRIED" -lt "$maxf" ] || break
    done
    return 1
}

mark_section() {
    state_apply --arg s "$1" --arg st "$2" --argjson f "$3" --argjson t "$(date +%s)" \
        '.sections[$s] = ((.sections[$s] // {}) + {status: $st, fails: $f, checked: $t})
         | if (.sections[$s] | '"$HEALTH"') == "ok" then del(.sections[$s].health_ack) else . end'
}

# <link> <seconds> - is there a TCP socket at the endpoint? 2 when the link cannot be probed.
# curl's exit code cannot answer this: a server that accepts the connection and then stays silent
# times out with 28, exactly like one that was never reachable. time_connect separates them - it is
# zero only when the handshake itself never completed. A silent socket is what a VLESS endpoint
# looks like when curl speaks MQTT at it, so this is the common case, not an edge one.
tcp_up() {
    local hp t
    # hy2/hysteria2 are UDP: there is nothing to connect to, and "cannot tell" is not "dead"
    case "$1" in hy2://* | hysteria2://*) return 2 ;; esac
    hp=$(link_hostport "$1")
    case "$hp" in *:*) ;; *) return 2 ;; esac
    # mqtt:// is the cheapest plain-TCP scheme this curl has: telnet:// is not compiled in
    t=$(curl -sk -o /dev/null -w '%{time_connect}' \
        --connect-timeout "$2" --max-time "$(($2 + 1))" "mqtt://$hp" 2> /dev/null)
    # any non-zero digit means the connect completed, whatever separator the build prints
    case "$(printf '%s' "$t" | tr -dc '0-9')" in
        *[1-9]*) return 0 ;;
    esac
    return 1
}

# the first node the section's subscriptions offer that it does not carry and that TCP answers
emergency_link() {
    local s="$1" f="$2" id l secs
    secs=$((($(setting ping_timeout 2000) + 999) / 1000))
    [ "$secs" -ge 1 ] || secs=1
    for id in $(section_subs "$s"); do
        [ -s "$CACHE_DIR/$id.lst" ] || continue
        while IFS= read -r l; do
            grep -Fxq "$l" "$f" && continue
            tcp_up "$l" "$secs"
            case "$?" in
                0)
                    printf '%s\n' "$l"
                    return 0
                    ;;
                # our stdout is the link the caller captures, so these lines go to stderr
                2) log "$s: $(safe_name "$(link_name "$l")") cannot be probed, skipping it" >&2 ;;
                *) log "$s: $(safe_name "$(link_name "$l")") is not reachable, skipping it" >&2 ;;
            esac
        done < "$CACHE_DIR/$id.lst"
    done
    return 1
}

# every chosen node is dead: borrow one the user did not pick, and let apply write it in
add_emergency() {
    local s="$1" f="$2" link name
    link=$(emergency_link "$s" "$f")
    [ -n "$link" ] || {
        log "$s: the subscription offers nothing else, leaving the section as it is"
        return 1
    }
    name=$(link_name "$link")
    log "$s: every node is dead, borrowing $(safe_name "$name") from the subscription"
    state_apply --arg s "$s" --arg n "$name" --arg l "$link" \
        '.sections[$s] = ((.sections[$s] // {}) + {added: $n, added_link: $l})' || return 1
    # a uci commit and a podkop restart: once per check pass, never in a loop
    CHECK_ADDED=1
    cmd_apply
    wait_for_group "$s" "$RESTORE_WAIT"
}

# a chosen node answers again: the section goes back to the user's selection alone
drop_emergency() {
    local s="$1" name="$2"
    log "$s: $(safe_name "$name") is not needed any more, dropping it from the section"
    state_apply --arg s "$s" 'del(.sections[$s].added, .sections[$s].added_link)' || return 1
    cmd_apply
    wait_for_group "$s" "$RESTORE_WAIT"
}

# <section> <its links> - nothing in the section answers, so re-read the subscriptions feeding
# it and apply. 1 when the links did not change: the same list is still the same dead nodes.
refresh_section() {
    local s="$1" id
    log "$s: nothing answered, re-reading the subscriptions"
    for id in $(section_subs "$s"); do
        cmd_update "$id"
    done
    cmd_apply
    [ "$(current_links "$s")" != "$(cat "$2")" ] || return 1
    wait_for_group "$s" "$RESTORE_WAIT" || log "$s: podkop's proxy groups did not come back"
}

# probe the node that carries the traffic, fail over when it dies, come back when it revives
check_section() {
    local s="$1" to="$2" maxf="$3" again="${4:-}"
    local f n mode sel fail add add_i fail_i sel_i now order name win
    if ! uci -q get "podkop.$s" > /dev/null 2>&1; then
        log "section $s is gone from podkop, dropping it"
        forget_section "$s"
        return 0
    fi
    f="$CHECKTMP/links.$s"
    current_links "$s" > "$f"
    n=$(wc -l < "$f" | tr -d ' ')
    if [ "$n" -eq 0 ]; then
        log "$s: podkop has no links for this section"
        mark_section "$s" fail 0
        return 0
    fi
    # a pick that is no longer in the section can never answer again, so it is not a pick
    sel=$(sec_state "$s" selected)
    if [ -n "$sel" ] && [ "$(link_index "$f" "$sel")" -eq 0 ]; then
        log "$s: $(safe_name "$sel") is not in this section any more, forgetting it"
        forget_choice "$s"
    fi
    # no apply happens in a healthy pass, so this is the only place his pick is ever learned
    remember_choice "$s"
    mode=$(section_mode "$s")
    sel=$(sec_state "$s" selected)
    fail=$(sec_state "$s" failover)
    add=$(sec_state "$s" added)
    add_i=$(link_index "$f" "$add")
    fail_i=$(link_index "$f" "$fail")
    sel_i=$(link_index "$f" "$sel")
    now=0
    [ "$mode" = selector ] && now=$(selector_index "$s")
    # a failover lasts only while the selector still sits on it; anything that moved it ended it
    if [ -n "$fail" ] && [ "$fail_i" -eq 0 ]; then
        forget_failover "$s"
        fail=''
    elif [ -n "$fail" ] && [ "$now" -gt 0 ] && [ "$now" != "$fail_i" ]; then
        log "$s: the selector left $(safe_name "$fail"), that failover is over"
        forget_failover "$s"
        fail=''
        fail_i=0
    fi

    # while the selector sits where we put it, the user's own nodes are what the probe is for
    if [ "$mode" = selector ] && [ "$fail_i" -gt 0 ]; then
        order=$(probe_order "$n" "$sel_i" "$fail_i")
    elif [ "$mode" != selector ] && [ "$add_i" -gt 0 ]; then
        order=$(probe_order "$n" 0 "$add_i")
    elif [ "$mode" = selector ]; then
        order=$(probe_order "$n" "$now" 0)
    else
        # a urltest section picks for itself; there is no "current" node to start from
        order=$(probe_order "$n" "$(awk -v n="$n" 'BEGIN { srand(); print int(rand() * n) + 1 }')" 0)
    fi

    # shellcheck disable=SC2086 # the order is a list of indexes: word splitting is the point
    if ! probe_indexes "$s" "$f" "$to" "$maxf" $order; then
        log "$s: no node answered ($PROBE_TRIED of $n tried)"
        # only a section with nothing left to run on is worth a fetch and podkop's restart
        if [ -z "$again" ] && [ "$PROBE_TRIED" -ge "$n" ] && refresh_section "$s" "$f"; then
            check_section "$s" "$to" "$maxf" 1
            return 0
        fi
        if [ "$PROBE_TRIED" -ge "$n" ] && [ -z "$CHECK_ADDED" ] && add_emergency "$s" "$f"; then
            current_links "$s" > "$f"
            add=$(sec_state "$s" added)
            add_i=$(link_index "$f" "$add")
            if [ "$add_i" -gt 0 ]; then
                probe_indexes "$s" "$f" "$to" 1 "$add_i"
                [ "$mode" = selector ] && select_node "$s" "$add_i" "$add"
                if [ "$PROBE_WIN" -gt 0 ]; then
                    mark_section "$s" ok 0
                    return 0
                fi
            fi
        fi
        mark_section "$s" fail "$PROBE_TRIED"
        return 0
    fi

    win=$PROBE_WIN
    name=$(link_name "$(sed -n "${win}p" "$f")")
    # every link but the borrowed one is the user's, so a win elsewhere means his side is back
    if [ -n "$add" ] && [ "$win" != "$add_i" ]; then
        drop_emergency "$s" "$add"
        current_links "$s" > "$f"
        win=$(link_index "$f" "$name")
        now=0
        [ "$mode" = selector ] && now=$(selector_index "$s")
    fi
    if [ "$mode" = selector ] && [ "$win" -gt 0 ] && [ "$win" != "$now" ]; then
        if [ "$name" = "$sel" ]; then
            "$PODKOP" clash_api set_group_proxy "$s-out" "$s-$win-out" > /dev/null 2>&1 ||
                log "$s: could not switch to $(safe_name "$name")"
        else
            select_node "$s" "$win" "$name"
        fi
    fi
    # the recovery is reported where the failover is dropped, not where the selector is moved
    if [ "$name" = "$sel" ] && [ -n "$fail" ]; then
        log "$s: $(safe_name "$name") answers again, the selector is back on it"
        forget_failover "$s"
    fi
    mark_section "$s" ok 0
    return 0
}

cmd_check() {
    local timeout maxf s
    if ! clash_up; then
        log "podkop is not answering, skipping the check"
        return 0
    fi
    timeout=$(setting ping_timeout 2000)
    maxf=$(setting max_failures 5)
    [ "$maxf" -ge 1 ] || maxf=1
    CHECK_ADDED=''
    CHECKTMP=$(mktemp -d) || return 1
    # a pass only probes; a section left with nothing to run on re-reads its own subscriptions
    for s in $(state_json | jq -r '.sections | keys[]?'); do
        check_section "$s" "$timeout" "$maxf"
    done
    rm -rf "$CHECKTMP"
    return 0
}

DAEMON_STOP=0

# ash finishes a plain `sleep` before handling a signal, so wait on it instead
nap() {
    local pid
    [ "$DAEMON_STOP" = 0 ] || return 0
    sleep "$1" &
    pid=$!
    wait "$pid"
    kill "$pid" 2> /dev/null
    return 0
}

cmd_daemon() {
    local interval
    trap 'DAEMON_STOP=1' TERM INT
    log "daemon started"
    # let podkop and sing-box finish booting before the first check
    nap 60
    while [ "$DAEMON_STOP" = 0 ]; do
        config_load podkop-sub
        cmd_check
        [ "$DAEMON_STOP" = 0 ] || break
        interval=$(setting check_interval 60)
        [ "$interval" -ge 1 ] || interval=60
        nap $((interval * 60))
    done
    log "daemon stopped"
    return 0
}
