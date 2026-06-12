#!/usr/bin/env bash
# .github/tests/test-fix-unmapped.sh
#
# Self-contained test suite for the auto-fix mailmap pipeline:
#   - merge-mailmap-additions.sh  (T1–T7, T-AMIT — pure unit)
#   - detect-unmapped-emails.sh   (T-EMPTY — empty-alias filter, ADO 5356763)
#   - fix-unmapped-emails-orchestrate.sh (E1–E3 — with fake `gh`)
#
# Mirrors the style of test-sync.sh exactly: bash helpers, temp-git pattern,
# no bats / no frameworks.
#
# Usage: bash .github/tests/test-fix-unmapped.sh
# Exit code: 0 if all tests pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MERGE_SCRIPT="$REPO_ROOT/.github/scripts/merge-mailmap-additions.sh"
DETECT_SCRIPT="$REPO_ROOT/.github/scripts/detect-unmapped-emails.sh"
ORCHESTRATE_SCRIPT="$REPO_ROOT/.github/scripts/fix-unmapped-emails-orchestrate.sh"

# ── Test framework (mirrors test-sync.sh) ──────────────────────────────────────

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

summary() {
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

# ── Helpers ────────────────────────────────────────────────────────────────────

WORK_DIR=""

setup_workdir() {
    WORK_DIR="/tmp/test-fix-unmapped-$$-${TESTS_RUN}"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

# Build a detect-style JSON payload from inline "email|alias|entry" rows.
# Use literal '\n' (backslash-n) inside <entry> to encode a two-line entry —
# the helper expands it to a real newline before JSON encoding.
write_detect_json() {
    local out="$1"
    shift
    python3 - "$out" "$@" <<'PY'
import json
import sys

out_path = sys.argv[1]
items = []
for raw in sys.argv[2:]:
    if not raw:
        continue
    parts = raw.split("|", 2)
    email = parts[0]
    alias = parts[1] if len(parts) > 1 else ""
    entry = parts[2] if len(parts) > 2 else ""
    items.append({
        "email": email,
        "alias": alias,
        "suggested_entry": entry.replace("\\n", "\n"),
    })
with open(out_path, "w") as f:
    json.dump({"unmapped": items}, f)
PY
}

# Write a minimal mailmap; lines passed as args are concatenated with newlines.
write_mailmap() {
    local out="$1"; shift
    : > "$out"
    for line in "$@"; do
        printf '%s\n' "$line" >> "$out"
    done
}

# Run merge-mailmap-additions.sh and capture stdout/stderr/exit code.
run_merge() {
    local detect="$1"
    local effective="$2"
    local stdout_file="$3"
    local stderr_file="$4"
    set +e
    bash "$MERGE_SCRIPT" \
        --detect-json "$detect" \
        --effective-mailmap "$effective" \
        > "$stdout_file" 2> "$stderr_file"
    local rc=$?
    set -e
    return $rc
}

# Install a stub `gh` on PATH for orchestration tests.
#
# The stub records every invocation (one line per call) to $FAKE_GH_LOG and
# returns canned data from $FAKE_GH_FIXTURES/<command>.out when present.
install_fake_gh() {
    local bin_dir="$WORK_DIR/bin"
    mkdir -p "$bin_dir"
    FAKE_GH_LOG="$WORK_DIR/fake-gh.log"
    FAKE_GH_FIXTURES="$WORK_DIR/fake-gh-fixtures"
    mkdir -p "$FAKE_GH_FIXTURES"
    : > "$FAKE_GH_LOG"

    cat > "$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
# Fake gh — log invocation, optionally emit fixture, exit 0.
{
    printf 'gh'
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
} >> "$FAKE_GH_LOG"

# Fixture lookup: combine the first 1–3 positional args into a key.
key=""
for a in "$@"; do
    case "$a" in
        --*|-*) break ;;
        *)
            if [[ -z "$key" ]]; then key="$a"; else key="$key-$a"; fi
            ;;
    esac
done
fixture="$FAKE_GH_FIXTURES/${key}.out"
if [[ -f "$fixture" ]]; then
    cat "$fixture"
fi
exit 0
STUB
    chmod +x "$bin_dir/gh"
    export PATH="$bin_dir:$PATH"
    export FAKE_GH_LOG
    export FAKE_GH_FIXTURES
}

