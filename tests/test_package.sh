#!/bin/sh
# shellcheck shell=dash
# L2: the built package installs next to a real podkop, touches nothing of its, and leaves
# no trace when removed. Needs dist/ from build.sh and network for podkop's release packages.
set -u
. tests/lib.sh

PODKOP_VERSION=$(target_podkop)
PODKOP_WWW=/www/luci-static/resources/view/podkop
DL=/tmp/podkop-release

if command -v apk > /dev/null 2>&1; then
    EXT=apk
    PODKOP_PKGS="podkop-$PODKOP_VERSION-r1.apk luci-app-podkop-$PODKOP_VERSION-r1.apk"
else
    EXT=ipk
    PODKOP_PKGS="podkop-v$PODKOP_VERSION-r1-all.ipk luci-app-podkop-v$PODKOP_VERSION-r1-all.ipk"
fi

PKG=""
for f in dist/luci-app-podkop-sub*."$EXT"; do
    [ -f "$f" ] && PKG="$f"
done
[ -n "$PKG" ] || {
    echo "skip: no dist/luci-app-podkop-sub*.$EXT (build it with: sh build.sh $EXT)"
    exit 0
}

# the stage-1 tests leave mocks and loose copies behind; this one starts from an unowned-file-free /
rm -f /usr/bin/podkop /etc/init.d/podkop /etc/config/podkop
rm -f /usr/bin/podkop-sub /etc/init.d/podkop-sub /etc/config/podkop-sub
rm -rf /usr/share/podkop-sub/lib
rm -rf /etc/podkop-sub
mkdir -p /var/lock "$DL"

# podkop's packages are cached in the mounted project: one download instead of one per run,
# and a truncated file no longer turns into a mystery failure later
CACHE=tests/.cache
mkdir -p "$CACHE"
for f in $PODKOP_PKGS; do
    if [ ! -s "$CACHE/$f" ]; then
        wget -q -O "$CACHE/$f.part" \
            "https://github.com/itdoginfo/podkop/releases/download/$PODKOP_VERSION/$f"
        if [ -s "$CACHE/$f.part" ]; then
            mv "$CACHE/$f.part" "$CACHE/$f"
        else
            rm -f "$CACHE/$f.part"
            rm -rf "$DL"
            echo "skip: no network (cannot fetch $f)"
            exit 0
        fi
    fi
    cp "$CACHE/$f" "$DL/$f"
done

