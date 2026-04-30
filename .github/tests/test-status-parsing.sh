#!/usr/bin/env bash
# .github/tests/test-status-parsing.sh
#
# TDD contract tests for Phase D3 validation status parsing.
# These tests are expected to fail until parse-validation-statuses.sh is implemented.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PARSE_SCRIPT="$REPO_ROOT/.github/scripts/parse-validation-statuses.sh"
WORK_DIR="$REPO_ROOT/.github/tests/.work-status-parsing-$$"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✅ PASS: $1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("$1: $2")
    echo "  ❌ FAIL: $1 — $2"
}

run_test() {
    local test_id="$1"
    local test_name="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo "── $test_id: $test_name ──"
}

cleanup() {
    rm -rf "$WORK_DIR"
}

summary() {
    cleanup
    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  Tests run: $TESTS_RUN  |  Passed: $TESTS_PASSED  |  Failed: $TESTS_FAILED"
    echo "════════════════════════════════════════════════════"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo ""
        echo "Failures:"
        for f in "${FAILURES[@]}"; do
            echo "  • $f"
        done
        exit 1
    fi
    exit 0
}

trap cleanup EXIT
mkdir -p "$WORK_DIR"

write_status_json() {
    local name="$1"
    cat > "$WORK_DIR/$name.json"
}

run_parser_case() {
    local test_id="$1"
    local json_name="$2"
    local expected="$3"

    set +e
    bash "$PARSE_SCRIPT" "$WORK_DIR/$json_name.json" > "$WORK_DIR/$test_id.out" 2> "$WORK_DIR/$test_id.err"
    local exit_code=$?
    set -e

    if [[ $exit_code -ne 0 ]]; then
        fail "$test_id" "parser exited $exit_code; stderr: $(cat "$WORK_DIR/$test_id.err")"
        return
    fi

    if diff -u <(printf '%s' "$expected") "$WORK_DIR/$test_id.out" > "$WORK_DIR/$test_id.diff"; then
        pass "$test_id"
    else
        fail "$test_id" "unexpected output: $(cat "$WORK_DIR/$test_id.diff")"
    fi
}

# TDD: pending Phase D3 (validation status parser). Expected to fail until D3 lands.
test_S1() {
    run_test "S1" "failure status blocks one sample"
    write_status_json "S1" <<'JSON'
{"statuses":[{"context":"validation/ado-build/samples/python/foo","state":"failure","created_at":"2026-04-29T10:00:00Z"}]}
JSON
    run_parser_case "S1" "S1" $'samples/python/foo\n'
}

# TDD: pending Phase D3 (validation status parser). Expected to fail until D3 lands.
test_S2() {
    run_test "S2" "success status does not block"
    write_status_json "S2" <<'JSON'
{"statuses":[{"context":"validation/ado-build/samples/python/foo","state":"success","created_at":"2026-04-29T10:00:00Z"}]}
JSON
    run_parser_case "S2" "S2" ""
}

# TDD: pending Phase D3 (validation status parser). Expected to fail until D3 lands.
test_S3() {
    run_test "S3" "pending status blocks"
    write_status_json "S3" <<'JSON'
{"statuses":[{"context":"validation/ado-build/samples/python/foo","state":"pending","created_at":"2026-04-29T10:00:00Z"}]}
JSON
    run_parser_case "S3" "S3" $'samples/python/foo\n'
}

# TDD: pending Phase D3 (validation status parser). Expected to fail until D3 lands.
test_S4() {
    run_test "S4" "error status blocks"
    write_status_json "S4" <<'JSON'
{"statuses":[{"context":"validation/ado-build/samples/python/foo","state":"error","created_at":"2026-04-29T10:00:00Z"}]}
JSON
    run_parser_case "S4" "S4" $'samples/python/foo\n'
}

# TDD: pending Phase D3 (validation status parser). Expected to fail until D3 lands.
test_S5() {
    run_test "S5" "latest write wins for duplicate contexts"
    write_status_json "S5" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/foo","state":"failure","created_at":"2026-04-29T10:00:00Z"},
  {"context":"validation/ado-build/samples/python/foo","state":"success","created_at":"2026-04-29T10:05:00Z"}
]}
JSON
    run_parser_case "S5" "S5" ""
}

# TDD: pending Phase D3 (validation status parser). Expected to fail until D3 lands.
test_S6() {
    run_test "S6" "multiple pipelines dedupe one blocked sample"
    write_status_json "S6" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/foo","state":"success","created_at":"2026-04-29T10:00:00Z"},
  {"context":"validation/hosted-agents-e2e/samples/python/foo","state":"failure","created_at":"2026-04-29T10:01:00Z"}
]}
JSON
    run_parser_case "S6" "S6" $'samples/python/foo\n'
}

# TDD: pending Phase D3 (validation status parser). Expected to fail until D3 lands.
test_S7() {
    run_test "S7" "non-validation status is ignored"
    write_status_json "S7" <<'JSON'
{"statuses":[{"context":"ci/build","state":"failure","created_at":"2026-04-29T10:00:00Z"}]}
JSON
    run_parser_case "S7" "S7" ""
}

# TDD: pending Phase D3 (validation status parser). Expected to fail until D3 lands.
test_S8() {
    run_test "S8" "malformed validation context is ignored"
    write_status_json "S8" <<'JSON'
{"statuses":[{"context":"validation/ado-build","state":"failure","created_at":"2026-04-29T10:00:00Z"}]}
JSON
    run_parser_case "S8" "S8" ""
}

# TDD: pending Phase D3 (validation status parser). Expected to fail until D3 lands.
test_S9() {
    run_test "S9" "flattened -- path is restored to slash-separated path"
    write_status_json "S9" <<'JSON'
{"statuses":[{"context":"validation/hosted-agents-e2e/samples--python--foo","state":"failure","created_at":"2026-04-29T10:00:00Z"}]}
JSON
    run_parser_case "S9" "S9" $'samples/python/foo\n'
}

echo "Status parser script: $PARSE_SCRIPT"

test_S1
test_S2
test_S3
test_S4
test_S5
test_S6
test_S7
test_S8
test_S9

summary
