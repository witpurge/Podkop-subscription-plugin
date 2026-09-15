#!/bin/sh
# shellcheck shell=dash
# L1: the pure parser functions, sourced straight out of the router script.
set -u
. tests/lib.sh

PODKOP_SUB_TEST=1
export PODKOP_SUB_TEST
# shellcheck source=luci-app-podkop-sub/root/usr/bin/podkop-sub
. luci-app-podkop-sub/root/usr/bin/podkop-sub

# --- sub_id

id=$(sub_id "https://panel.example.net/sub/token")
assert_eq "12" "${#id}" "sub_id is 12 characters"
assert_eq "$id" "$(sub_id "https://panel.example.net/sub/token")" "sub_id is stable"

# --- parse_subscription

plain=$(parse_subscription < tests/fixtures/plain.txt)
assert_eq "3" "$(printf '%s\n' "$plain" | wc -l | tr -d ' ')" "plain.txt yields 3 links"
assert_eq "" "$(printf '%s\n' "$plain" | grep vmess)" "vmess is dropped (podkop cannot build it)"

b64=$(parse_subscription < tests/fixtures/base64.txt)
assert_eq "$plain" "$b64" "base64.txt parses to the same links as plain.txt"

urlsafe=$(parse_subscription < tests/fixtures/base64-urlsafe.txt)
assert_eq "$plain" "$urlsafe" "unpadded url-safe base64 parses to the same links"

html=$(parse_subscription < tests/fixtures/html.txt)
rc=$?
assert_eq "0" "$rc" "an HTML error page does not make the parser fail"
assert_eq "" "$html" "an HTML error page yields no links"

empty=$(parse_subscription < tests/fixtures/empty.txt)
rc=$?
assert_eq "0" "$rc" "an empty body does not make the parser fail"
assert_eq "" "$empty" "an empty body yields no links"

dup=$(printf 'trojan://p@h.example.net:443#one\ntrojan://p@h.example.net:443#one\n' |
    parse_subscription)
assert_eq "trojan://p@h.example.net:443#one" "$dup" "identical links collapse into one"

# --- sanitize_link / link_name

first=$(printf '%s\n' "$plain" | sed -n 1p)
assert_contains "$first" "%20NL%2001%20Amsterdam" "spaces in #name are percent-encoded"
assert_eq "🇳🇱 NL 01 Amsterdam" "$(link_name "$first")" "link_name decodes %20 back to a space"

second=$(printf '%s\n' "$plain" | sed -n 2p)
assert_eq "ss://YWVzLTI1Ni1nY206c2VjcmV0cGFzcw==@node2.example.net:8388#node2.example.net:8388" \
    "$second" "a link without a fragment gets #host:port"
assert_eq "node2.example.net:8388" "$(link_name "$second")" "link_name of a generated fragment"

third=$(printf '%s\n' "$plain" | sed -n 3p)
assert_eq "🇩🇪 DE Frankfurt" "$(link_name "$third")" "a CRLF line is trimmed and its name decodes"

assert_eq "vless://u@h.example.net:443#a%09b" "$(sanitize_link "vless://u@h.example.net:443#a	b")" \
    "a tab in #name becomes %09"
assert_eq "vless://u@h.example.net:443?path=/x%20y#n" \
    "$(sanitize_link "vless://u@h.example.net:443?path=/x%20y#n")" \
    "nothing outside the fragment is touched"

test_summary