# Count fake-gh invocations matching a regex. Always emits a single integer.
fake_gh_count() {
    local pattern="$1"
    local n
    if [[ ! -f "${FAKE_GH_LOG:-}" ]]; then
        echo 0; return
    fi
    n=$(grep -cE "$pattern" "$FAKE_GH_LOG" 2>/dev/null) || n=0
    echo "${n:-0}"
}

# ── Unit tests: merge-mailmap-additions.sh ─────────────────────────────────────

# T1 — Empty detect → empty output, exit 0.
test_T1() {
    run_test "T1" "Empty detect input → no additions"
    setup_workdir
    write_detect_json "$WORK_DIR/detect.json"
    write_mailmap "$WORK_DIR/eff.mailmap" "# empty"
    if ! run_merge "$WORK_DIR/detect.json" "$WORK_DIR/eff.mailmap" \
        "$WORK_DIR/out" "$WORK_DIR/err"; then
        fail "T1" "exit non-zero: $(cat "$WORK_DIR/err")"
        cleanup; return
    fi
    if [[ -s "$WORK_DIR/out" ]]; then
        fail "T1" "expected empty output, got:
$(cat "$WORK_DIR/out")"
        cleanup; return
    fi
    pass "T1"
    cleanup
}

# T2 — One unmapped with a real resolved entry not in effective → emit it.
test_T2() {
    run_test "T2" "Unmapped + resolved entry, not in effective → emit"
    setup_workdir
    local entry="# VERIFY (confidence: low): auto-resolved newuser → newuser\nNew User <99+newuser@users.noreply.github.com> <newuser@microsoft.com>"
    write_detect_json "$WORK_DIR/detect.json" \
        "newuser@microsoft.com|newuser|$entry"
    write_mailmap "$WORK_DIR/eff.mailmap" \
        "Existing User <1+existing@users.noreply.github.com> <existing@microsoft.com>"
    if ! run_merge "$WORK_DIR/detect.json" "$WORK_DIR/eff.mailmap" \
        "$WORK_DIR/out" "$WORK_DIR/err"; then
        fail "T2" "exit non-zero: $(cat "$WORK_DIR/err")"
        cleanup; return
    fi
    if ! grep -qF "<newuser@microsoft.com>" "$WORK_DIR/out"; then
        fail "T2" "expected new entry in output, got:
$(cat "$WORK_DIR/out")"
        cleanup; return
    fi
    if ! grep -qF "VERIFY" "$WORK_DIR/out"; then
        fail "T2" "expected VERIFY comment in output"
        cleanup; return
    fi
    pass "T2"
    cleanup
}

# T3 — Unmapped that's already in effective mailmap → empty output.
test_T3() {
    run_test "T3" "Unmapped already in effective → dedup to empty"
    setup_workdir
    local entry="# VERIFY (confidence: low): auto-resolved dup → dup\nDup User <5+dup@users.noreply.github.com> <dup@microsoft.com>"
    write_detect_json "$WORK_DIR/detect.json" \
        "dup@microsoft.com|dup|$entry"
    write_mailmap "$WORK_DIR/eff.mailmap" \
        "Dup User <5+dup@users.noreply.github.com> <dup@microsoft.com>"
    if ! run_merge "$WORK_DIR/detect.json" "$WORK_DIR/eff.mailmap" \
        "$WORK_DIR/out" "$WORK_DIR/err"; then
        fail "T3" "exit non-zero: $(cat "$WORK_DIR/err")"
        cleanup; return
    fi
    if [[ -s "$WORK_DIR/out" ]]; then
        fail "T3" "expected empty output, got:
$(cat "$WORK_DIR/out")"
        cleanup; return
    fi
    pass "T3"
    cleanup
}

