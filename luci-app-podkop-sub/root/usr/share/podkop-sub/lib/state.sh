# shellcheck shell=dash
# shellcheck disable=SC3043 # busybox ash has `local`; podkop's own script relies on it
# shellcheck disable=SC2016 # single-quoted jq filters use jq's own $vars, not the shell's
# podkop-sub: the debug log and state.json, which every other part reads

# deliberately not a setting: 64 KiB is enough to debug with and small enough to never matter
LOG_MAX=65536

# /tmp is tmpfs: a debug log there costs no flash writes and ends with the reboot
LOGFILE=/tmp/podkop-sub.log

# the page shows this file, so a message may name ids, hosts, sections and counts - never a URL
log() {
    local sz
    logger -t podkop-sub "$*"
    echo "$*"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE" 2> /dev/null
    sz=$(wc -c < "$LOGFILE" 2> /dev/null | tr -d ' ')
    [ "${sz:-0}" -gt "$LOG_MAX" ] || return 0
    # newest wins: keep the tail, and drop the half line the byte cut leaves at the top
    tail -c "$LOG_MAX" "$LOGFILE" | sed 1d > "$LOGFILE.tmp" && mv "$LOGFILE.tmp" "$LOGFILE"
    rm -f "$LOGFILE.tmp"
    return 0
}

cmd_logs() {
    case "${1:-}" in
        '') [ -f "$LOGFILE" ] && cat "$LOGFILE" ;;
        --clear) : > "$LOGFILE" ;;
        # the argument is never echoed back: a mistyped command must not paste a URL into the log
        *)
            log "logs: unknown option"
            return 1
            ;;
    esac
    return 0
}

state_json() {
    if [ -s "$STATE" ] && jq -e . "$STATE" > /dev/null 2>&1; then
        cat "$STATE"
    else
        echo '{"subs":{},"sections":{}}'
    fi
}

# state_apply <jq args...> <filter> - read-modify-write state.json atomically
state_apply() {
    local tmp="$STATE.$$"
    if state_json | jq "$@" > "$tmp" 2> /dev/null && [ -s "$tmp" ]; then
        mv "$tmp" "$STATE"
        return 0
    fi
    rm -f "$tmp"
    log "failed to update $STATE"
    return 1
}

# jq over one section of state.json: the abnormal state check left it in, "ok" when there is none
# shellcheck disable=SC2034 # read by subs.sh, health.sh and the status command
HEALTH='if .status == "fail" then "fail"
        elif (.added // "") != "" then "added"
        elif (.failover // "") != "" then "failover"
        else "ok" end'

# <option> <default> - an integer straight out of uci, without config_load
setting() {
    local v
    v=$(uci -q get "podkop-sub.settings.$1")
    case "$v" in '' | *[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$v" ;; esac
}

# one field of a section's state, empty when it was never written
sec_state() { state_json | jq -r --arg s "$1" --arg k "$2" '.sections[$s][$k] // ""'; }
