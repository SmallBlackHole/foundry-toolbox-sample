#!/usr/bin/env bash
# Smoke tests for ADO validation status helper scripts. No real GitHub API calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MINT_SCRIPT="$REPO_ROOT/.azure-pipelines/scripts/mint-installation-token.sh"
POST_SCRIPT="$REPO_ROOT/.azure-pipelines/scripts/post-validation-status.sh"
DECIDE_SCRIPT="$REPO_ROOT/.azure-pipelines/scripts/decide-carry-over-state.sh"
FETCH_SCRIPT="$REPO_ROOT/.azure-pipelines/scripts/fetch-parent-validation-statuses.sh"
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

test_decide_carry_over_state() {
    run_test "H4" "decide-carry-over-state encodes the carry-over decision matrix"

    # Fixture: parent SHA had a mix of states for ado-build contexts.
    local fixture="$WORK_DIR/parent-statuses.txt"
    cat > "$fixture" <<'EOF'
samples/python/passing:success
samples/python/broken:failure
samples/python/errored:error
samples/python/pending-sample:pending
EOF

    local out_success out_failure out_error out_pending out_missing
    out_success="$(bash "$DECIDE_SCRIPT" 'samples/python/passing' "$fixture")"
    out_failure="$(bash "$DECIDE_SCRIPT" 'samples/python/broken' "$fixture")"
    out_error="$(bash "$DECIDE_SCRIPT" 'samples/python/errored' "$fixture")"
    out_pending="$(bash "$DECIDE_SCRIPT" 'samples/python/pending-sample' "$fixture")"
    out_missing="$(bash "$DECIDE_SCRIPT" 'samples/python/never-validated' "$fixture")"

    # Each line is "<state>\t<description>"; extract the state field.
    local s_success s_failure s_error s_pending s_missing
    s_success="$(printf '%s' "$out_success" | cut -f1)"
    s_failure="$(printf '%s' "$out_failure" | cut -f1)"
    s_error="$(printf '%s' "$out_error" | cut -f1)"
    s_pending="$(printf '%s' "$out_pending" | cut -f1)"
    s_missing="$(printf '%s' "$out_missing" | cut -f1)"

    # Decision matrix:
    #   parent success  → success  (carried over)
    #   parent failure  → failure  (carried forward; source unchanged)
    #   parent error    → error    (carried forward; source unchanged)
    #   parent pending  → error    (no decisive prior result)
    #   parent missing  → error    (no prior result at all)
    local actual="$s_success,$s_failure,$s_error,$s_pending,$s_missing"
    if [[ "$actual" == "success,failure,error,error,error" ]]; then
        # Spot-check that descriptions are non-empty and distinguish carried vs missing.
        local d_success d_missing
        d_success="$(printf '%s' "$out_success" | cut -f2)"
        d_missing="$(printf '%s' "$out_missing" | cut -f2)"
        if [[ -n "$d_success" && -n "$d_missing" && "$d_success" != "$d_missing" ]]; then
            pass "H4"
        else
            fail "H4" "states correct but descriptions missing/identical: success=[$d_success] missing=[$d_missing]"
        fi
    else
        fail "H4" "expected success,failure,error,error,error; got $actual"
    fi
}

test_fetch_parent_statuses_filter() {
    run_test "H5" "fetch-parent-validation-statuses extracts only validation/ado-build/* contexts"

    # Fixture mimics the GitHub combined-status response: one validation/ado-build/<path>
    # entry per sample plus an unrelated context that must be filtered out.
    local fixture="$WORK_DIR/combined-status.json"
    cat > "$fixture" <<'EOF'
{
  "state": "failure",
  "total_count": 4,
  "statuses": [
    {"context": "validation/ado-build/samples/python/quickstart-chat", "state": "success"},
    {"context": "validation/ado-build/samples/csharp/agents/quickstart", "state": "failure"},
    {"context": "validation/hosted-agents-e2e/samples/python/quickstart-chat", "state": "success"},
    {"context": "ci/some-other-check", "state": "success"}
  ]
}
EOF

    local out
    out="$(FETCH_STATUSES_FIXTURE="$fixture" bash "$FETCH_SCRIPT" deadbeef)"

    local expected
    expected="samples/python/quickstart-chat:success
samples/csharp/agents/quickstart:failure"

    # Order is preserved from input; the filter must drop hosted-agents-e2e and ci/* contexts.
    if [[ "$out" == "$expected" ]]; then
        pass "H5"
    else
        fail "H5" "unexpected output:
expected:
$expected
actual:
$out"
    fi
}

test_fetch_parent_statuses_empty() {
    run_test "H6" "fetch-parent-validation-statuses on a SHA with no statuses emits nothing"

    local fixture="$WORK_DIR/combined-status-empty.json"
    cat > "$fixture" <<'EOF'
{
  "state": "pending",
  "total_count": 0,
  "statuses": []
}
EOF

    local out
    out="$(FETCH_STATUSES_FIXTURE="$fixture" bash "$FETCH_SCRIPT" deadbeef)"

    if [[ -z "$out" ]]; then
        pass "H6"
    else
        fail "H6" "expected empty output, got: $out"
    fi
}

