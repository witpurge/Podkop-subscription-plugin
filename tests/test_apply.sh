#!/bin/sh
# shellcheck shell=dash
# L2: update/apply/restore against the podkop and curl mocks.
# The podkop fixture is stored in uci's own output format, so restore can be checked with cmp.
set -u
. tests/lib.sh

ROOT=$PWD
FIXTURE=$ROOT/tests/mock/etc/config/podkop
MOCK_FIXTURE_DIR=$ROOT/tests/fixtures
MOCK_CALLS=/tmp/mock-calls
MOCK_PROXIES=/tmp/mock-proxies.json
MOCK_HEADERS='Subscription-Userinfo: upload=100; download=200; total=1000; expire=2218276800'
export MOCK_FIXTURE_DIR MOCK_CALLS MOCK_PROXIES MOCK_HEADERS

# the shipped apply detaches the selector restore; inline here so assertions cannot race the child
PODKOP_SUB_SYNC=1
export PODKOP_SUB_SYNC

reset() {
    uci -q revert podkop
    rm -rf /etc/podkop-sub
    cp -r "$ROOT"/tests/mock/. /
    cp "$ROOT/luci-app-podkop-sub/root/usr/bin/podkop-sub" /usr/bin/podkop-sub
    chmod +x /usr/bin/podkop-sub /usr/bin/podkop /usr/bin/curl /etc/init.d/podkop
    echo '{"proxies":{"main-out":{"now":"main-1-out"},"media-out":{"now":"media-urltest-out"}}}' \
        > "$MOCK_PROXIES"
    : > "$MOCK_CALLS"
    unset MOCK_HTTP_CODE MOCK_HTTP_CODE_alt MOCK_BODY_alt MOCK_BODY_plain
}

links_of() { # <section> <option> - one link per line, as uci stores them
    for l in $(uci -q get "podkop.$1.$2"); do printf '%s\n' "$l"; done
}

# ---------------------------------------------------------------- update

reset
podkop-sub update --all > /dev/null 2>&1
assert_eq "0" "$?" "update --all exits 0"

podkop-sub status > /tmp/status.json 2> /dev/null
assert_cmd "status is valid JSON" jq -e . /tmp/status.json
assert_eq "2" "$(jq '.subs | length' /tmp/status.json)" "status lists both subscriptions"
assert_eq "3 2" "$(jq -r '[.subs[].count] | join(" ")' /tmp/status.json)" \
    "counts match the fixtures"
assert_eq "ok ok" "$(jq -r '[.subs[].status] | join(" ")' /tmp/status.json)" \
    "both subscriptions are ok"
assert_eq "true" "$(jq '[.subs[].updated] | all(. > 0)' /tmp/status.json)" \
    "updated timestamps are filled in"
assert_eq "1" "$(jq -r '.subs[0].skipped' /tmp/status.json)" "the vmess line is counted as skipped"
assert_eq "2218276800" "$(jq -r '.subs[0].expire' /tmp/status.json)" \
    "expire comes from subscription-userinfo"
assert_eq "700" "$(jq -r '.subs[0].traffic_left' /tmp/status.json)" \
    "traffic_left is total - upload - download"
assert_eq "0.7.22" "$(jq -r .podkop_version /tmp/status.json)" "podkop version comes from its CLI"
assert_eq "false" "$(jq -r '.service.running' /tmp/status.json)" "the service field is always present"

id_plain=$(jq -r '.subs[] | select(.url | endswith("/plain")) | .id' /tmp/status.json)
id_alt=$(jq -r '.subs[] | select(.url | endswith("/alt")) | .id' /tmp/status.json)
assert_cmd "cache file for the first subscription" test -s "/etc/podkop-sub/cache/$id_plain.lst"
assert_cmd "cache file for the second subscription" test -s "/etc/podkop-sub/cache/$id_alt.lst"

# one subscription fails: its cache stays, the other one is untouched
kept=$(sha256sum "/etc/podkop-sub/cache/$id_alt.lst" | cut -d' ' -f1)
MOCK_HTTP_CODE_alt=502
MOCK_BODY_alt=html
export MOCK_HTTP_CODE_alt MOCK_BODY_alt
podkop-sub update --all > /dev/null 2>&1
assert_eq "0" "$?" "update exits 0 while at least one subscription succeeds"
podkop-sub status > /tmp/status.json 2> /dev/null
assert_eq "error" "$(jq -r --arg i "$id_alt" '.subs[]|select(.id==$i)|.status' /tmp/status.json)" \
    "the failed subscription is marked error"
assert_contains "$(jq -r --arg i "$id_alt" '.subs[]|select(.id==$i)|.error' /tmp/status.json)" \
    "502" "the error carries the http code"
