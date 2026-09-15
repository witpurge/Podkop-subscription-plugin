#!/bin/sh
# shellcheck shell=dash
# Dev stand: OpenWrt container with real podkop and a browsable LuCI. See CONTRIBUTING.md.
set -eu

ENGINE="${CONTAINER_ENGINE:-docker}"
PODKOP_VERSION="${PODKOP_VERSION:-}"
PORT="${PORT:-8080}"
NAME="podkop-sub-dev-${OPENWRT_VERSION:-24.10.8}"
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# default to the podkop the plugin is built for, so the stand never lags the target
[ -n "$PODKOP_VERSION" ] || PODKOP_VERSION=$(sed -n "s/^TARGET_PODKOP='\(.*\)'\$/\1/p" \
    "$ROOT/luci-app-podkop-sub/root/usr/share/podkop-sub/version")
action=start

usage() {
    cat << EOF
usage: sh tests/dev.sh [--port N] [--stop | --reset]

  (no flags)   start the stand, creating it if needed
  --port N     serve LuCI on port N instead of $PORT
  --stop       stop the container, keeping it for the next start
  --reset      delete the container and its image, then start clean
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --port)
            PORT="${2:?--port needs a number}"
            shift 2
            ;;
        --port=*)
            PORT="${1#*=}"
            shift
            ;;
        --stop)
            action=stop
            shift
            ;;
        --reset)
            action=reset
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

case "$PORT" in
    '' | *[!0-9]*)
        echo "port must be a number, got: $PORT" >&2
        exit 1
        ;;
esac

if [ "$action" = stop ]; then
    if "$ENGINE" stop "$NAME" > /dev/null 2>&1; then
        echo "$NAME stopped"
    else
        echo "$NAME is not running"
    fi
    exit 0
fi

. "$ROOT/tests/image.sh"
resolve_image "$ENGINE"
TAG="podkop-sub-test:$(echo "$BASE_IMAGE" | tr ':/' '--')"
DEV_IMAGE="podkop-sub-dev:$PODKOP_VERSION-$(echo "$BASE_IMAGE" | tr ':/' '--')"

if [ "$action" = reset ]; then
    "$ENGINE" rm -f "$NAME" > /dev/null 2>&1 || true
    "$ENGINE" rmi -f "$DEV_IMAGE" > /dev/null 2>&1 || true
fi

"$ENGINE" image inspect "$TAG" > /dev/null 2>&1 ||
    "$ENGINE" build --build-arg "OPENWRT_IMAGE=$BASE_IMAGE" -t "$TAG" "$ROOT/tests"

if ! "$ENGINE" image inspect "$DEV_IMAGE" > /dev/null 2>&1; then
    echo "Building $DEV_IMAGE with podkop $PODKOP_VERSION and luci (a few minutes)..."
    "$ENGINE" build -f "$ROOT/tests/Dockerfile.dev" \
        --build-arg "BASE=$TAG" --build-arg "PODKOP_VERSION=$PODKOP_VERSION" \
        -t "$DEV_IMAGE" "$ROOT/tests"
fi

# The published port is fixed when the container is created, so a new one means recreating it
published=$("$ENGINE" port "$NAME" 80 2> /dev/null | head -1 | sed 's/.*://')
if [ -n "$published" ] && [ "$published" != "$PORT" ]; then
    echo "Recreating $NAME on port $PORT (was $published)..."
    "$ENGINE" rm -f "$NAME" > /dev/null
fi

"$ENGINE" inspect "$NAME" > /dev/null 2>&1 ||
    "$ENGINE" run -d --name "$NAME" -p "$PORT:80" -v "$ROOT:/w" -w /w \
        "$DEV_IMAGE" sh -c 'while :; do sleep 3600; done' > /dev/null

"$ENGINE" start "$NAME" > /dev/null 2>&1 || true

# Restart outright: a leftover rpcd would register the ubus objects a second time
# shellcheck disable=SC2016 # the script body runs inside the container
"$ENGINE" exec "$NAME" sh -c '
    mkdir -p /var/run /var/lock /var/state /tmp/luci-sessions
    ps w | grep -E "/sbin/(ubusd|procd|rpcd)|/usr/sbin/uhttpd" | grep -v grep |
        while read -r pid rest; do kill -9 "$pid" 2>/dev/null; done
    sleep 1
    rm -f /var/lock/procd_rpcd.lock /var/run/ubus/ubus.sock
    (ubusd &)
    sleep 1
    (procd &)  # not as PID 1: only to provide the system ubus object LuCI needs
    sleep 1
    # via init.d, so uhttpd gets its real arguments - notably -u /ubus
    /etc/init.d/rpcd start
    sleep 1
    /etc/init.d/uhttpd start
    sleep 2' > /dev/null 2>&1

# uhttpd needs a moment after the restart, so poll instead of guessing a sleep
i=0
while [ "$i" -lt 10 ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/cgi-bin/luci" || echo 000)
    case "$code" in 200 | 403) break ;; esac
    i=$((i + 1))
    sleep 1
done

case "$code" in
    200 | 403) state="ok (HTTP $code, login page)" ;;
    *) state="PROBLEM: HTTP $code" ;;
esac
ubus=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -d '{"jsonrpc":"2.0","id":1,"method":"list","params":["*"]}' \
    "http://localhost:$PORT/ubus" || echo 000)

cat << EOF

LuCI:    http://localhost:$PORT/cgi-bin/luci   $state
ubus:    /ubus HTTP $ubus (must be 200, LuCI is dead without it)
login:   root, empty password
podkop:  $("$ENGINE" exec "$NAME" podkop show_version)
shell:   $ENGINE exec -it $NAME /bin/sh
project: mounted at /w
stop:    sh tests/dev.sh --stop
EOF