test_jwt_structure_flat_pem() {
    run_test "H7" "minted JWT works when PEM arrives flattened (no newlines)"

    local key flat jwt header payload alg iss
    key="$(write_test_private_key)"
    flat="$(printf '%s' "$key" | tr -d '\n')"
    jwt="$(GH_APP_ID=654321 GH_APP_INSTALLATION_ID=789 GH_APP_PRIVATE_KEY="$flat" bash "$MINT_SCRIPT" --print-jwt)"

    IFS='.' read -r header payload _signature <<< "$jwt"
    base64url_decode "$header" > "$WORK_DIR/jwt-header-flat.json"
    base64url_decode "$payload" > "$WORK_DIR/jwt-payload-flat.json"

    alg="$(json_field alg "$WORK_DIR/jwt-header-flat.json")"
    iss="$(json_field iss "$WORK_DIR/jwt-payload-flat.json")"

    if [[ "$alg" == "RS256" && "$iss" == "654321" ]]; then
        pass "H7"
    else
        fail "H7" "flat-PEM mint produced unexpected JWT: header=$(cat "$WORK_DIR/jwt-header-flat.json") payload=$(cat "$WORK_DIR/jwt-payload-flat.json")"
    fi
}

# ─── G1-G5: push:main fan-out gate (compute-push-main-partial.sh) ─────────
GATE_SCRIPT="$REPO_ROOT/.azure-pipelines/scripts/compute-push-main-partial.sh"

run_gate() {
    # Run gate script with a clean env so previous test cases don't leak.
    env -i PATH="$PATH" \
        BUILD_SOURCE_BRANCH="${1:-}" \
        BUILD_REASON="${2:-}" \
        VALIDATE_ALL="${3:-false}" \
        bash "$GATE_SCRIPT"
}

assert_gate() {
    local label="$1" expected="$2" actual="$3" detail="$4"
    if [[ "$actual" == "$expected" ]]; then
        pass "$label"
    else
        fail "$label" "expected $expected, got $actual ($detail)"
    fi
}

test_gate_individualci_main() {
    run_test "G1" "gate=1 for IndividualCI on refs/heads/main"
    local out; out="$(run_gate refs/heads/main IndividualCI false)"
    assert_gate "G1" "1" "$out" "BUILD_SOURCE_BRANCH=refs/heads/main BUILD_REASON=IndividualCI"
}

test_gate_manual_main() {
    run_test "G2" "gate=1 for Manual on refs/heads/main (re-queue path)"
    local out; out="$(run_gate refs/heads/main Manual false)"
    assert_gate "G2" "1" "$out" "BUILD_SOURCE_BRANCH=refs/heads/main BUILD_REASON=Manual"
}

test_gate_schedule_main() {
    run_test "G3" "gate=0 for Schedule on refs/heads/main (full validation owns posts)"
    local out; out="$(run_gate refs/heads/main Schedule false)"
    assert_gate "G3" "0" "$out" "BUILD_SOURCE_BRANCH=refs/heads/main BUILD_REASON=Schedule"
}

test_gate_pr_branch() {
    run_test "G4" "gate=0 for PullRequest build on refs/pull/X/merge"
    local out; out="$(run_gate refs/pull/123/merge PullRequest false)"
    assert_gate "G4" "0" "$out" "PR builds never fan out (sync only reads main)"
}

test_gate_validate_all() {
    run_test "G5" "gate=0 when VALIDATE_ALL=true (case-insensitive) — full sweep posts directly"
    local out_true out_True
    out_true="$(run_gate refs/heads/main IndividualCI true)"
    out_True="$(run_gate refs/heads/main Manual True)"
    if [[ "$out_true" == "0" && "$out_True" == "0" ]]; then
        pass "G5"
    else
        fail "G5" "expected 0 for VALIDATE_ALL=true and =True; got $out_true / $out_True"
    fi
}

test_gate_batchedci_main() {
    run_test "G5b" "gate=1 for BatchedCI on refs/heads/main (batched push)"
    local out; out="$(run_gate refs/heads/main BatchedCI false)"
    assert_gate "G5b" "1" "$out" "BUILD_SOURCE_BRANCH=refs/heads/main BUILD_REASON=BatchedCI"
}

