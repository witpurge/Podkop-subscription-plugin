#!/bin/sh
# shellcheck shell=dash
# L2: the debug log - what reaches it, that it stays capped, and the logs subcommand.
set -u
. tests/lib.sh

ROOT=$PWD
MOCK_FIXTURE_DIR=$ROOT/tests/fixtures
MOCK_CALLS=/tmp/mock-calls-logs
MOCK_PROXIES=/tmp/mock-proxies-logs.json
MOCK_HEADERS='Subscription-Userinfo: upload=100; download=200; total=1000; expire=2218276800'
export MOCK_FIXTURE_DIR MOCK_CALLS MOCK_PROXIES MOCK_HEADERS

# the shipped apply detaches the selector restore; inline here so assertions cannot race the child
PODKOP_SUB_SYNC=1
export PODKOP_SUB_SYNC

LOGFILE=/tmp/podkop-sub.log
LOG_MAX=65536
STAMP='^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] '

reset() {
    uci -q revert podkop
    uci -q revert podkop-sub
    rm -rf /etc/podkop-sub
    rm -f "$LOGFILE"
    cp -r "$ROOT"/tests/mock/. /
    cp "$ROOT/luci-app-podkop-sub/root/usr/bin/podkop-sub" /usr/bin/podkop-sub
    chmod +x /usr/bin/podkop-sub /usr/bin/podkop /usr/bin/curl /etc/init.d/podkop
    echo '{"proxies":{"main-out":{"now":"main-1-out"},"media-out":{}}}' > "$MOCK_PROXIES"
    unset MOCK_HTTP_CODE MOCK_BODY_plain MOCK_BODY_alt MOCK_PODKOP_DOWN
    : > "$MOCK_CALLS"
}

size_of() { wc -c < "$LOGFILE" | tr -d ' '; }
unstamped() { grep -cv "$STAMP" "$LOGFILE"; }

# ---------------------------------------------------------------- the subcommand

reset
out=$(podkop-sub logs 2>&1)
rc=$?
assert_eq "0" "$rc" "logs exits 0 with no log file"
assert_eq "" "$out" "logs prints nothing with no log file"

podkop-sub update --all > /dev/null 2>&1
assert_cmd "a run creates the log" test -s "$LOGFILE"
assert_eq "$(cat "$LOGFILE")" "$(podkop-sub logs)" "logs prints the file"
assert_eq "0" "$(unstamped)" "every line carries a timestamp"

podkop-sub logs --clear
assert_eq "0" "$?" "logs --clear exits 0"
assert_eq "0" "$(size_of)" "logs --clear empties the file"
assert_eq "" "$(podkop-sub logs)" "logs prints nothing after --clear"

podkop-sub logs --bogus > /dev/null 2>&1
assert_eq "1" "$?" "an unknown logs option fails"
assert_eq "" "$(grep -F -- '--bogus' "$LOGFILE")" "and is not echoed into the log"

# ---------------------------------------------------------------- nothing confidential

# the subscription host may be logged; its path, the whole URL and any proxy link may not
secret_check() { # <label>
    assert_eq "" "$(grep -F '://' "$LOGFILE")" "$1: no scheme of any kind"
    assert_eq "" "$(grep -F '/sub/' "$LOGFILE")" "$1: no subscription URL path"
    for s in 11111111-2222-3333-4444-555555555555 secretpass altpass \
        node1.example.net node7.example.net YWVzLTI1Ni1nY206c2VjcmV0cGFzcw; do
        assert_eq "" "$(grep -F "$s" "$LOGFILE")" "$1: no $s"
    done
}

reset
podkop-sub update --all > /dev/null 2>&1
podkop-sub apply > /dev/null 2>&1
podkop-sub check > /dev/null 2>&1
podkop-sub restore > /dev/null 2>&1
secret_check "the happy path"
assert_cmd "the run itself was recorded" grep -q 'links' "$LOGFILE"
# an address in the log keeps its first and last part and hides the middle, so it stays comparable
assert_cmd "the subscription host is masked" grep -q 'panel\.x\.net' "$LOGFILE"
assert_eq "" "$(grep -F 'panel.example.net' "$LOGFILE")" "its middle never reaches the log"
# the one event worth reading the log for: podkop's config was rewritten under the user's feet
assert_cmd "an apply that restarts podkop says so, with the sections" \
    grep -q 'podkop restarted for .*main' "$LOGFILE"

