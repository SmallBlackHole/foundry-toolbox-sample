#!/usr/bin/env bash
# Smoke tests for ADO validation status helper scripts. No real GitHub API calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MINT_SCRIPT="$REPO_ROOT/.azure-pipelines/scripts/mint-installation-token.sh"
POST_SCRIPT="$REPO_ROOT/.azure-pipelines/scripts/post-validation-status.sh"
WORK_DIR="$REPO_ROOT/.azure-pipelines/scripts/tests/.work-validation-status-helpers-$$"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  ✅ PASS: $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$1: $2"); echo "  ❌ FAIL: $1 — $2"; }
run_test() { TESTS_RUN=$((TESTS_RUN + 1)); echo ""; echo "── $1: $2 ──"; }
cleanup() { rm -rf "$WORK_DIR"; }
summary() {
    local exit_code=$?
    cleanup
    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  Tests run: $TESTS_RUN  |  Passed: $TESTS_PASSED  |  Failed: $TESTS_FAILED"
    echo "════════════════════════════════════════════════════"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        printf '\nFailures:\n'
        printf '  • %s\n' "${FAILURES[@]}"
        exit 1
    fi
    if [[ $exit_code -ne 0 ]]; then
        exit "$exit_code"
    fi
    exit 0
}
trap summary EXIT
mkdir -p "$WORK_DIR"

json_field() {
    local field="$1"
    local file="$2"
    if command -v jq >/dev/null 2>&1; then
        jq -r ".$field" "$file"
    else
        python3 - "$field" "$file" <<'PY'
import json
import sys
with open(sys.argv[2], encoding="utf-8") as handle:
    print(json.load(handle)[sys.argv[1]])
PY
    fi
}

json_field_stdin() {
    local field="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r ".$field"
    else
        python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$field"
    fi
}

base64url_decode() {
    local input="$1"
    local remainder=$(( ${#input} % 4 ))
    if [[ $remainder -eq 2 ]]; then
        input="${input}=="
    elif [[ $remainder -eq 3 ]]; then
        input="${input}="
    elif [[ $remainder -eq 1 ]]; then
        echo "Invalid base64url length" >&2
        return 1
    fi
    printf '%s' "$input" | tr '_-' '/+' | openssl base64 -A -d
}

write_test_private_key() {
    openssl genrsa 2048 2>/dev/null
}

test_jwt_structure() {
    run_test "H1" "minted JWT has RS256 header and bounded iat/exp"

    local key jwt header payload alg typ iss iat exp delta
    key="$(write_test_private_key)"
    jwt="$(GH_APP_ID=123456 GH_APP_INSTALLATION_ID=789 GH_APP_PRIVATE_KEY="$key" bash "$MINT_SCRIPT" --print-jwt)"

    IFS='.' read -r header payload _signature <<< "$jwt"
    base64url_decode "$header" > "$WORK_DIR/jwt-header.json"
    base64url_decode "$payload" > "$WORK_DIR/jwt-payload.json"

    alg="$(json_field alg "$WORK_DIR/jwt-header.json")"
    typ="$(json_field typ "$WORK_DIR/jwt-header.json")"
    iss="$(json_field iss "$WORK_DIR/jwt-payload.json")"
    iat="$(json_field iat "$WORK_DIR/jwt-payload.json")"
    exp="$(json_field exp "$WORK_DIR/jwt-payload.json")"
    delta=$((exp - iat))

    # delta == 660s = 60s clock-skew tolerance (iat backdated by 60s)
    #               + 600s validity window (GitHub's 10-minute max for App JWTs).
    # Matches the iat/exp computation in mint-installation-token.sh.
    if [[ "$alg" == "RS256" && "$typ" == "JWT" && "$iss" == "123456" && "$delta" -eq 660 ]]; then
        pass "H1"
    else
        fail "H1" "unexpected JWT header/payload: header=$(cat "$WORK_DIR/jwt-header.json") payload=$(cat "$WORK_DIR/jwt-payload.json")"
    fi
}

test_status_payload_context() {
    run_test "H2" "status payload uses unflattened validation/ado-build context"

    # Per docs/validation-results-contract.md (normative ado-build example), this
    # pipeline preserves '/' in <sample-path>. GitHub status contexts allow '/',
    # and the D3 parser handles both forms, so flattening is unnecessary here.
    local payload context state target description
    payload="$(GITHUB_TOKEN=fake GITHUB_SHA=abc123 POST_VALIDATION_STATUS_DRY_RUN=1 \
        bash "$POST_SCRIPT" 'samples/python/quickstart-chat' success 'https://dev.azure.com/build/1' 'L3 load validation passed')"
    context="$(printf '%s' "$payload" | json_field_stdin context)"
    state="$(printf '%s' "$payload" | json_field_stdin state)"
    target="$(printf '%s' "$payload" | json_field_stdin target_url)"
    description="$(printf '%s' "$payload" | json_field_stdin description)"

    if [[ "$context" == "validation/ado-build/samples/python/quickstart-chat" && "$state" == "success" && "$target" == "https://dev.azure.com/build/1" && "$description" == "L3 load validation passed" ]]; then
        pass "H2"
    else
        fail "H2" "unexpected payload: $payload"
    fi
}

test_state_mapping() {
    run_test "H3" "state aliases map to GitHub status states"

    local passed failed timeout pending
    passed="$(GITHUB_TOKEN=fake GITHUB_SHA=abc POST_VALIDATION_STATUS_DRY_RUN=1 bash "$POST_SCRIPT" 'samples/python/a' passed url desc | json_field_stdin state)"
    failed="$(GITHUB_TOKEN=fake GITHUB_SHA=abc POST_VALIDATION_STATUS_DRY_RUN=1 bash "$POST_SCRIPT" 'samples/python/a' failed url desc | json_field_stdin state)"
    timeout="$(GITHUB_TOKEN=fake GITHUB_SHA=abc POST_VALIDATION_STATUS_DRY_RUN=1 bash "$POST_SCRIPT" 'samples/python/a' timeout url desc | json_field_stdin state)"
    pending="$(GITHUB_TOKEN=fake GITHUB_SHA=abc POST_VALIDATION_STATUS_DRY_RUN=1 bash "$POST_SCRIPT" 'samples/python/a' pending url desc | json_field_stdin state)"

    if [[ "$passed,$failed,$timeout,$pending" == "success,failure,error,pending" ]]; then
        pass "H3"
    else
        fail "H3" "unexpected mapped states: $passed,$failed,$timeout,$pending"
    fi
}

echo "Mint helper: $MINT_SCRIPT"
echo "Post helper: $POST_SCRIPT"

test_jwt_structure
test_status_payload_context
test_state_mapping