# T4 — Mixed: 2 unmapped, one in effective, one not → emit only the missing one.
test_T4() {
    run_test "T4" "Mixed input: emit only the entry not in effective"
    setup_workdir
    local e_old="# VERIFY: auto-resolved old → old\nOld User <2+old@users.noreply.github.com> <old@microsoft.com>"
    local e_new="# VERIFY: auto-resolved new → new\nNew User <3+new@users.noreply.github.com> <new@microsoft.com>"
    write_detect_json "$WORK_DIR/detect.json" \
        "old@microsoft.com|old|$e_old" \
        "new@microsoft.com|new|$e_new"
    write_mailmap "$WORK_DIR/eff.mailmap" \
        "Old User <2+old@users.noreply.github.com> <old@microsoft.com>"
    if ! run_merge "$WORK_DIR/detect.json" "$WORK_DIR/eff.mailmap" \
        "$WORK_DIR/out" "$WORK_DIR/err"; then
        fail "T4" "exit non-zero: $(cat "$WORK_DIR/err")"
        cleanup; return
    fi
    if grep -qF "<old@microsoft.com>" "$WORK_DIR/out"; then
        fail "T4" "should NOT re-emit existing 'old' entry"
        cleanup; return
    fi
    if ! grep -qF "<new@microsoft.com>" "$WORK_DIR/out"; then
        fail "T4" "expected 'new' entry in output, got:
$(cat "$WORK_DIR/out")"
        cleanup; return
    fi
    pass "T4"
    cleanup
}

# T5 — UNRESOLVED entry → emit "Needs manual lookup" placeholder block.
test_T5() {
    run_test "T5" "UNRESOLVED entry → manual-lookup placeholder"
    setup_workdir
    local entry="# UNRESOLVED: unknown <???> <unknown@microsoft.com>"
    write_detect_json "$WORK_DIR/detect.json" \
        "unknown@microsoft.com|unknown|$entry"
    write_mailmap "$WORK_DIR/eff.mailmap" "# empty"
    if ! run_merge "$WORK_DIR/detect.json" "$WORK_DIR/eff.mailmap" \
        "$WORK_DIR/out" "$WORK_DIR/err"; then
        fail "T5" "exit non-zero: $(cat "$WORK_DIR/err")"
        cleanup; return
    fi
    if ! grep -qF "Needs manual lookup" "$WORK_DIR/out"; then
        fail "T5" "expected 'Needs manual lookup' placeholder, got:
$(cat "$WORK_DIR/out")"
        cleanup; return
    fi
    if ! grep -qF "?q=unknown" "$WORK_DIR/out"; then
        fail "T5" "expected lookup URL with alias query"
        cleanup; return
    fi
    pass "T5"
    cleanup
}

# T6 — Empty suggested_entry → same manual-lookup placeholder behavior.
test_T6() {
    run_test "T6" "Empty suggested_entry → manual-lookup placeholder"
    setup_workdir
    write_detect_json "$WORK_DIR/detect.json" \
        "alice@microsoft.com|alice|"
    write_mailmap "$WORK_DIR/eff.mailmap" "# empty"
    if ! run_merge "$WORK_DIR/detect.json" "$WORK_DIR/eff.mailmap" \
        "$WORK_DIR/out" "$WORK_DIR/err"; then
        fail "T6" "exit non-zero: $(cat "$WORK_DIR/err")"
        cleanup; return
    fi
    if ! grep -qF "?q=alice" "$WORK_DIR/out"; then
        fail "T6" "expected lookup URL with alias query"
        cleanup; return
    fi
    pass "T6"
    cleanup
}

# T7 — Idempotent: same inputs twice → same output.
test_T7() {
    run_test "T7" "Idempotent — running twice produces identical output"
    setup_workdir
    local entry="# VERIFY: auto-resolved idem → idem\nIdem <7+idem@users.noreply.github.com> <idem@microsoft.com>"
    write_detect_json "$WORK_DIR/detect.json" \
        "idem@microsoft.com|idem|$entry"
    write_mailmap "$WORK_DIR/eff.mailmap" "# empty"
    if ! run_merge "$WORK_DIR/detect.json" "$WORK_DIR/eff.mailmap" \
        "$WORK_DIR/out1" "$WORK_DIR/err1"; then
        fail "T7" "first run exit non-zero: $(cat "$WORK_DIR/err1")"
        cleanup; return
    fi
    if ! run_merge "$WORK_DIR/detect.json" "$WORK_DIR/eff.mailmap" \
        "$WORK_DIR/out2" "$WORK_DIR/err2"; then
        fail "T7" "second run exit non-zero: $(cat "$WORK_DIR/err2")"
        cleanup; return
    fi
    if ! diff -q "$WORK_DIR/out1" "$WORK_DIR/out2" >/dev/null; then
        fail "T7" "outputs differ between runs:
$(diff "$WORK_DIR/out1" "$WORK_DIR/out2")"
        cleanup; return
    fi
    pass "T7"
    cleanup
}

