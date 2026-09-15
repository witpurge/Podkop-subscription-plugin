# Test stand: real OpenWrt rootfs plus podkop's runtime dependencies.
ARG OPENWRT_IMAGE=openwrt/rootfs:x86-64-24.10.8
FROM ${OPENWRT_IMAGE}

# 24.10 has opkg and needs /var/lock created by hand, 25.12 has apk.
RUN if command -v apk > /dev/null 2>&1; then \
        apk update && apk add jq curl coreutils-base64; \
    else \
        mkdir -p /var/lock && opkg update && opkg install jq curl coreutils-base64; \
    fi