assert_eq "$kept" "$(sha256sum "/etc/podkop-sub/cache/$id_alt.lst" | cut -d' ' -f1)" \
    "the old cache survives a failed update"
assert_eq "ok" "$(jq -r --arg i "$id_alt" '.subs[]|select(.id!=$i)|.status' /tmp/status.json)" \
    "the other subscription is unaffected"

MOCK_HTTP_CODE=502
export MOCK_HTTP_CODE
podkop-sub update --all > /dev/null 2>&1
assert_eq "1" "$?" "update exits 1 when every subscription fails"

# ---------------------------------------------------------------- apply

reset
podkop-sub update --all > /dev/null 2>&1
: > "$MOCK_CALLS"
podkop-sub apply > /dev/null 2>&1
assert_eq "0" "$?" "apply exits 0"
assert_eq "proxy" "$(uci -q get podkop.main.connection_type)" "main switched to proxy"
assert_eq "selector" "$(uci -q get podkop.main.proxy_config_type)" "main uses selector"
assert_eq "urltest" "$(uci -q get podkop.media.proxy_config_type)" "media uses urltest"
assert_eq "" "$(uci -q get podkop.main.proxy_string)" "main.proxy_string was removed"
assert_eq "" "$(uci -q get podkop.media.selector_proxy_links)" "media has no selector list"
assert_eq "$(cat "/etc/podkop-sub/cache/$id_plain.lst" "/etc/podkop-sub/cache/$id_alt.lst")" \
    "$(links_of main selector_proxy_links)" "main got both subscriptions' links, in config order"
assert_eq "$(cat "/etc/podkop-sub/cache/$id_plain.lst")" "$(links_of media urltest_proxy_links)" \
    "media got only the subscription that targets it"
assert_contains "$(cat "$MOCK_CALLS")" "podkop-init restart" "apply restarts podkop"
assert_cmd "a backup was written for main" test -s /etc/podkop-sub/backup/main.uci
assert_eq "ok ok" "$(jq -r '[.sections[].status] | join(" ")' /etc/podkop-sub/state.json)" \
    "both sections are ok in state.json"
assert_eq "5" "$(jq -r '.sections.main.links' /etc/podkop-sub/state.json)" \
    "state.json records the link count"

# second apply with nothing to change
: > "$MOCK_CALLS"
out=$(podkop-sub apply 2>&1)
assert_eq "0" "$?" "a second apply exits 0"
assert_contains "$out" "no changes" "a second apply reports no changes"
assert_eq "" "$(uci changes podkop)" "a second apply leaves no uncommitted uci changes"
assert_eq "" "$(grep 'podkop-init restart' "$MOCK_CALLS")" "a second apply does not restart podkop"

# ---------------------------------------------------------------- selector choice

# main-4-out is the second subscription's first link; after the swap it must come back as main-1-out
echo '{"proxies":{"main-out":{"now":"main-4-out"},"media-out":{"now":"media-urltest-out"}}}' \
    > "$MOCK_PROXIES"
MOCK_BODY_plain=alt
MOCK_BODY_alt=plain
export MOCK_BODY_plain MOCK_BODY_alt
podkop-sub update --all > /dev/null 2>&1
: > "$MOCK_CALLS"
podkop-sub apply > /dev/null 2>&1
assert_eq "🇫🇮 FI Helsinki" "$(jq -r '.sections.main.selected' /etc/podkop-sub/state.json)" \
    "the selector choice was remembered by name"
assert_contains "$(cat "$MOCK_CALLS")" "clash_api set_group_proxy main-out main-1-out" \
    "the choice is restored at its new index"
assert_eq "" "$(grep 'set_group_proxy media-out' "$MOCK_CALLS")" \
    "a urltest section gets no set_group_proxy"

# the remembered name is no longer in the list
echo '{"proxies":{"main-out":{},"media-out":{}}}' > "$MOCK_PROXIES"
jq '.sections.main.selected = "gone"' /etc/podkop-sub/state.json > /tmp/state.json &&
    mv /tmp/state.json /etc/podkop-sub/state.json
: > "$MOCK_CALLS"
podkop-sub apply --force > /dev/null 2>&1
assert_eq "" "$(grep set_group_proxy "$MOCK_CALLS")" \
    "a name that is gone from the list produces no set_group_proxy"

# ---------------------------------------------------------------- restore

: > "$MOCK_CALLS"
podkop-sub restore > /dev/null 2>&1
assert_eq "0" "$?" "restore exits 0"
assert_cmd "restore puts /etc/config/podkop back byte for byte" cmp -s "$FIXTURE" /etc/config/podkop
assert_eq "" "$(ls /etc/podkop-sub/backup)" "restore removes the backups"
assert_eq "0" "$(jq '.sections | length' /etc/podkop-sub/state.json)" \
    "restore clears the section state"
