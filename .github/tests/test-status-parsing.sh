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

# ── --json mode tests (per-context structured output for Health Board) ──
# In --json mode the parser emits a JSON array of objects with shape:
#   {path, pipeline_id, state, target_url, created_at, context}
# One entry per latest-write-wins context. ALL states retained (not just blocking).

run_parser_json_case() {
    local test_id="$1"
    local json_name="$2"
    local py_expr="$3"
    local expected="$4"

    set +e
    bash "$PARSE_SCRIPT" --json "$WORK_DIR/$json_name.json" > "$WORK_DIR/$test_id.out.json" 2> "$WORK_DIR/$test_id.err"
    local exit_code=$?
    set -e

    if [[ $exit_code -ne 0 ]]; then
        fail "$test_id" "parser --json exited $exit_code; stderr: $(cat "$WORK_DIR/$test_id.err")"
        return
    fi

    set +e
    local actual
    actual="$(python3 -c "
import json, sys
data = json.load(open('$WORK_DIR/$test_id.out.json'))
result = $py_expr
print(result, end='')
" 2> "$WORK_DIR/$test_id.py-err")"
    local py_exit=$?
    set -e

    if [[ $py_exit -ne 0 ]]; then
        fail "$test_id" "python assertion failed (exit $py_exit): $(cat "$WORK_DIR/$test_id.py-err"); raw output: $(cat "$WORK_DIR/$test_id.out.json")"
        return
    fi

    if [[ "$actual" == "$expected" ]]; then
        pass "$test_id"
    else
        fail "$test_id" "expected '$expected', got '$actual' (full output: $(cat "$WORK_DIR/$test_id.out.json"))"
    fi
}

test_J1() {
    run_test "J1" "--json emits per-context entries with path, pipeline_id, state"
    write_status_json "J1" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/foo","state":"success","target_url":"https://dev.azure.com/x/_build/results?buildId=1","created_at":"2026-04-29T10:00:00Z"},
  {"context":"validation/ado-build/samples/csharp/bar","state":"failure","target_url":"https://dev.azure.com/x/_build/results?buildId=2","created_at":"2026-04-29T11:00:00Z"}
]}
JSON
    run_parser_json_case "J1" "J1" "len(data)" "2"
}

test_J2() {
    run_test "J2" "--json includes target_url and pipeline_id correctly"
    write_status_json "J2" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/foo","state":"failure","target_url":"https://dev.azure.com/x/_build/results?buildId=42","created_at":"2026-04-29T10:00:00Z"}
]}
JSON
    run_parser_json_case "J2" "J2" "'%s|%s|%s|%s' % (data[0]['pipeline_id'], data[0]['path'], data[0]['state'], data[0]['target_url'])" \
        "ado-build|samples/python/foo|failure|https://dev.azure.com/x/_build/results?buildId=42"
}

test_J3() {
    run_test "J3" "--json applies latest-write-wins across duplicate contexts"
    write_status_json "J3" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/foo","state":"failure","target_url":"u1","created_at":"2026-04-29T09:00:00Z"},
  {"context":"validation/ado-build/samples/python/foo","state":"success","target_url":"u2","created_at":"2026-04-29T11:00:00Z"},
  {"context":"validation/ado-build/samples/python/foo","state":"pending","target_url":"u0","created_at":"2026-04-29T08:00:00Z"}
]}
JSON
    run_parser_json_case "J3" "J3" "'%s|%s' % (data[0]['state'], data[0]['target_url'])" "success|u2"
}

test_J4() {
    run_test "J4" "--json retains success states (not just blocking)"
    write_status_json "J4" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/foo","state":"success","target_url":"u1","created_at":"2026-04-29T10:00:00Z"}
]}
JSON
    run_parser_json_case "J4" "J4" "','.join(r['state'] for r in data)" "success"
}

test_J5() {
    run_test "J5" "--json decodes -- to / in path"
    write_status_json "J5" <<'JSON'
{"statuses":[
  {"context":"validation/hosted-agents-e2e/samples--python--hosted-agents--alpha","state":"success","target_url":"u","created_at":"2026-04-29T10:00:00Z"}
]}
JSON
    run_parser_json_case "J5" "J5" "data[0]['path']" "samples/python/hosted-agents/alpha"
}

test_J6() {
    run_test "J6" "--json with empty input emits []"
    write_status_json "J6" <<'JSON'
{"statuses":[]}
JSON
    run_parser_json_case "J6" "J6" "len(data)" "0"
}

test_J7() {
    run_test "J7" "--json ignores non-validation contexts"
    write_status_json "J7" <<'JSON'
{"statuses":[
  {"context":"ci/build","state":"success","target_url":"u","created_at":"2026-04-29T10:00:00Z"},
  {"context":"validation/ado-build/samples/python/foo","state":"success","target_url":"u","created_at":"2026-04-29T10:00:00Z"}
]}
JSON
    run_parser_json_case "J7" "J7" "len(data)" "1"
}

test_J1
test_J2
test_J3
test_J4
test_J5
test_J6
test_J7

summary
