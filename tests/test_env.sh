#!/bin/sh
# shellcheck shell=dash
# Checks the stand: a failure here means a bad Dockerfile or an assumption we may not make.
set -u
. tests/lib.sh

# Shell and OpenWrt runtime
assert_cmd "busybox ash is the shell" test -x /bin/busybox
assert_cmd "/lib/functions.sh exists" test -r /lib/functions.sh
assert_cmd "uci present" command -v uci
assert_cmd "logger present" command -v logger

# config_load/config_get must really work here - podkop-sub is built on them
cat > /tmp/env-probe << 'EOF'
config probe 'probe'
	option value 'works'
EOF
mkdir -p /etc/config
cp /tmp/env-probe /etc/config/env_probe
# shellcheck disable=SC1091,SC2154 # config_get assigns $v at runtime
probe=$(
    set +u # /lib/functions.sh is not set -u safe: IPKG_INSTROOT, CONFIG_LIST_STATE, ...
    . /lib/functions.sh
    config_load env_probe
    config_get v probe value
    echo "$v"
)
assert_eq "works" "$probe" "config_load/config_get work"
rm -f /etc/config/env_probe /tmp/env-probe

# podkop's dependencies, therefore ours
for tool in jq curl base64 md5sum sha256sum flock awk sed grep date; do
    assert_cmd "$tool present" command -v "$tool"
done

# The exact invocations podkop-sub will use
assert_eq "aGk=" "$(printf 'hi' | base64)" "base64 encodes"
assert_eq "hi" "$(printf 'aGk=' | base64 -d)" "base64 -d decodes"
assert_eq "ok" "$(printf '{"a":"ok"}' | jq -r .a)" "jq reads json"
assert_eq "9dd4e461268c8034f5c8564e155c67a6" "$(printf 'x' | md5sum | cut -d' ' -f1)" \
    "md5sum of stdin matches known value"

# busybox ash has no namespaces: the same name in two modules wins silently, with no diagnostic
dups=$(grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' \
    luci-app-podkop-sub/root/usr/share/podkop-sub/lib/*.sh \
    luci-app-podkop-sub/root/usr/bin/podkop-sub | sort | uniq -d)
assert_eq "" "$dups" "no function name is defined in two modules"

test_summary