# ─── G6: validation.yml trigger config invariant ──────────────────────────
# Static check that the trigger contract for the production pipeline matches
# what Fix A landed: every push:main must queue a run (no path filter); PR
# runs keep their cost-control path filter. If a future edit reintroduces
# `paths:` on the main trigger, the fan-out from D4's perspective regresses
# silently — this test fails loudly instead.
test_trigger_config_invariant() {
    run_test "G6" "validation.yml main trigger has no paths filter; PR trigger still does"

    local yaml="$REPO_ROOT/.azure-pipelines/validation.yml"
    if [[ ! -f "$yaml" ]]; then
        fail "G6" "validation.yml not found at $yaml"
        return
    fi

    # Use python (always available in this repo's CI) for a robust line-based
    # parse so we don't get tripped up by comments or whitespace shifts. Falls
    # back to awk if python isn't available.
    local result
    if command -v python3 >/dev/null 2>&1; then
        result="$(python3 - "$yaml" <<'PY'
import sys
import re

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

def block_lines(key):
    """Return body lines (after `key:`) of the top-level block, stopping at
    the next column-0 non-blank, non-comment line. Comments inside the block
    are kept; empty lines are kept. We strip inline comments before matching."""
    out = []
    inside = False
    for line in lines:
        if not inside:
            if re.match(rf"^{re.escape(key)}\s*:\s*(?:#.*)?$", line):
                inside = True
            continue
        # inside: stop when we hit a new top-level key (column-0 letter).
        if re.match(r"^[A-Za-z]", line):
            break
        out.append(line)
    return out

def has_paths(block):
    for line in block:
        # Strip inline comment.
        code = re.sub(r"\s*#.*$", "", line).rstrip("\n")
        if re.match(r"^\s*paths\s*:\s*$", code):
            return True
    return False

def has_main_branch(block):
    for line in block:
        code = re.sub(r"\s*#.*$", "", line).rstrip("\n")
        if re.match(r"^\s*-\s*main\s*$", code):
            return True
    return False

trig = block_lines("trigger")
pr = block_lines("pr")

if not trig:
    print("FAIL: no trigger: block found"); sys.exit(0)
if not pr:
    print("FAIL: no pr: block found"); sys.exit(0)

if has_paths(trig):
    print("FAIL: main trigger has a paths: filter — Fix A regressed"); sys.exit(0)

if not has_paths(pr):
    print("FAIL: pr trigger missing paths: filter — cost guard regressed"); sys.exit(0)

if not has_main_branch(trig):
    print("FAIL: main not in trigger.branches.include"); sys.exit(0)

print("OK")
PY
)"
    else
        # Awk fallback: walk lines from `^trigger:` until next column-0 letter,
        # asserting no line in between is `paths:`.
        result="$(awk '
            /^trigger:[[:space:]]*$/ { in_trig = 1; next }
            in_trig && /^[A-Za-z]/ { in_trig = 0 }
            in_trig {
                line = $0
                sub(/[[:space:]]*#.*$/, "", line)
                if (line ~ /^[[:space:]]*paths[[:space:]]*:[[:space:]]*$/) found = 1
            }
            END { print (found ? "FAIL: main trigger has a paths: filter — Fix A regressed" : "OK") }
        ' "$yaml")"
    fi

    if [[ "$result" == "OK" ]]; then
        pass "G6"
    else
        fail "G6" "$result"
    fi
}

# ─── G7: shell scripts under .azure-pipelines/scripts/ have exec bit ──────
# Static check that every tracked *.sh under .azure-pipelines/scripts/ is
# stored in git with mode 100755. PR-A (#237) shipped
# fetch-parent-validation-statuses.sh as 100644, which silently fail-closed
# every carry-over fan-out to `error` on Linux agents (Permission denied).
# The publish step's fail-closed posture masked the bug as "carry-over →
# error" instead of failing the build, so it only surfaced once we had a
# parent SHA with real success statuses to compare against. This test
# catches the same class of regression at PR time.
test_script_exec_bits() {
    run_test "G7" "all *.sh under .azure-pipelines/scripts/ have mode 100755 in git index"

    local listing
    listing="$(cd "$REPO_ROOT" && git ls-files --stage -- '.azure-pipelines/scripts/*.sh' '.azure-pipelines/scripts/**/*.sh')"

    if [[ -z "$listing" ]]; then
        fail "G7" "no tracked *.sh files found under .azure-pipelines/scripts/ (test setup error)"
        return
    fi

    local bad=""
    while IFS= read -r row; do
        # Format: <mode> <sha> <stage>\t<path>
        local mode path
        mode="${row%% *}"
        path="${row#*$'\t'}"
        if [[ "$mode" != "100755" ]]; then
            bad+="  $mode  $path"$'\n'
        fi
    done <<< "$listing"

    if [[ -z "$bad" ]]; then
        pass "G7"
    else
        fail "G7" $'shell scripts missing exec bit (run `git update-index --chmod=+x <path>`):\n'"$bad"
    fi
}

echo "Mint helper:   $MINT_SCRIPT"
echo "Post helper:   $POST_SCRIPT"
echo "Decide helper: $DECIDE_SCRIPT"
echo "Fetch helper:  $FETCH_SCRIPT"

test_jwt_structure
test_status_payload_context
test_state_mapping
test_decide_carry_over_state
test_fetch_parent_statuses_filter
test_fetch_parent_statuses_empty
test_jwt_structure_flat_pem
test_gate_individualci_main
test_gate_manual_main
test_gate_schedule_main
test_gate_pr_branch
test_gate_validate_all
test_gate_batchedci_main
test_trigger_config_invariant
test_script_exec_bits