# T8 — Placeholder dedup. Effective mailmap (= an open auto-fix PR branch's
# mailmap) already contains the "Needs manual lookup" placeholder block this
# script emits for unresolved aliases. detect surfaces the same alias again
# (still unresolved). Merge MUST recognise the placeholder as "already
# represented" and emit nothing — otherwise every failing-sync trigger would
# append a duplicate placeholder block to the open PR, ballooning its diff.
# Same PR-pollution family as the PR-flood regression closed in 491650fd.
test_T8() {
    run_test "T8" "Placeholder for unresolved alias already in effective → dedup to empty"
    setup_workdir
    # detect surfaces an unresolved row (no suggested_entry) for amitbhave.
    write_detect_json "$WORK_DIR/detect.json" \
        "amitbhave@microsoft.com|amitbhave|"
    # Previous merge run already wrote the placeholder block into the open
    # PR branch's mailmap.
    write_mailmap "$WORK_DIR/eff.mailmap" \
        "Existing User <1+existing@users.noreply.github.com> <existing@microsoft.com>" \
        "" \
        "# -- Added by fix-unmapped-emails workflow (2026-06-01) ----" \
        "# VERIFY: Needs manual lookup - amitbhave@microsoft.com" \
        "# Lookup: https://repos.opensource.microsoft.com/people?q=amitbhave"
    if ! run_merge "$WORK_DIR/detect.json" "$WORK_DIR/eff.mailmap" \
        "$WORK_DIR/out" "$WORK_DIR/err"; then
        fail "T8" "exit non-zero: $(cat "$WORK_DIR/err")"
        cleanup; return
    fi
    if [[ -s "$WORK_DIR/out" ]]; then
        fail "T8" "expected empty output (placeholder dedup'd), got:
$(cat "$WORK_DIR/out")"
        cleanup; return
    fi
    pass "T8"
    cleanup
}

# T-AMIT — Regression for ADO 5356762.
# Main mailmap is empty (or has unrelated entries). PR #479-style additions
# include `pelong`. New detect run reports BOTH pelong (already in PR's branch
# mailmap) and amitbhave (new). The effective mailmap = main ∪ PR-additions.
# Script must emit ONLY amitbhave — never re-emit pelong, never silently drop.
test_T_AMIT() {
    run_test "T-AMIT" "Regression: append amitbhave without re-emitting pelong"
    setup_workdir

    local pelong_entry="# VERIFY (confidence: low): auto-resolved pelong → pelong\nPelong <11+pelong@users.noreply.github.com> <pelong@microsoft.com>"
    local amit_entry="# VERIFY (confidence: low): auto-resolved amitbhave → amitbhave\nAmit Bhave <22+amitbhave@users.noreply.github.com> <amitbhave@microsoft.com>"

    write_detect_json "$WORK_DIR/detect.json" \
        "pelong@microsoft.com|pelong|$pelong_entry" \
        "amitbhave@microsoft.com|amitbhave|$amit_entry"

    # Effective = main mailmap concatenated with PR #479's additions.
    write_mailmap "$WORK_DIR/main.mailmap" \
        "# main mailmap (no overlap with this scenario)"
    write_mailmap "$WORK_DIR/pr.mailmap" \
        "Pelong <11+pelong@users.noreply.github.com> <pelong@microsoft.com>"
    cat "$WORK_DIR/main.mailmap" "$WORK_DIR/pr.mailmap" > "$WORK_DIR/eff.mailmap"

    if ! run_merge "$WORK_DIR/detect.json" "$WORK_DIR/eff.mailmap" \
        "$WORK_DIR/out" "$WORK_DIR/err"; then
        fail "T-AMIT" "exit non-zero: $(cat "$WORK_DIR/err")"
        cleanup; return
    fi
    if grep -qF "<pelong@microsoft.com>" "$WORK_DIR/out"; then
        fail "T-AMIT" "should NOT re-emit pelong (already in PR-side mailmap)"
        cleanup; return
    fi
    if ! grep -qF "<amitbhave@microsoft.com>" "$WORK_DIR/out"; then
        fail "T-AMIT" "MUST emit amitbhave — this is the silent-drop regression
output was:
$(cat "$WORK_DIR/out")"
        cleanup; return
    fi
    pass "T-AMIT"
    cleanup
}

# ── Detect-script bug fix (ADO 5356763) ────────────────────────────────────────