assert_contains "$(cat "$MOCK_CALLS")" "podkop-init restart" "restore restarts podkop"

# ---------------------------------------------------------------- deleted podkop section

reset
podkop-sub update --all > /dev/null 2>&1
uci delete podkop.media && uci commit podkop
podkop-sub apply > /dev/null 2>&1
assert_eq "0" "$?" "apply exits 0 when a targeted section no longer exists"
assert_eq "false" "$(jq '.sections | has("media")' /etc/podkop-sub/state.json)" \
    "the deleted section leaves no state entry"
assert_cmd "the deleted section leaves no backup" test ! -e /etc/podkop-sub/backup/media.uci
assert_eq "selector" "$(uci -q get podkop.main.proxy_config_type)" \
    "the remaining section is applied normally"

podkop-sub restore > /dev/null 2>&1
assert_eq "0" "$?" "restore exits 0 with a deleted section"
assert_eq "url" "$(uci -q get podkop.main.proxy_config_type)" "restore rolled the live section back"
assert_cmd "restore does not recreate the deleted section" test -z "$(uci -q get podkop.media)"


# ---------------------------------------------------------------- section without a mode

reset
uci -q delete podkop-sub.media.mode && uci commit podkop-sub
podkop-sub update --all > /dev/null 2>&1
out=$(podkop-sub apply 2>&1)
assert_eq "0" "$?" "apply exits 0 when a targeted section has no mode"
assert_contains "$out" "section media has no configuration type set" \
    "the skipped section is named in the log"
assert_eq "url" "$(uci -q get podkop.media.proxy_config_type)" "the section without a mode is untouched"
assert_eq "" "$(uci -q get podkop.media.urltest_proxy_links)" "no links are written without a mode"
assert_cmd "no backup is taken for a section without a mode" test ! -e /etc/podkop-sub/backup/media.uci
assert_eq "false" "$(jq '.sections | has("media")' /etc/podkop-sub/state.json)" \
    "a section without a mode gets no state entry"
assert_eq "selector" "$(uci -q get podkop.main.proxy_config_type)" \
    "the section that has a mode is still applied"

podkop-sub status > /tmp/status.json 2> /dev/null
assert_eq "no-mode" "$(jq -r '.sections[]|select(.name=="media")|.status' /tmp/status.json)" \
    "status reports the missing mode"
assert_eq "" "$(jq -r '.sections[]|select(.name=="media")|.mode' /tmp/status.json)" \
    "status leaves the mode empty"
assert_eq "$(target_podkop)" "$(jq -r .target_podkop /tmp/status.json)" \
    "status carries the podkop version the plugin was built for"

# ---------------------------------------------------------------- the restore is detached

# the real path, without PODKOP_SUB_SYNC: the clash api is down, so the restore waits and times out
reset
podkop-sub update --all > /dev/null 2>&1
podkop-sub apply > /dev/null 2>&1
podkop-sub apply --force > /dev/null 2>&1
assert_eq "true" "$(jq '.sections.main | has("selected")' /etc/podkop-sub/state.json)" \
    "a selector choice is remembered, so the restore has work to do"

unset PODKOP_SUB_SYNC
MOCK_PODKOP_DOWN=1
PODKOP_SUB_WAIT=1
export MOCK_PODKOP_DOWN PODKOP_SUB_WAIT
: > "$MOCK_CALLS"
: > /tmp/podkop-sub.log
t0=$(date +%s)
podkop-sub apply --force > /dev/null 2>&1
rc=$?
elapsed=$(($(date +%s) - t0))
# from here on, anything in $MOCK_CALLS was done after apply had already returned
: > "$MOCK_CALLS"
assert_eq "0" "$rc" "apply exits 0 with the clash api down"
assert_cmd "apply returns in seconds, not after the restore window" test "$elapsed" -lt 5
assert_eq "" "$(grep 'did not come back' /tmp/podkop-sub.log)" \
    "the restore has not finished when apply returns"

out=$(podkop-sub apply 2>&1)
assert_eq "0" "$?" "a second apply is not blocked by the detached child"
assert_contains "$out" "no changes" "the child holds no lock"

waited=0
while [ "$waited" -lt 30 ] && ! grep -q 'did not come back' /tmp/podkop-sub.log; do
    waited=$((waited + 1))
    sleep 1
done
assert_contains "$(cat /tmp/podkop-sub.log)" "main: proxy group did not come back" \
    "the detached restore logs its timeout after apply has returned"
assert_contains "$(cat "$MOCK_CALLS")" "clash_api get_proxies" \
    "the child kept asking podkop after apply had returned"
echo "     apply returned in ${elapsed}s, the restore finished ~${waited}s later"

test_summary
