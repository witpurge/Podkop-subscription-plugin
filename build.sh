#!/bin/sh
# shellcheck shell=dash
# Builds the package with the official OpenWrt SDK in a container. Usage: sh build.sh ipk|apk
set -eu

ENGINE="${CONTAINER_ENGINE:-docker}"
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FMT="${1:-}"

case "$FMT" in
    ipk | apk) ;;
    *)
        echo "usage: sh build.sh ipk|apk" >&2
        exit 1
        ;;
esac

command -v "$ENGINE" > /dev/null 2>&1 || {
    echo "$ENGINE not found. See CONTRIBUTING.md for setup." >&2
    exit 1
}

TAG="podkop-sub-build:$FMT"

# OpenWrt SDK images are x86_64-only, so on an arm host this needs working amd64 emulation
case "$(uname -m)" in
    arm64 | aarch64)
        echo "Note: the SDK is x86_64. On Apple Silicon, colima needs rosetta" >&2
        echo "      (colima start --vm-type vz --vz-rosetta), qemu segfaults gcc at random." >&2
        ;;
esac

echo "Building $FMT (the SDK image is ~2.5 GB on the first run)..."
"$ENGINE" build -f "$ROOT/Dockerfile-$FMT" \
    --build-arg "PODKOP_SUB_VERSION=${PODKOP_SUB_VERSION:-}" \
    -t "$TAG" "$ROOT"

# The SDK image runs as an unprivileged user, so copy the artifacts out instead of bind-mounting
mkdir -p "$ROOT/dist"
cid=$("$ENGINE" create "$TAG" true)
"$ENGINE" cp "$cid:/tmp/out/." "$ROOT/dist/"
"$ENGINE" rm -f "$cid" > /dev/null

ls -l "$ROOT/dist"