# T-EMPTY — Author email of literally "@microsoft.com" (empty local part)
# must be filtered out by detect-unmapped-emails.sh with a stderr warning,
# never producing a placeholder entry with an empty alias.
test_T_EMPTY() {
    run_test "T-EMPTY" "detect-unmapped-emails.sh filters empty-alias internal emails"
    setup_workdir

    local repo="$WORK_DIR/repo"
    git init --initial-branch=main "$repo" >/dev/null 2>&1
    git -C "$repo" config user.name "Init"
    git -C "$repo" config user.email "init@example.com"
    echo "seed" > "$repo/seed.txt"
    git -C "$repo" add seed.txt
    git -C "$repo" commit -m "seed" --quiet

    # Commit with author email "@microsoft.com" — empty local part.
    echo "broken" > "$repo/broken.txt"
    git -C "$repo" add broken.txt
    GIT_AUTHOR_NAME="Empty Alias" GIT_AUTHOR_EMAIL="@microsoft.com" \
    GIT_COMMITTER_NAME="Empty Alias" GIT_COMMITTER_EMAIL="@microsoft.com" \
        git -C "$repo" commit -m "Empty-alias author" --quiet

    # detect-unmapped-emails.sh aborts if the mailmap parses to zero entries,
    # so seed at least one valid mapping unrelated to this test.
    write_mailmap "$WORK_DIR/eff.mailmap" \
        "Filler User <1+filler@users.noreply.github.com> <filler@microsoft.com>"

    set +e
    bash "$DETECT_SCRIPT" \
        --mailmap "$WORK_DIR/eff.mailmap" \
        --repo "$repo" \
        --json \
        > "$WORK_DIR/detect.out" 2> "$WORK_DIR/detect.err"
    local rc=$?
    set -e

    # The empty-alias email must NOT appear in the JSON unmapped list.
    if grep -qE '"alias"[[:space:]]*:[[:space:]]*""' "$WORK_DIR/detect.out"; then
        fail "T-EMPTY" "detect emitted an empty-alias entry into JSON:
$(cat "$WORK_DIR/detect.out")"
        cleanup; return
    fi
    if grep -qF '"email": "@microsoft.com"' "$WORK_DIR/detect.out"; then
        fail "T-EMPTY" "detect emitted '@microsoft.com' (empty local part) into JSON"
        cleanup; return
    fi
    # Stderr should mention the skip / warning so the operator sees why.
    if ! grep -qiE "empty[- ]alias|skip|@microsoft\.com" "$WORK_DIR/detect.err"; then
        fail "T-EMPTY" "expected stderr warning about skipping empty-alias email; got:
$(cat "$WORK_DIR/detect.err")"
        cleanup; return
    fi
    # rc 0 (nothing unmapped) is the right outcome here.
    if [[ $rc -ne 0 ]]; then
        fail "T-EMPTY" "expected exit 0 (no real unmapped emails), got $rc"
        cleanup; return
    fi
    pass "T-EMPTY"
    cleanup
}

# ── Orchestration tests (fake gh) ──────────────────────────────────────────────

# Build a tiny git repo the orchestrator can operate against.
setup_orchestrate_repo() {
    LOCAL_REPO="$WORK_DIR/local"
    REMOTE_REPO="$WORK_DIR/remote.git"
    git init --bare "$REMOTE_REPO" >/dev/null 2>&1
    git init --initial-branch=main "$LOCAL_REPO" >/dev/null 2>&1
    git -C "$LOCAL_REPO" config user.name "Init"
    git -C "$LOCAL_REPO" config user.email "init@example.com"
    mkdir -p "$LOCAL_REPO/.github/scripts" "$LOCAL_REPO/.github/workflows"
    # Seed a tiny mailmap with no relevant entries.
    cat > "$LOCAL_REPO/.github/sync-mailmap" <<'EOF'
# Test mailmap
# ── Vendor accounts ──────────────────────────────────────────────────────────
v-test <0+v-test@users.noreply.github.com> <v-test@microsoft.com>
EOF
    # Add a commit by an unmapped internal author so detect has something to find.
    echo "code" > "$LOCAL_REPO/work.txt"
    git -C "$LOCAL_REPO" add -A
    GIT_AUTHOR_NAME="New Person" GIT_AUTHOR_EMAIL="newperson@microsoft.com" \
    GIT_COMMITTER_NAME="New Person" GIT_COMMITTER_EMAIL="newperson@microsoft.com" \
        git -C "$LOCAL_REPO" commit -m "Add work" --quiet
    git -C "$LOCAL_REPO" remote add origin "$REMOTE_REPO"
    git -C "$LOCAL_REPO" push -u origin main --quiet
}

