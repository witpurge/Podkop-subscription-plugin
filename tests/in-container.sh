#!/bin/sh
# shellcheck shell=dash
# Runs tests/test_*.sh inside the container; $1 filters by name without the test_ prefix.
set -u

filter="${1:-}"
rc=0
matched=0

for t in tests/test_*.sh; do
    [ -f "$t" ] || continue

    name=$(basename "$t" .sh)
    name=${name#test_}
    if [ -n "$filter" ] && [ "$filter" != "$name" ]; then
        continue
    fi
    matched=$((matched + 1))

    printf '\n== %s ==\n' "$name"
    sh "$t" || rc=1
done

if [ "$matched" -eq 0 ]; then
    echo "no tests matched '${filter:-*}'" >&2
    exit 1
fi

exit "$rc"
