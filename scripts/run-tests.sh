#!/bin/bash
# Run the suite and decide pass/fail from whichever signal actually reported.
#
# Neither the exit code nor any single output is dependable here. With a Command
# Line Tools-only toolchain, swiftpm-testing-helper aborts (signal 6) during
# process teardown, after the tests have finished:
#
#   * the exit code is therefore meaningless;
#   * the abort races the stdout summary, so roughly one run in five prints no
#     summary at all;
#   * and occasionally the JUnit XML lands with tests="0" even though every test
#     ran and passed.
#
# So: prefer the XML when it actually contains results, fall back to the stdout
# summary when it does not, and fail only when neither reports success.
set -uo pipefail
cd "$(dirname "$0")/.."

xml=$(mktemp -t hebrish-xunit)
rm -f "$xml"          # mktemp made it; swift test wants to create it itself
trap 'rm -f "$xml"' EXIT

out=$(swift test --xunit-output "$xml" "$@" 2>&1)
echo "$out"

xml_attr() {
    [[ -s "$xml" ]] || { echo 0; return; }
    local v
    v=$(grep -o "$1=\"[0-9]*\"" "$xml" | head -1 | sed 's/.*="\([0-9]*\)"/\1/')
    echo "${v:-0}"
}

tests=$(xml_attr tests)
failures=$(xml_attr failures)
errors=$(xml_attr errors)
skipped=$(xml_attr skipped)

if [[ "$tests" -gt 0 ]]; then
    echo "==> $tests tests, $failures failures, $errors errors, $skipped skipped"
    if [[ "$failures" -eq 0 && "$errors" -eq 0 ]]; then
        echo "==> PASS"; exit 0
    fi
    echo "==> FAIL"; exit 1
fi

# No usable XML. Fall back to what swift-testing printed.
if grep -qE '✘|Test run with .* failed' <<<"$out"; then
    echo "==> FAIL (from the printed summary)"; exit 1
fi
if grep -qE 'Test run with [0-9]+ tests?( in [0-9]+ suites?)? passed' <<<"$out"; then
    echo "==> PASS (no XML results; matched the printed summary)"; exit 0
fi
echo "==> FAIL: no results were produced at all (build error or early crash)"
exit 1