# Invoke the orchestrator with standard env, capturing logs.
run_orchestrate() {
    local stdout_file="$1"; local stderr_file="$2"
    set +e
    (
        cd "$LOCAL_REPO"
        REPO="test-org/test-repo" \
        GH_TOKEN="fake-token" \
        RUN_URL="https://example.invalid/runs/1" \
        MAILMAP_FILE=".github/sync-mailmap" \
        DRY_RUN=0 \
        bash "$ORCHESTRATE_SCRIPT" \
            > "$stdout_file" 2> "$stderr_file"
    )
    local rc=$?
    set -e
    return $rc
}

# E1 — No open auto-fix PR + new entries detected → orchestrator calls `gh pr create`.
test_E1() {
    run_test "E1" "No open PR + new entries → gh pr create called"
    setup_workdir
    setup_orchestrate_repo
    install_fake_gh

    # Fixture: gh pr list returns no auto-fix PRs.
    echo "[]" > "$FAKE_GH_FIXTURES/pr-list.out"

    if ! run_orchestrate "$WORK_DIR/orch.out" "$WORK_DIR/orch.err"; then
        fail "E1" "orchestrator exit non-zero: $(cat "$WORK_DIR/orch.err")"
        cleanup; return
    fi
    if [[ $(fake_gh_count 'gh pr create') -lt 1 ]]; then
        fail "E1" "expected at least one 'gh pr create' call; log:
$(cat "$FAKE_GH_LOG")"
        cleanup; return
    fi
    if [[ $(fake_gh_count 'gh pr comment') -gt 0 ]]; then
        fail "E1" "should not call 'gh pr comment' when no open PR exists"
        cleanup; return
    fi
    pass "E1"
    cleanup
}

# E2 — Open auto-fix PR exists + new entries → append commit + gh pr comment, no pr create.
test_E2() {
    run_test "E2" "Open PR + new entries → append commit + gh pr comment"
    setup_workdir
    setup_orchestrate_repo
    install_fake_gh

    # Prepare the open PR's branch on the remote with its own (different) mailmap.
    local pr_branch="auto/fix-unmapped-emails-20260601-000000"
    git -C "$LOCAL_REPO" checkout -b "$pr_branch" --quiet
    cat >> "$LOCAL_REPO/.github/sync-mailmap" <<'EOF'

# -- Added by fix-unmapped-emails workflow (2026-06-01) ----
Other Person <77+other@users.noreply.github.com> <other@microsoft.com>
EOF
    git -C "$LOCAL_REPO" add -A
    git -C "$LOCAL_REPO" commit -m "previous auto-fix entry" --quiet
    git -C "$LOCAL_REPO" push -u origin "$pr_branch" --quiet
    git -C "$LOCAL_REPO" checkout main --quiet

    # Fixture: gh pr list returns the existing PR.
    cat > "$FAKE_GH_FIXTURES/pr-list.out" <<EOF
[{"number": 479, "headRefName": "$pr_branch"}]
EOF

    if ! run_orchestrate "$WORK_DIR/orch.out" "$WORK_DIR/orch.err"; then
        fail "E2" "orchestrator exit non-zero: $(cat "$WORK_DIR/orch.err")"
        cleanup; return
    fi
    if [[ $(fake_gh_count 'gh pr create') -gt 0 ]]; then
        fail "E2" "should NOT call 'gh pr create' when an open PR exists"
        cleanup; return
    fi
    if [[ $(fake_gh_count 'gh pr comment') -lt 1 ]]; then
        fail "E2" "expected at least one 'gh pr comment' call; log:
$(cat "$FAKE_GH_LOG")"
        cleanup; return
    fi
    pass "E2"
    cleanup
}

