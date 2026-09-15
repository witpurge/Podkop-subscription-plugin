#!/bin/sh
# shellcheck shell=dash
# Installs luci-app-podkop-sub from a GitHub release, or from a local package with --file.

REPO="witpurge/Podkop-subscription-plugin"
API="https://api.github.com/repos/$REPO/releases"
DOWNLOAD_DIR="/tmp/podkop-sub-install"
COUNT=3
MAX_RELEASES=10 # how far back install.sh looks; the API is unauthenticated and rate-limited

PKG_IS_APK=0
command -v apk > /dev/null 2>&1 && PKG_IS_APK=1
EXT=ipk
[ "$PKG_IS_APK" -eq 1 ] && EXT=apk

TAG=""
LOCAL_FILE=""

msg() { printf '\033[32;1m%s\033[0m\n' "$1"; }
err() { printf '\033[31;1m%s\033[0m\n' "$1" >&2; }

usage() {
    cat << EOF
usage: sh install.sh [-t <tag>] [--file <package>]

  -t <tag>          install this release instead of the one built for your podkop
  --file <package>  install a local .$EXT file, without contacting GitHub
EOF
}

pkg_is_installed() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk list --installed 2> /dev/null | grep -q "$1"
    else
        opkg list-installed 2> /dev/null | grep -q "$1"
    fi
}

pkg_install() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --allow-untrusted "$1"
    else
        opkg install "$1"
    fi
}

# download <url> <path>: podkop's retry loop, a truncated file counts as a failure
download() {
    attempt=0
    while [ "$attempt" -lt "$COUNT" ]; do
        attempt=$((attempt + 1))
        msg "Download $(basename "$2") (attempt $attempt)..."
        if wget -q -O "$2" "$1" && [ -s "$2" ]; then
            return 0
        fi
        rm -f "$2"
    done
    err "Failed to download $(basename "$2") after $COUNT attempts"
    return 1
}

version_warning() { # <release tag> <podkop its packages were built for, may be empty> <podkop here>
    printf '\033[48;5;196m\033[1m╔══════════════════════════════════════════════════════════════════════╗\033[0m\n'
    printf '\033[48;5;196m\033[1m║ ! Нет сборки плагина под вашу версию podkop.                         ║\033[0m\n'
    printf '\033[48;5;196m\033[1m║ Ставим последний релиз: возможны нестабильности.                     ║\033[0m\n'
    printf '\033[48;5;196m\033[1m║ ! No plugin release built for your podkop version.                   ║\033[0m\n'
    printf '\033[48;5;196m\033[1m║ Installing the latest one: instabilities are possible.               ║\033[0m\n'
    printf '\033[48;5;196m\033[1m╚══════════════════════════════════════════════════════════════════════╝\033[0m\n'
    if [ -n "$2" ]; then
        err "$1 is built for podkop $2, you have podkop $3"
    else
        err "$1 does not say which podkop it was built for, you have podkop $3"
    fi
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -t | --tag)
                TAG="${2:?-t needs a tag}"
                shift 2
                ;;
            --file)
                LOCAL_FILE="${2:?--file needs a path}"
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                err "unknown option: $1"
                usage >&2
                exit 1
                ;;
        esac
    done

    if ! command -v podkop > /dev/null 2>&1; then
        err "podkop is not installed. Install podkop first: https://podkop.net"
        exit 1
    fi
    PODKOP_VER=$(podkop show_version 2> /dev/null | head -n 1 | tr -d '\r' | sed 's/^v//')
    msg "podkop $PODKOP_VER"

    if [ -n "$LOCAL_FILE" ]; then
        [ -s "$LOCAL_FILE" ] || {
            err "no such package: $LOCAL_FILE"
            exit 1
        }
        pkg_install "$LOCAL_FILE" || exit 1
        done_message
        return
    fi

    rm -rf "$DOWNLOAD_DIR"
    mkdir -p "$DOWNLOAD_DIR"

    releases=$(wget -qO- "$API?per_page=$MAX_RELEASES" 2> /dev/null)
    case "$releases" in
        *'API rate limit'*)
            err "You've reached the GitHub rate limit. Repeat in five minutes."
            exit 1
            ;;
        '')
            err "Cannot reach GitHub. Check the router's connectivity, or use --file."
            exit 1
            ;;
    esac
    # one ordered stream of the page: GitHub emits a release's tag_name before its own assets
    stream=$(printf '%s\n' "$releases" |
        grep -Eo '"(tag_name|browser_download_url)": *"[^"]*"' |
        sed -e 's/"tag_name": *"/T /' -e 's/"browser_download_url": *"/U /' -e 's/"$//')

    if [ -z "$TAG" ]; then
        newest=""
        newest_podkop=""
        tag=""
        # releases come back newest first, so the first release with a matching asset is the newest
        while read -r kind value; do
            if [ "$kind" = T ]; then
                tag=$value
                [ -n "$newest" ] || newest=$tag
                continue
            fi
            name=${value##*/}
            case "$name" in
                *".$EXT") ;;
                *) continue ;;
            esac
            # only the package name says which podkop it was built for; the tag is a plain version
            if [ "$tag" = "$newest" ] && [ -z "$newest_podkop" ]; then
                newest_podkop=$(printf '%s' "$name" |
                    grep -o 'podkop[0-9][0-9.]*' | sed 's/^podkop//; s/\.$//')
            fi
            case "$name" in
                *"podkop$PODKOP_VER"[._]*)
                    TAG=$tag
                    break
                    ;;
            esac
        done << EOF
$stream
EOF
        if [ -z "$TAG" ]; then
            TAG=$newest
            [ -n "$TAG" ] || {
                err "No releases found in $REPO"
                exit 1
            }
            version_warning "$TAG" "$newest_podkop" "$PODKOP_VER"
            msg "Continue? (yes/no)"
            read -r answer
            case "$answer" in
                yes | y | Y) ;;
                *)
                    msg "Exit"
                    exit 1
                    ;;
            esac
        fi
    fi
    msg "Installing release $TAG"

    urls=$(wget -qO- "$API/tags/$TAG" 2> /dev/null |
        grep -o "https://[^\"[:space:]]*\.$EXT")
    [ -n "$urls" ] || {
        err "Release $TAG has no .$EXT assets"
        exit 1
    }

    for url in $urls; do
        download "$url" "$DOWNLOAD_DIR/$(basename "$url")" || exit 1
    done

    app=""
    ru=""
    for f in "$DOWNLOAD_DIR"/luci-app-podkop-sub*; do
        [ -f "$f" ] && app="$f"
    done
    for f in "$DOWNLOAD_DIR"/luci-i18n-podkop-sub-ru*; do
        [ -f "$f" ] && ru="$f"
    done

    [ -n "$app" ] || {
        err "Release $TAG has no luci-app-podkop-sub package"
        exit 1
    }
    pkg_install "$app" || exit 1

    if [ -n "$ru" ]; then
        if pkg_is_installed luci-i18n-podkop-sub-ru; then
            pkg_install "$ru"
        else
            msg "Русский язык интерфейса ставим? y/n (Install the Russian interface language?)"
            while :; do
                read -r answer
                case "$answer" in
                    y | Y)
                        pkg_install "$ru"
                        break
                        ;;
                    n | N) break ;;
                    *) echo "Введите y или n" ;;
                esac
            done
        fi
    fi

    rm -rf "$DOWNLOAD_DIR"
    done_message
}

done_message() {
    msg "Done. LuCI: Services -> Podkop Subscriptions"
    msg "Reload the LuCI page with Ctrl+Shift+R, the old page is cached by the browser."
}

main "$@"
