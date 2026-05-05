#!/usr/bin/env bash
# .github/tests/test-compute-blocklist.sh
#
# TDD contract tests for Phase D4 compute-blocklist.sh — the shared script
# that fetches GitHub validation statuses for a SHA and emits the
# colon-separated SYNC_BLOCKED_PATHS value consumed by sync-core and
# verify-sync. Tests use BLOCKLIST_PAYLOAD_FILE to skip the gh fetch.
#
# Run: bash .github/tests/test-compute-blocklist.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPUTE_SCRIPT="$REPO_ROOT/.github/scripts/compute-blocklist.sh"
WORK_DIR="$REPO_ROOT/.github/tests/.work-compute-blocklist-$$"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  ✅ PASS: $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$1: $2"); echo "  ❌ FAIL: $1 — $2"; }
run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo "── $1: $2 ──"
}

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
mkdir -p "$WORK_DIR"

summary() {
    cleanup
    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  Tests run: $TESTS_RUN  |  Passed: $TESTS_PASSED  |  Failed: $TESTS_FAILED"
    echo "════════════════════════════════════════════════════"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo ""
        echo "Failures:"
        for f in "${FAILURES[@]}"; do echo "  • $f"; done
        exit 1
    fi
    exit 0
}

write_payload() {
    local name="$1"
    cat > "$WORK_DIR/$name.json"
}

run_compute() {
    local test_id="$1"
    local payload_name="$2"
    local expected_stdout="$3"
    local expected_exit="${4:-0}"

    set +e
    BLOCKLIST_PAYLOAD_FILE="$WORK_DIR/$payload_name.json" \
        bash "$COMPUTE_SCRIPT" microsoft-foundry/foundry-samples-pr deadbeef \
        > "$WORK_DIR/$test_id.out" 2> "$WORK_DIR/$test_id.err"
    local exit_code=$?
    set -e

    if [[ $exit_code -ne $expected_exit ]]; then
        fail "$test_id" "expected exit $expected_exit, got $exit_code; stderr: $(cat "$WORK_DIR/$test_id.err")"
        return
    fi

    if ! diff -u <(printf '%s' "$expected_stdout") "$WORK_DIR/$test_id.out" > "$WORK_DIR/$test_id.diff"; then
        fail "$test_id" "unexpected stdout: $(cat "$WORK_DIR/$test_id.diff")"
        return
    fi

    pass "$test_id"
}

# CB1: empty payload → empty output, exit 0 (legitimate "no statuses")
test_CB1() {
    run_test "CB1" "empty statuses payload → empty output, exit 0"
    write_payload "cb1" <<'JSON'
{"statuses":[]}
JSON
    run_compute "CB1" "cb1" "" 0
}

# CB2: failing statuses → blocked paths
test_CB2() {
    run_test "CB2" "failure status → blocked path"
    write_payload "cb2" <<'JSON'
{"statuses":[{"context":"validation/ado-build/samples/python/foo","state":"failure","created_at":"2026-04-29T10:00:00Z"}]}
JSON
    run_compute "CB2" "cb2" $'samples/python/foo\n' 0
}

# CB3: multiple blocked paths sorted → colon-separated
test_CB3() {
    run_test "CB3" "multiple blocked paths sorted, colon-separated"
    write_payload "cb3" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/foo","state":"failure","created_at":"2026-04-29T10:00:00Z"},
  {"context":"validation/hosted-agents-e2e/samples/csharp/bar","state":"pending","created_at":"2026-04-29T10:01:00Z"},
  {"context":"validation/ado-build/samples/python/keep","state":"success","created_at":"2026-04-29T10:02:00Z"}
]}
JSON
    run_compute "CB3" "cb3" $'samples/csharp/bar:samples/python/foo\n' 0
}

# CB4: missing payload file (and no fetch path) → exit non-zero (fail closed)
test_CB4() {
    run_test "CB4" "missing payload file → exit non-zero (fail closed)"
    set +e
    BLOCKLIST_PAYLOAD_FILE="$WORK_DIR/does-not-exist.json" \
        bash "$COMPUTE_SCRIPT" microsoft-foundry/foundry-samples-pr deadbeef \
        > "$WORK_DIR/CB4.out" 2> "$WORK_DIR/CB4.err"
    local exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
        fail "CB4" "expected non-zero exit, got 0; stdout: $(cat "$WORK_DIR/CB4.out")"
        return
    fi

    pass "CB4"
}

# CB5: stderr reports per-pipeline reporter counts (observability)
test_CB5() {
    run_test "CB5" "stderr reports per-pipeline reporter counts"
    write_payload "cb5" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/foo","state":"success","created_at":"2026-04-29T10:00:00Z"},
  {"context":"validation/ado-build/samples/python/bar","state":"failure","created_at":"2026-04-29T10:01:00Z"},
  {"context":"validation/hosted-agents-e2e/samples/python/foo","state":"success","created_at":"2026-04-29T10:02:00Z"}
]}
JSON
    set +e
    BLOCKLIST_PAYLOAD_FILE="$WORK_DIR/cb5.json" \
        bash "$COMPUTE_SCRIPT" microsoft-foundry/foundry-samples-pr deadbeef \
        > "$WORK_DIR/CB5.out" 2> "$WORK_DIR/CB5.err"
    local exit_code=$?
    set -e

    if [[ $exit_code -ne 0 ]]; then
        fail "CB5" "expected exit 0, got $exit_code; stderr: $(cat "$WORK_DIR/CB5.err")"
        return
    fi

    if ! grep -q "ado-build" "$WORK_DIR/CB5.err"; then
        fail "CB5" "stderr missing pipeline 'ado-build'; stderr: $(cat "$WORK_DIR/CB5.err")"
        return
    fi
    if ! grep -q "hosted-agents-e2e" "$WORK_DIR/CB5.err"; then
        fail "CB5" "stderr missing pipeline 'hosted-agents-e2e'; stderr: $(cat "$WORK_DIR/CB5.err")"
        return
    fi

    pass "CB5"
}

# CB6: malformed JSON in payload → exit non-zero (fail closed on parse error)
test_CB6() {
    run_test "CB6" "malformed JSON payload → exit non-zero (fail closed)"
    echo "this is not json" > "$WORK_DIR/cb6.json"
    set +e
    BLOCKLIST_PAYLOAD_FILE="$WORK_DIR/cb6.json" \
        bash "$COMPUTE_SCRIPT" microsoft-foundry/foundry-samples-pr deadbeef \
        > "$WORK_DIR/CB6.out" 2> "$WORK_DIR/CB6.err"
    local exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
        fail "CB6" "expected non-zero exit, got 0; stdout: $(cat "$WORK_DIR/CB6.out")"
        return
    fi

    pass "CB6"
}

if [[ ! -f "$COMPUTE_SCRIPT" ]]; then
    echo "⚠️  Compute-blocklist script not found at $COMPUTE_SCRIPT"
    echo "    Tests will fail until the script is implemented."
fi

test_CB1
test_CB2
test_CB3
test_CB4
test_CB5
test_CB6

summary