# E3 — Open auto-fix PR exists and already contains every detected unmapped author
# → no pr create, no pr comment, no new commit on the PR branch.
test_E3() {
    run_test "E3" "Open PR + all detected already present → no-op"
    setup_workdir
    setup_orchestrate_repo
    install_fake_gh

    # Open PR already contains newperson@microsoft.com (the one detect would find).
    local pr_branch="auto/fix-unmapped-emails-20260601-000000"
    git -C "$LOCAL_REPO" checkout -b "$pr_branch" --quiet
    cat >> "$LOCAL_REPO/.github/sync-mailmap" <<'EOF'

# -- Added by fix-unmapped-emails workflow (2026-06-01) ----
New Person <99+newperson@users.noreply.github.com> <newperson@microsoft.com>
EOF
    git -C "$LOCAL_REPO" add -A
    git -C "$LOCAL_REPO" commit -m "covers newperson already" --quiet
    git -C "$LOCAL_REPO" push -u origin "$pr_branch" --quiet
    local pr_sha_before
    pr_sha_before=$(git -C "$LOCAL_REPO" rev-parse "$pr_branch")
    git -C "$LOCAL_REPO" checkout main --quiet

    cat > "$FAKE_GH_FIXTURES/pr-list.out" <<EOF
[{"number": 479, "headRefName": "$pr_branch"}]
EOF

    if ! run_orchestrate "$WORK_DIR/orch.out" "$WORK_DIR/orch.err"; then
        fail "E3" "orchestrator exit non-zero: $(cat "$WORK_DIR/orch.err")"
        cleanup; return
    fi
    if [[ $(fake_gh_count 'gh pr create') -gt 0 ]]; then
        fail "E3" "should NOT call 'gh pr create' on a no-op"
        cleanup; return
    fi
    if [[ $(fake_gh_count 'gh pr comment') -gt 0 ]]; then
        fail "E3" "should NOT call 'gh pr comment' on a no-op"
        cleanup; return
    fi
    # PR branch on the remote must be unchanged.
    local pr_sha_after
    pr_sha_after=$(git -C "$REMOTE_REPO" rev-parse "$pr_branch")
    if [[ "$pr_sha_before" != "$pr_sha_after" ]]; then
        fail "E3" "PR branch advanced on no-op: $pr_sha_before → $pr_sha_after"
        cleanup; return
    fi
    pass "E3"
    cleanup
}

# E4 — gh pr list returns garbled (exit-0 but malformed) JSON. The orchestrator
# MUST fail fast with exit 3 ("PR discovery failed") rather than silently
# degrading to prs=[] and creating a duplicate PR. Same threat model as the
# transport-failure exit-3 path landed in 491650fd, but exercising the
# content-validity path.
test_E4() {
    run_test "E4" "Garbled gh pr list JSON → exit 3, no pr create / comment"
    setup_workdir
    setup_orchestrate_repo
    install_fake_gh

    # Fixture: gh pr list emits malformed JSON but still exits 0.
    printf '%s\n' '{"number": 479, "headRef' > "$FAKE_GH_FIXTURES/pr-list.out"

    # OR-list suspends errexit for the call so we can capture the expected
    # non-zero exit. (run_orchestrate re-enables `set -e` before returning,
    # which would otherwise fire the parent script's errexit on a non-zero
    # return — fine for E1–E3 which use `if !`, but not for our rc=3 check.)
    local rc=0
    run_orchestrate "$WORK_DIR/orch.out" "$WORK_DIR/orch.err" || rc=$?

    if [[ $rc -ne 3 ]]; then
        fail "E4" "expected exit 3 (PR discovery failed), got $rc; stderr:
$(cat "$WORK_DIR/orch.err")"
        cleanup; return
    fi
    if [[ $(fake_gh_count 'gh pr create') -gt 0 ]]; then
        fail "E4" "should NOT call 'gh pr create' on garbled JSON; log:
$(cat "$FAKE_GH_LOG")"
        cleanup; return
    fi
    if [[ $(fake_gh_count 'gh pr comment') -gt 0 ]]; then
        fail "E4" "should NOT call 'gh pr comment' on garbled JSON"
        cleanup; return
    fi
    pass "E4"
    cleanup
}

# ── Driver ─────────────────────────────────────────────────────────────────────

trap cleanup EXIT

echo "╔══════════════════════════════════════════════════╗"
echo "║   fix-unmapped-emails test suite                 ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Merge script:        $MERGE_SCRIPT"
echo "Detect script:       $DETECT_SCRIPT"
echo "Orchestrate script:  $ORCHESTRATE_SCRIPT"

# Unit — merge
test_T1
test_T2
test_T3
test_T4
test_T5
test_T6
test_T7
test_T8

# Regression — main scenario
test_T_AMIT

# Detect bug fix
test_T_EMPTY

# Orchestration
test_E1
test_E2
test_E3
test_E4

summary
