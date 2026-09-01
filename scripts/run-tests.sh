#!/bin/bash
# Run the suite and decide pass/fail from swift-testing's own summary.
#
# Why not just trust the exit code: with a Command Line Tools-only toolchain
# (no Xcode), swiftpm-testing-helper aborts during process teardown *after* the
# run has finished and reported. The tests themselves are unaffected, but the
# exit code is garbage, so we parse the summary line instead.
set -uo pipefail
cd "$(dirname "$0")/.."

out=$(swift test "$@" 2>&1)
status=$?
echo "$out"

if grep -qE '✘|◇ Test .* recorded an issue|Test run with .* failed' <<<"$out"; then
    echo "==> FAIL: one or more tests reported an issue"
    exit 1
fi
if grep -qE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' <<<"$out"; then
    echo "==> PASS"
    exit 0
fi
if grep -qE '^Test run with [0-9]+ tests? passed' <<<"$out"; then
    echo "==> PASS"
    exit 0
fi
echo "==> FAIL: the suite never reached a summary (build error or early crash); swift exit=$status"
exit 1
