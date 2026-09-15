#!/bin/sh
# shellcheck shell=dash
# Removes luci-app-podkop-sub. The package's prerm does the real work; --purge also drops
# the config, the cache and the sysupgrade.conf lines.

PKG_IS_APK=0
command -v apk > /dev/null 2>&1 && PKG_IS_APK=1
PURGE=0

msg() { printf '\033[32;1m%s\033[0m\n' "$1"; }

usage() {
    cat << EOF
usage: sh uninstall.sh [--purge]

  --purge   also remove /etc/config/podkop-sub, /etc/podkop-sub/ and their
            lines in /etc/sysupgrade.conf
EOF
}

pkg_remove() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk del "$1" 2> /dev/null
    else
        opkg remove --force-depends "$1" 2> /dev/null
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --purge)
            PURGE=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# opkg and apk both exit 0 when the package is not installed, so uninstalling twice is not an error
for pkg in luci-i18n-podkop-sub-ru luci-app-podkop-sub; do
    pkg_remove "$pkg"
done

if [ "$PURGE" -eq 1 ]; then
    rm -f /etc/config/podkop-sub
    rm -rf /etc/podkop-sub
    [ -f /etc/sysupgrade.conf ] && sed -i \
        -e '/^\/etc\/config\/podkop-sub$/d' \
        -e '/^\/etc\/podkop-sub\/$/d' /etc/sysupgrade.conf
    msg "Purged /etc/config/podkop-sub and /etc/podkop-sub/"
fi

rm -f /tmp/luci-indexcache*
msg "Done. Reload the LuCI page with Ctrl+Shift+R."
exit 0