# a stale index fails sing-box on its checksum and takes luci-app-podkop's install with it
if [ "$EXT" = apk ]; then
    apk update > /dev/null 2>&1
    apk add --allow-untrusted "$DL"/* > /tmp/podkop-install.log 2>&1
else
    opkg update > /dev/null 2>&1
    opkg install --force-depends "$DL"/* > /tmp/podkop-install.log 2>&1
fi
[ -x /usr/bin/podkop ] || {
    tail -5 /tmp/podkop-install.log
    echo "skip: podkop $PODKOP_VERSION could not be installed (see above)"
    exit 0
}

podkop_md5() { md5sum "$PODKOP_WWW"/* 2> /dev/null | sort; }

BEFORE=$(podkop_md5)
[ -n "$BEFORE" ] || {
    tail -5 /tmp/podkop-install.log
    echo "skip: luci-app-podkop installed no pages to compare against (see above)"
    exit 0
}
assert_cmd "podkop's own pages are there to compare against" test -n "$BEFORE"

sysupgrade_count() { grep -c "^$1\$" /etc/sysupgrade.conf 2> /dev/null; }

# ---------------------------------------------------------------- install

sh install.sh --file "$PKG" > /tmp/install.log 2>&1
assert_eq "0" "$?" "install.sh --file installs the package"

assert_cmd "the page is installed" test -f /www/luci-static/resources/view/podkop-sub/subscriptions.js
assert_cmd "the menu entry is installed" test -f /usr/share/luci/menu.d/luci-app-podkop-sub.json
assert_cmd "the ACL is installed" test -f /usr/share/rpcd/acl.d/luci-app-podkop-sub.json
assert_cmd "the script is installed and executable" test -x /usr/bin/podkop-sub
modules=$(find luci-app-podkop-sub/root/usr/share/podkop-sub/lib -name '*.sh' | wc -l | tr -d ' ')
assert_eq "$modules" \
    "$(find /usr/share/podkop-sub/lib -name '*.sh' 2> /dev/null | wc -l | tr -d ' ')" \
    "every module the repo ships is installed with the entry point"
assert_cmd "the init script is installed and executable" test -x /etc/init.d/podkop-sub
assert_cmd "the default config is installed" test -f /etc/config/podkop-sub
version=$(cat /usr/share/podkop-sub/version 2> /dev/null)
assert_contains "$version" "PLUGIN_VERSION=" "the version file is installed"
assert_eq "" "$(printf '%s' "$version" | grep -F __COMPILED_VERSION_VARIABLE__)" \
    "the version placeholder was substituted at build time"

assert_cmd "cache directory created by uci-defaults" test -d /etc/podkop-sub/cache
assert_cmd "backup directory created by uci-defaults" test -d /etc/podkop-sub/backup
assert_eq "1" "$(sysupgrade_count /etc/config/podkop-sub)" "config is listed in sysupgrade.conf"
assert_eq "1" "$(sysupgrade_count /etc/podkop-sub/)" "state directory is listed in sysupgrade.conf"

assert_eq "$BEFORE" "$(podkop_md5)" "podkop's files are unchanged after our install"

# ---------------------------------------------------------------- reinstall over itself

echo "# edited by the test" >> /etc/config/podkop-sub
sh install.sh --file "$PKG" > /tmp/install2.log 2>&1
assert_eq "0" "$?" "installing over an existing install works"
assert_contains "$(cat /etc/config/podkop-sub)" "# edited by the test" \
    "conffiles: the edited config is not overwritten"
assert_eq "1" "$(sysupgrade_count /etc/config/podkop-sub)" "sysupgrade.conf line is not duplicated"
assert_eq "1" "$(sysupgrade_count /etc/podkop-sub/)" "second sysupgrade.conf line is not duplicated"
assert_eq "$BEFORE" "$(podkop_md5)" "podkop's files are unchanged after a reinstall"

# ---------------------------------------------------------------- remove

sh uninstall.sh > /tmp/uninstall.log 2>&1
assert_eq "0" "$?" "uninstall.sh removes the package"

assert_cmd "the page is gone" test ! -e /www/luci-static/resources/view/podkop-sub/subscriptions.js
assert_cmd "the menu entry is gone" test ! -e /usr/share/luci/menu.d/luci-app-podkop-sub.json
assert_cmd "the ACL is gone" test ! -e /usr/share/rpcd/acl.d/luci-app-podkop-sub.json
assert_cmd "the script is gone" test ! -e /usr/bin/podkop-sub
assert_cmd "the modules go with it, directory and all" test ! -e /usr/share/podkop-sub/lib
assert_cmd "the init script is gone" test ! -e /etc/init.d/podkop-sub
assert_cmd "the empty view directory is gone too" test ! -e /www/luci-static/resources/view/podkop-sub
assert_cmd "the config survives a plain removal" test -f /etc/config/podkop-sub
assert_eq "$BEFORE" "$(podkop_md5)" "podkop's files are unchanged after our removal"

# ---------------------------------------------------------------- purge

sh install.sh --file "$PKG" > /tmp/install3.log 2>&1
sh uninstall.sh --purge > /tmp/purge.log 2>&1
assert_eq "0" "$?" "uninstall.sh --purge removes the package"

assert_cmd "the config is purged" test ! -e /etc/config/podkop-sub
assert_cmd "the state directory is purged" test ! -e /etc/podkop-sub
assert_eq "0" "$(sysupgrade_count /etc/config/podkop-sub)" "config line removed from sysupgrade.conf"
assert_eq "0" "$(sysupgrade_count /etc/podkop-sub/)" "state line removed from sysupgrade.conf"
assert_eq "$BEFORE" "$(podkop_md5)" "podkop's files are unchanged after a purge"

sh uninstall.sh --purge > /tmp/purge2.log 2>&1
assert_eq "0" "$?" "a second uninstall in a row is not an error"

test_summary
