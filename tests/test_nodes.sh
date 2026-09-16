#!/bin/sh
# shellcheck shell=dash
# L2: which nodes of a subscription reach podkop, and what a vanished node does.
set -u
. tests/lib.sh

ROOT=$PWD
MOCK_FIXTURE_DIR=$ROOT/tests/fixtures
MOCK_CALLS=/tmp/mock-calls
MOCK_PROXIES=/tmp/mock-proxies.json
MOCK_HEADERS=''
export MOCK_FIXTURE_DIR MOCK_CALLS MOCK_PROXIES MOCK_HEADERS

# plain.txt in fetch order: 1 NL, 2 the ss link with no fragment, 3 DE
NL='🇳🇱 NL 01 Amsterdam'
DE='🇩🇪 DE Frankfurt'

reset() {
    uci -q revert podkop
    uci -q revert podkop-sub
    rm -rf /etc/podkop-sub
    cp -r "$ROOT"/tests/mock/. /
    install_core
    chmod +x /usr/bin/podkop-sub /usr/bin/podkop /usr/bin/curl /etc/init.d/podkop
    echo '{"proxies":{}}' > "$MOCK_PROXIES"
    : > "$MOCK_CALLS"
    unset MOCK_BODY_plain
}

links_of() { # <section> <option> - one link per line, as uci stores them
    for l in $(uci -q get "podkop.$1.$2"); do printf '%s\n' "$l"; done
}

sub_of() { # <url suffix> - the id the core assigned to that subscription
    jq -r --arg u "$1" '.subs[] | select(.url | endswith($u)) | .id' /tmp/status.json
}

field_of() { # <id> <jq expression on the subscription object>
    jq -r --arg i "$1" ".subs[] | select(.id==\$i) | $2" /tmp/status.json
}

# ---------------------------------------------------------------- no choice means all

reset
podkop-sub update --all > /dev/null 2>&1
podkop-sub status > /tmp/status.json 2> /dev/null
id_plain=$(sub_of /plain)
id_alt=$(sub_of /alt)
CACHE=/etc/podkop-sub/cache

assert_eq "3" "$(field_of "$id_plain" '.nodes | length')" "status lists every cached node"
assert_eq "$NL" "$(field_of "$id_plain" '.nodes[0]')" "the node names are in the fetched order"
assert_eq "$DE" "$(field_of "$id_plain" '.nodes[2]')" "including the one on the CRLF line"
assert_eq "0" "$(field_of "$id_plain" '.missing | length')" "nothing is missing without a choice"

podkop-sub apply > /dev/null 2>&1
assert_eq "$(cat "$CACHE/$id_plain.lst")" "$(links_of media urltest_proxy_links)" \
    "an empty nodes list writes every link, as before"

# ---------------------------------------------------------------- a chosen subset

uci add_list "podkop-sub.@subscription[0].nodes=$DE"
uci add_list "podkop-sub.@subscription[0].nodes=$NL"
uci commit podkop-sub
chosen=$(uci -q show podkop-sub | grep nodes)

podkop-sub apply --force > /dev/null 2>&1
assert_eq "0" "$?" "apply exits 0 with a node choice"
assert_eq "$(sed -n '1p;3p' "$CACHE/$id_plain.lst")" "$(links_of media urltest_proxy_links)" \
    "only the chosen nodes are written, in the subscription's order"
assert_eq "$(sed -n '1p;3p' "$CACHE/$id_plain.lst"; cat "$CACHE/$id_alt.lst")" \
    "$(links_of main selector_proxy_links)" \
    "every targeted section gets the same choice, the other subscription untouched"
assert_eq "2" "$(jq -r '.sections.media.links' /etc/podkop-sub/state.json)" \
    "state.json counts the links that were actually written"

assert_eq "$chosen" "$(uci -q show podkop-sub | grep nodes)" "apply does not rewrite the choice"
assert_eq "" "$(uci changes podkop-sub)" "and leaves no uncommitted change behind"

# ---------------------------------------------------------------- a chosen node vanishes

MOCK_BODY_plain=alt
export MOCK_BODY_plain
podkop-sub update --all > /dev/null 2>&1
podkop-sub status > /tmp/status.json 2> /dev/null
assert_eq "2" "$(field_of "$id_plain" '.missing | length')" "both vanished names are recorded"
assert_eq "$DE" "$(field_of "$id_plain" '.missing[0]')" "missing keeps the order of the uci list"
assert_eq "ok" "$(field_of "$id_plain" '.status')" "a vanished node is not an error"
assert_eq "$chosen" "$(uci -q show podkop-sub | grep nodes)" "update does not rewrite the choice"

out=$(podkop-sub apply --force 2>&1)
assert_eq "0" "$?" "apply exits 0 when nothing the user chose is on offer"
assert_eq "$(sed -n 1p "$CACHE/$id_plain.lst")" "$(links_of media urltest_proxy_links)" \
    "a choice that matches nothing falls back to the first node"
assert_eq "" "$(printf '%s' "$out" | grep -i 'error\|fail')" "and says nothing alarming"
assert_eq "$chosen" "$(uci -q show podkop-sub | grep nodes)" "the fallback is never written back"

# ---------------------------------------------------------------- ack

podkop-sub ack "$id_plain" > /dev/null 2>&1
assert_eq "0" "$?" "ack exits 0"
podkop-sub status > /tmp/status.json 2> /dev/null
assert_eq "0" "$(field_of "$id_plain" '.missing | length')" "ack clears the warning"

podkop-sub update --all > /dev/null 2>&1
podkop-sub status > /tmp/status.json 2> /dev/null
assert_eq "0" "$(field_of "$id_plain" '.missing | length')" \
    "and it survives another update while the nodes are still gone"

unset MOCK_BODY_plain
podkop-sub update --all > /dev/null 2>&1
podkop-sub status > /tmp/status.json 2> /dev/null
assert_eq "0" "$(field_of "$id_plain" '.missing | length')" "a node that comes back clears itself"
assert_eq "false" "$(jq -r --arg i "$id_plain" '.subs[$i].missing_ack' /etc/podkop-sub/state.json)" \
    "an empty missing list drops the acknowledgement"

MOCK_BODY_plain=alt
export MOCK_BODY_plain
podkop-sub update --all > /dev/null 2>&1
podkop-sub status > /tmp/status.json 2> /dev/null
assert_eq "2" "$(field_of "$id_plain" '.missing | length')" "so a later disappearance warns again"

podkop-sub ack > /dev/null 2>&1
assert_eq "1" "$?" "ack without an id exits 1"

# ---------------------------------------------------------------- a name with no cache yet

reset
podkop-sub status > /tmp/status.json 2> /dev/null
assert_eq "0" "$(jq '[.subs[].nodes | length] | add' /tmp/status.json)" \
    "a subscription that was never fetched offers no nodes"
podkop-sub apply > /dev/null 2>&1
assert_eq "" "$(uci -q get podkop.media.urltest_proxy_links)" "and nothing is written for it"

test_summary
