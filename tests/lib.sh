# shellcheck shell=dash
# Assertions for the test scripts: sourced, and every test ends with test_summary.

TESTS_RUN=0
TESTS_FAILED=0

# the podkop we are built for lives in exactly one place; a bump must not leave the stands behind
target_podkop() {
    sed -n "s/^TARGET_PODKOP='\(.*\)'\$/\1/p" \
        luci-app-podkop-sub/root/usr/share/podkop-sub/version
}

# assert_eq <expected> <actual> <label>
assert_eq() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$1" = "$2" ]; then
        echo "ok   $3"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "FAIL $3"
        echo "     expected: $1"
        echo "     actual:   $2"
    fi
}

# assert_contains <haystack> <needle> <label>
assert_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$1" in
        *"$2"*)
            echo "ok   $3"
            ;;
        *)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            echo "FAIL $3"
            echo "     missing: $2"
            echo "     in:      $1"
            ;;
    esac
}

# assert_cmd <label> <command...>
assert_cmd() {
    label="$1"
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" > /dev/null 2>&1; then
        echo "ok   $label"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "FAIL $label ($*)"
    fi
}

test_summary() {
    echo "-- $((TESTS_RUN - TESTS_FAILED))/$TESTS_RUN passed"
    [ "$TESTS_FAILED" -eq 0 ]
}
