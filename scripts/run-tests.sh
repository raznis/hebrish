#!/bin/bash
# Run the suite and judge it from swift-testing's JUnit XML.
#
# Neither the exit code nor stdout is trustworthy here. With a Command Line
# Tools-only toolchain, swiftpm-testing-helper aborts (signal 6) during process
# teardown, after the tests themselves have finished. That makes the exit code
# meaningless, and it also races the summary line: roughly one run in five the
# abort wins and no summary is printed at all, so judging by stdout reports a
# failure when nothing failed.
#
# The XML is written before teardown and carries explicit counts, so it is the
# one authoritative signal. Stdout is only a fallback for the case where the run
# died early enough to produce no XML.
set -uo pipefail
cd "$(dirname "$0")/.."

xml=$(mktemp -t hebrish-xunit).xml
trap 'rm -f "$xml"' EXIT

out=$(swift test --xunit-output "$xml" "$@" 2>&1)
echo "$out"

if [[ -s "$xml" ]]; then
    attr() {
        grep -o "$1=\"[0-9]*\"" "$xml" | head -1 | sed 's/.*="\([0-9]*\)"/\1/'
    }
    tests=$(attr tests); failures=$(attr failures); errors=$(attr errors)
    skipped=$(attr skipped)
    echo "==> ${tests:-0} tests, ${failures:-0} failures, ${errors:-0} errors, ${skipped:-0} skipped"
    if [[ "${tests:-0}" -gt 0 && "${failures:-0}" -eq 0 && "${errors:-0}" -eq 0 ]]; then
        echo "==> PASS"
        exit 0
    fi
    echo "==> FAIL"
    exit 1
fi

# No XML: the run did not get far enough to report, so fall back to stdout.
if grep -qE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' <<<"$out"; then
    echo "==> PASS (no XML; matched the summary line)"
    exit 0
fi
echo "==> FAIL: no test results were produced (build error or early crash)"
exit 1
