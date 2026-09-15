#!/bin/sh
# shellcheck shell=dash
# L2: install.sh picks a release by its asset names. The tag is a plain version and says nothing
# about podkop, which is exactly the bug this covers.
set -u
. tests/lib.sh

ROOT=$PWD
DL="https://github.com/witpurge/Podkop-subscription-plugin/releases/download"
MOCK_WGET_DIR=/tmp/mock-wget
MOCK_CALLS=/tmp/mock-calls-install
MOCK_PODKOP_VERSION=0.7.22
MOCK_PROXIES=''
MOCK_DEAD=''
export MOCK_WGET_DIR MOCK_CALLS MOCK_PODKOP_VERSION MOCK_PROXIES MOCK_DEAD

if command -v apk > /dev/null 2>&1; then
    EXT=apk
else
    EXT=ipk
fi

cp -r "$ROOT"/tests/mock/. /
chmod +x /usr/bin/podkop /usr/bin/wget
rm -rf "$MOCK_WGET_DIR"
mkdir -p "$MOCK_WGET_DIR"

app_asset() { # <plugin version> <podkop it was built for, empty for an unstamped build>
    if [ "$EXT" = apk ]; then
        echo "luci-app-podkop-sub-$1-r1${2:+-podkop$2}.apk"
    else
        echo "luci-app-podkop-sub_$1-r1${2:+_podkop$2}_all.ipk"
    fi
}

# one release object, tag_name before its own assets, the way the GitHub API emits it
rel() { # <tag> <podkop its packages are stamped with, empty for an unstamped release>
    printf '{"tag_name":"%s","assets":[{"browser_download_url":"%s/%s/install.sh"}' "$1" "$DL" "$1"
    printf ',{"browser_download_url":"%s/%s/luci-app-podkop-sub-%s-r1%s.apk"}' \
        "$DL" "$1" "$1" "${2:+-podkop$2}"
    printf ',{"browser_download_url":"%s/%s/luci-app-podkop-sub_%s-r1%s_all.ipk"}]}' \
        "$DL" "$1" "$1" "${2:+_podkop$2}"
}

# <tag> <podkop> pairs: the first is the newest release
releases() {
    body=''
    one=''
    while [ $# -gt 0 ]; do
        body="$body$one$(rel "$1" "$2")"
        one=','
        shift 2
    done
    printf '[%s]\n' "$body" > "$MOCK_WGET_DIR/releases"
}

serve_tag() { # <tag> <podkop>: the per-tag response install.sh fetches once it has chosen
    rel "$1" "$2" > "$MOCK_WGET_DIR/release-$1"
    # the asset is empty on purpose: the download fails and opkg/apk is never reached
    : > "$MOCK_WGET_DIR/$(app_asset "$1" "$2")"
}

run() { # <answer fed to the prompt> [install.sh args...]; the package itself never installs here
    answer="$1"
    shift
    : > "$MOCK_CALLS"
    printf '%s\n' "$answer" | sh install.sh "$@" 2>&1
}

# ---------------------------------------------------------------- the newest is not the match

releases 0.9.0 0.9.9 0.0.2 0.7.22
serve_tag 0.0.2 0.7.22
out=$(run '')

assert_contains "$out" "Installing release 0.0.2" \
    "the release whose packages carry this podkop wins over the newer one"
assert_eq "" "$(printf '%s' "$out" | grep -F 'No plugin release built')" \
    "a match is installed without a warning"
assert_contains "$(cat "$MOCK_CALLS")" "per_page=10" "the release list is bounded"
assert_contains "$(cat "$MOCK_CALLS")" "/releases/tags/0.0.2" "the chosen release is fetched by tag"
assert_eq "" "$(grep -F '/releases/tags/0.9.0' "$MOCK_CALLS")" "the newer release is not fetched"
assert_contains "$(cat "$MOCK_CALLS")" "$(app_asset 0.0.2 0.7.22)" \
    "and its .$EXT package is the one downloaded"

# ---------------------------------------------------------------- nothing matches: the fallback

releases 0.9.0 0.9.9 0.0.1 0.6.0
out=$(run no)

assert_contains "$out" "0.9.0 is built for podkop 0.9.9, you have podkop 0.7.22" \
    "the fallback reads the podkop version out of the newest release's package name"
assert_contains "$out" "Exit" "answering anything but yes aborts"

serve_tag 0.9.0 0.9.9
out=$(run yes)
assert_contains "$out" "Installing release 0.9.0" "answering yes installs the newest release anyway"

# ---------------------------------------------------------------- the owner's release

releases 0.0.2 ''
out=$(run no)

assert_eq "" "$(printf '%s' "$out" | grep -F 'built for podkop 0.0.2')" \
    "a plain version tag is never reported as a podkop version"
assert_contains "$out" "0.0.2 does not say which podkop it was built for, you have podkop 0.7.22" \
    "an unstamped release says so instead of inventing a version"

# ---------------------------------------------------------------- a version that is a prefix

MOCK_PODKOP_VERSION=0.7.2
releases 0.0.2 0.7.22
out=$(run no)
assert_contains "$out" "0.0.2 is built for podkop 0.7.22, you have podkop 0.7.2" \
    "podkop 0.7.2 does not match packages built for 0.7.22"
MOCK_PODKOP_VERSION=0.7.22

# ---------------------------------------------------------------- -t, and GitHub misbehaving

releases 0.9.0 0.9.9 0.0.2 0.7.22
serve_tag 0.0.1 0.7.22
out=$(run '' -t 0.0.1)
assert_contains "$out" "Installing release 0.0.1" "-t installs that tag without asking"

echo '{"message":"API rate limit exceeded for 1.2.3.4."}' > "$MOCK_WGET_DIR/releases"
out=$(run '')
assert_contains "$out" "GitHub rate limit" "the rate limit is still recognised"

rm -f "$MOCK_WGET_DIR/releases"
out=$(run '')
assert_contains "$out" "Cannot reach GitHub" "an unreachable API is not a silent failure"

rm -rf "$MOCK_WGET_DIR" /tmp/podkop-sub-install
test_summary
