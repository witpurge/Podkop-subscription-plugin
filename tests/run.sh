#!/bin/sh
# shellcheck shell=dash
# Runs the test suite inside an OpenWrt rootfs container. Usage: CONTRIBUTING.md.
set -eu

ENGINE="${CONTAINER_ENGINE:-docker}"
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/tests/image.sh"
resolve_image "$ENGINE"

# One image per base tag, so 24.10 and 25.12 runs don't overwrite each other
TAG="podkop-sub-test:$(echo "$BASE_IMAGE" | tr ':/' '--')"

command -v "$ENGINE" > /dev/null 2>&1 || {
    echo "$ENGINE not found. See CONTRIBUTING.md for setup." >&2
    exit 1
}

rebuild=0
if [ "${1:-}" = "--rebuild" ]; then
    rebuild=1
    shift
fi

if [ "$rebuild" -eq 1 ] || ! "$ENGINE" image inspect "$TAG" > /dev/null 2>&1; then
    echo "Building $TAG from $BASE_IMAGE..."
    "$ENGINE" build --build-arg "OPENWRT_IMAGE=$BASE_IMAGE" -t "$TAG" "$ROOT/tests"
fi

if [ "${1:-}" = "--shell" ]; then
    exec "$ENGINE" run --rm -it -v "$ROOT:/w" -w /w "$TAG" /bin/sh
fi

echo "stand: $BASE_IMAGE"
exec "$ENGINE" run --rm -v "$ROOT:/w" -w /w "$TAG" sh tests/in-container.sh "$@"