# the error paths are where a URL is most likely to slip through
reset
MOCK_HTTP_CODE=502
export MOCK_HTTP_CODE
podkop-sub update --all > /dev/null 2>&1
MOCK_HTTP_CODE=200
MOCK_BODY_plain=html
MOCK_BODY_alt=empty
export MOCK_HTTP_CODE MOCK_BODY_plain MOCK_BODY_alt
podkop-sub update --all > /dev/null 2>&1
podkop-sub apply > /dev/null 2>&1
secret_check "the error paths"
assert_cmd "the failures were recorded" grep -q 'http 502' "$LOGFILE"
# the error paths used to log the host unmasked while the success paths masked it
assert_cmd "an error line masks the host too" grep -q 'panel\.x\.net' "$LOGFILE"

# the configured URLs themselves, read back out of uci
reset
podkop-sub update --all > /dev/null 2>&1
n=0
for u in $(uci -q show podkop-sub | sed -n "s/^.*\.url='\(.*\)'\$/\1/p"); do
    n=$((n + 1))
    assert_eq "" "$(grep -F "$u" "$LOGFILE")" "the configured URL $n is not in the log"
done
assert_eq "2" "$n" "both fixture URLs were checked"

# ---------------------------------------------------------------- masking addresses

# a node with no #fragment is named after its endpoint, and that endpoint is the VPN server
# shellcheck source=/dev/null # sourced at run time from the copy the test installed
mask() { PODKOP_SUB_TEST=1 . /usr/bin/podkop-sub; mask_host "$1"; }
assert_eq "92.x.x.206:443" "$(mask 92.5.7.206:443)" "an IPv4 keeps its first and last octet"
assert_eq "2001:x:1" "$(mask 2001:db8::1)" "an IPv6 keeps its first and last group"
assert_eq "panel.x.net:2096" "$(mask panel.example.net:2096)" "a name keeps its first and last label"
assert_eq "example.net" "$(mask example.net)" "two labels have no middle to hide"

# shellcheck source=/dev/null # same
name() { PODKOP_SUB_TEST=1 . /usr/bin/podkop-sub; safe_name "$1"; }
assert_eq "Tokyo 02" "$(name "Tokyo 02")" "a provider's label goes to the log untouched"
assert_eq "92.x.x.206:443" "$(name 92.5.7.206:443)" "a name that is only an address is masked"

# ---------------------------------------------------------------- the files behind the log

reset
podkop-sub update --all > /dev/null 2>&1
for d in /etc/podkop-sub /etc/podkop-sub/cache /etc/podkop-sub/backup; do
    # shellcheck disable=SC2012 # busybox on 25.12 has no stat, and these paths are fixed
    assert_eq "drwx------" "$(ls -ld "$d" | cut -d' ' -f1)" "$d holds URLs and links: root only"
done

# ---------------------------------------------------------------- the cap

reset
awk 'BEGIN { for (i = 0; i < 1500; i++)
    printf "2026-01-01 00:00:00 filler line %d %s\n", i,
        "0123456789012345678901234567890123456789" }' > "$LOGFILE"
before=$(size_of)
assert_cmd "the filler really is over the cap" test "$before" -gt "$LOG_MAX"

podkop-sub update --all > /dev/null 2>&1
assert_cmd "the log is back under the cap" test "$(size_of)" -le "$LOG_MAX"
assert_cmd "the newest line survived" grep -q 'links' "$LOGFILE"
assert_cmd "so did the newest filler lines" grep -qF 'filler line 1499 ' "$LOGFILE"
assert_eq "" "$(grep -F 'filler line 0 ' "$LOGFILE")" "the oldest lines were evicted"
assert_eq "0" "$(unstamped)" "the half line left by the byte cut is dropped"

test_summary
