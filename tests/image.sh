# shellcheck shell=dash
# Sets BASE_IMAGE: ARM images of OpenWrt only pull by digest, and qemu emulation breaks ucode/ubus.

resolve_image() {
    engine="$1"
    want="${OPENWRT_IMAGE:-}"

    if [ -z "$want" ]; then
        case "$(uname -m)" in
            arm64 | aarch64) want="openwrt/rootfs:aarch64_generic-${OPENWRT_VERSION:-24.10.8}" ;;
            *) want="openwrt/rootfs:x86-64-${OPENWRT_VERSION:-24.10.8}" ;;
        esac
    fi

    case "$want" in
        *aarch64*) ;;
        *)
            # x86 images resolve by tag; emulate only when the host is not x86
            case "$(uname -m)" in
                arm64 | aarch64) DOCKER_DEFAULT_PLATFORM=linux/amd64 && export DOCKER_DEFAULT_PLATFORM ;;
            esac
            BASE_IMAGE="$want"
            return
            ;;
    esac

    unset DOCKER_DEFAULT_PLATFORM
    BASE_IMAGE="openwrt-rootfs-native:$(echo "$want" | sed 's|.*:||')"
    "$engine" image inspect "$BASE_IMAGE" > /dev/null 2>&1 && return

    echo "Resolving $want by digest (arm images cannot be pulled by tag)..."
    digest=$("$engine" manifest inspect "$want" |
        awk '/"digest"/ { d = $2 } /"architecture": *"aarch64/ { gsub(/[",]/, "", d); print d; exit }')
    [ -n "$digest" ] || {
        echo "cannot resolve an aarch64 manifest in $want" >&2
        exit 1
    }
    "$engine" pull -q "openwrt/rootfs@$digest" > /dev/null
    "$engine" tag "openwrt/rootfs@$digest" "$BASE_IMAGE"
}
