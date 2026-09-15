#!/bin/sh
# shellcheck shell=dash
# L1: the LuCI part - our JS parses, requires nothing of podkop's, menu and ACL are valid JSON.
set -u
. tests/lib.sh

APP=luci-app-podkop-sub
VIEW=$APP/htdocs/luci-static/resources/view/podkop-sub
MENU=$APP/root/usr/share/luci/menu.d/luci-app-podkop-sub.json
ACL=$APP/root/usr/share/rpcd/acl.d/luci-app-podkop-sub.json
ENTRY=admin/services/podkop-sub

# LuCI wraps a view file in a function, so a bare file with a top-level return only parses wrapped
if command -v node > /dev/null 2>&1; then
    for js in "$VIEW"/*.js; do
        {
            echo 'function __luci_view() {'
            cat "$js"
            echo '}'
        } > /tmp/view-check.js
        assert_cmd "$(basename "$js") parses" node --check /tmp/view-check.js
    done
    rm -f /tmp/view-check.js
else
    echo "skip node --check (no node in the stand)"
fi

# the rule of this package: not a single module of podkop's
assert_eq "" "$(grep -rn 'view\.podkop\.' "$APP/htdocs" 2> /dev/null)" \
    "no podkop JS module is required"

assert_cmd "menu.d is valid json" jq -e . "$MENU"
assert_cmd "acl.d is valid json" jq -e . "$ACL"

assert_eq "$ENTRY" "$(jq -r 'keys[]' "$MENU")" "the menu adds exactly our own entry"
assert_eq "43" "$(jq -r ".\"$ENTRY\".order" "$MENU")" "order 43 puts us right after podkop's 42"
assert_eq "true" "$(jq -r ".\"$ENTRY\".depends.uci.podkop" "$MENU")" \
    "the entry is hidden when podkop is not installed"
assert_eq "luci-app-podkop-sub" "$(jq -r ".\"$ENTRY\".depends.acl[]" "$MENU")" \
    "the entry depends on our own ACL group"

path=$(jq -r ".\"$ENTRY\".action.path" "$MENU")
assert_cmd "action.path points at a view we ship" \
    test -f "$APP/htdocs/luci-static/resources/view/$path.js"

assert_eq "luci-app-podkop-sub" "$(jq -r 'keys[]' "$ACL")" "the ACL group is named after the package"
assert_eq "exec" "$(jq -r '.[].read.file["/usr/bin/podkop-sub"][]' "$ACL")" \
    "the page may exec our own script"
assert_eq "exec" "$(jq -r '.[].read.file["/etc/init.d/podkop-sub"][]' "$ACL")" \
    "the page may exec the init script, for the service buttons"
assert_eq "2" "$(jq -r '.[].read.file | length' "$ACL")" "and nothing else is granted exec"
assert_eq "podkop podkop-sub" "$(jq -r '.[].read.uci | sort | join(" ")' "$ACL")" \
    "read access to both configs, for the section list"
assert_eq "podkop-sub" "$(jq -r '.[].write.uci | join(" ")' "$ACL")" \
    "write access to our config only - podkop's is edited by our script, as root"

# ---------------------------------------------------------------- the page itself

PAGE=$VIEW/subscriptions.js

has() { # <label> <fixed string>
    assert_cmd "$1" grep -qF "$2" "$PAGE"
}

hasnt() { # <label> <fixed string>
    assert_eq "" "$(grep -F "$2" "$PAGE")" "$1"
}

assert_eq "2" "$(grep -c 'map.section(' "$PAGE")" "exactly two sections, so exactly two tabs"
has "the map is tabbed" "map.tabbed = true"
has "tab 1 is Subscriptions" '"subscriptions",'
has "tab 2 is Settings" '"settings",'
has "the mode block is embedded, not a third tab" "form.SectionValue"
has "subscriptions are an add/removable TypedSection" "subscriptions.addremove = true"

for opt in name url enabled sections user_agent nodes; do
    has "a subscription has $opt" "\"$opt\""
done
for opt in check_interval ping_timeout max_failures; do
    has "settings keep $opt" "\"$opt\""
done

has "the mode offers an empty first choice" 'mode.value("", '
has "the mode carries a validator" "mode.validate"
has "the mode refuses to be left empty" "mode.rmempty = false"
has "Update now downloads and applies" '[["update", "--all"], ["apply"]]'
has "Save & Apply is what applies to podkop" 'runCommands(this.map, [["apply"]]'
# uci.apply() rejects when nothing is staged, which used to break the chain before the core ran
has "an unedited Save & Apply still reaches the core" "uci.changes()"
hasnt "no separate apply button" '"_apply"'
has "Save & Apply runs the core afterwards" "handleSaveApply"
has "the version notice compares against target_podkop" "target_podkop"
has "traffic is hidden when the core reports nothing left" "sub.traffic_left > 0"

# the URL is long: a textarea makes it readable without letting several be pasted
has "the URL field is multi-line" 'form.TextValue, "url"'
has "with soft wrapping, like podkop's proxy_string" 'url.wrap = "soft"'
has "and it is trimmed on the way into uci" "String(value).trim()"
has "the validator still takes exactly one http(s) URL" 'https?:\/\/\S+\s*$/'
# the owner confirmed the existing name field is the free-form one; a second would be a bug
assert_eq "1" "$(grep -c '"name"' "$PAGE")" "there is exactly one name field"

# ---------------------------------------------------------------- the node picker

has "there is a per-subscription Refresh button" 'reload.inputtitle = _("Refresh")'
has "it only updates that one subscription" 'runCommands(map, [["update", sub.id]]'
has "and takes the id from status, never recomputing it" "coreStatus.subs.filter"
assert_eq "2" "$(grep -c "form.MultiValue" "$PAGE")" \
    "the nodes picker is a multi-select like the sections one, not 62 checkboxes"
has "scrolled rather than unrolled in full" "display_items: this.display_size"
has "with a bounded dropdown" "nodes.dropdown_size"
has "with its own choices per subscription" "nodes.renderWidget"
has "an empty cache points at Refresh instead of an empty box" "press Refresh"
has "selecting nothing means every node" "All nodes (%d)"
has "the counter multiplies nodes by sections" "= %d outbounds in podkop"
has "and follows the pickers live" "nodes.onchange = recount"
has "a cache the core has not filled yet never wipes the choice" "nodes.remove"
has "and a vanished name is carried over instead of being saved away" "nodes.write"

# ---------------------------------------------------------------- the vanished-node warning

has "vanished nodes raise a warning" "no longer offers these nodes"
has "which names them" "missing.join"
has "closing it acknowledges them in the core" 'execCore(["ack", sub.id])'
has "the warning is rebuilt whenever status is re-read" "warnAboutMissingNodes()"

# ---------------------------------------------------------------- the section health banner

has "an unhealthy section raises a warning of its own" "function warnAboutSectionHealth"
has "one banner per section, so a re-read replaces its own" "healthBanners[section.name] = banner"
has "a failover names his node and the one traffic goes through" "another node of your selection"
has "a borrowed node is named, and its removal promised" "borrowed from the subscription"
has "a section with nothing alive says the plugin keeps trying" "The plugin keeps probing it."
has "a healthy section produces no line at all" "if (!text)"
has "closing it acknowledges that state in the core" 'execCore(["ack-section", section.name])'
has "the banner is rebuilt whenever status is re-read" "warnAboutSectionHealth()"
# the core reports health ok while the state is acknowledged, the way it already blanks missing[]
has "the page trusts the core's health field, deriving nothing" 'section.health === "failover"'

# ---------------------------------------------------------------- the log viewer

has "there is a Show log button" 'logs.inputtitle = _("Show log")'
has "it reads the log through the core" 'execCore(["logs"])'
has "in a stock LuCI modal" "ui.showModal"
has "the text is a scrollable block" "overflow:auto"
has "with a Clear log button inside" 'execCore(["logs", "--clear"])'
has "and a close button" "ui.hideModal"
has "an empty log is a sentence, not an error" 'The log is empty.'

# ---------------------------------------------------------------- the service on the Settings tab

has "the settings tab shows the service state" 'service.running ? _("Running")'
has "and whether it starts on boot" "service.enabled"
has "the buttons call the init script" 'const INIT = "/etc/init.d/podkop-sub"'
for action in start stop restart; do
    has "there is a $action button" "serviceButton(map, \"$action\""
done
has "a stopped service is explained rather than implied to be broken" \
    "Update now and Save & Apply keep working"

# ---------------------------------------------------------------- the service itself

INITD=$APP/root/etc/init.d/podkop-sub
DEFAULTS=$APP/root/etc/uci-defaults/50_podkop-sub

assert_cmd "the init script is shipped executable" test -x "$INITD"
init=$(cat "$INITD")
assert_contains "$init" "USE_PROCD=1" "it is a procd service"
assert_contains "$init" "START=96" "it starts at 96"
assert_contains "$init" "podkop-sub daemon" "it runs the daemon, not check"
assert_contains "$init" "term_timeout 30" "procd gives an apply in flight time to finish"
assert_contains "$init" "procd_add_config_trigger" "saving the page restarts it with the new interval"

assert_contains "$(cat "$DEFAULTS")" "/etc/init.d/podkop-sub enable" "installing enables the service"
assert_contains "$(cat "$DEFAULTS")" "/etc/init.d/podkop-sub start" "installing starts the service"
# the file name is the only place the target podkop is visible once a package is downloaded
# shellcheck disable=SC2016 # the shell expansion is matched literally in the Dockerfile
assert_contains "$(cat Dockerfile-ipk)" '_podkop${TARGET_PODKOP}_all.ipk' \
    "the ipk artifact is named after the podkop it targets"
# shellcheck disable=SC2016 # same
assert_contains "$(cat Dockerfile-apk)" '-podkop${TARGET_PODKOP}.apk' \
    "the apk artifact is named after the podkop it targets"

# without this luci.mk stamps the translation package with a date-derived version of its own
# shellcheck disable=SC2016 # the make variables are matched literally, not expanded
assert_contains "$(cat "$APP/Makefile")" 'PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)' \
    "the translation package carries the same version as the package it translates"

# a package claiming a licence the repo does not ship is a licensing bug, not a typo
assert_contains "$(cat "$APP/Makefile")" "PKG_LICENSE:=AGPL-3.0-only" \
    "the package declares the repo's licence"
assert_cmd "and the repo really ships that licence" \
    grep -q "GNU AFFERO GENERAL PUBLIC LICENSE" LICENSE

assert_contains "$(cat "$APP/Makefile")" "/etc/init.d/podkop-sub stop" "prerm stops the service"
assert_contains "$(cat "$APP/Makefile")" "/etc/init.d/podkop-sub disable" "prerm disables it"

# the service state is the on/off switch; a uci option would only ever disagree with it
assert_eq "" "$(grep -n enabled "$APP/root/etc/config/podkop-sub")" \
    "the shipped config has no enabled option"

test_summary
