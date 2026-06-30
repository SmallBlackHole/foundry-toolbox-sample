#!/usr/bin/env bash
# .github/tests/test-mailmap-precheck.sh
#
# Tests for the pre-merge mailmap check (ADO 5399046):
#   - .github/scripts/detect-trailer-leaks.sh        (L1–L7 — pure unit)
#   - .github/scripts/detect-unmapped-emails.sh      (range mode, R1–R4)
#   - .github/scripts/mailmap-precheck-comment.sh    (M1–M4, E1–E3 — with fake gh)
#
# Mirrors the style of test-fix-unmapped.sh: bash helpers, temp-git pattern,
# fake gh on PATH, no framework.
#
# Usage: bash .github/tests/test-mailmap-precheck.sh
# Exit:  0 if all tests pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DETECT_TRAILERS="$REPO_ROOT/.github/scripts/detect-trailer-leaks.sh"
DETECT_UNMAPPED="$REPO_ROOT/.github/scripts/detect-unmapped-emails.sh"
COMMENT_SCRIPT="$REPO_ROOT/.github/scripts/mailmap-precheck-comment.sh"

# ── Test framework (mirrors test-fix-unmapped.sh) ──────────────────────────────

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

WORK_DIR=""

setup_workdir() {
    WORK_DIR="/tmp/test-mailmap-precheck-$$-${TESTS_RUN}"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

# Initialize a temp repo with a seed commit on `main`, return the SHA via stdout.
init_repo_with_seed() {
    local repo="$1"
    git init --initial-branch=main "$repo" >/dev/null 2>&1
    git -C "$repo" config user.name "Init"
    git -C "$repo" config user.email "init@example.com"
    echo "seed" > "$repo/seed.txt"
    git -C "$repo" add seed.txt
    git -C "$repo" commit -m "seed" --quiet
    git -C "$repo" rev-parse HEAD
}

# Make a commit with custom author/committer email and body. Returns the SHA.
make_commit() {
    local repo="$1" file="$2" author_name="$3" author_email="$4" \
          committer_name="$5" committer_email="$6" msg="$7"
    echo "x" > "$repo/$file"
    git -C "$repo" add "$file"
    GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author_email" \
    GIT_COMMITTER_NAME="$committer_name" GIT_COMMITTER_EMAIL="$committer_email" \
        git -C "$repo" commit -m "$msg" --quiet
    git -C "$repo" rev-parse HEAD
}

# ──────────────────────────────────────────────────────────────────────────────
# detect-trailer-leaks.sh — L1 through L6
# ──────────────────────────────────────────────────────────────────────────────

# L1 — Empty range → exit 0.
test_L1() {
    run_test "L1" "detect-trailer-leaks: empty range exits 0"
    setup_workdir
    local repo="$WORK_DIR/repo"
    local seed; seed=$(init_repo_with_seed "$repo")
    set +e
    bash "$DETECT_TRAILERS" --repo "$repo" --range "$seed..$seed" --json --quiet \
        > "$WORK_DIR/out.json" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        fail "L1" "expected exit 0, got $rc; stderr=$(cat "$WORK_DIR/err")"
    elif ! grep -qE '"trailer_leaks":[[:space:]]*\[\]' "$WORK_DIR/out.json"; then
        fail "L1" "expected empty trailer_leaks JSON, got: $(cat "$WORK_DIR/out.json")"
    else
        pass "L1"
    fi
    cleanup
}

# L2 — Clean commit (noreply email in trailer) → exit 0.
test_L2() {
    run_test "L2" "detect-trailer-leaks: clean noreply trailer exits 0"
    setup_workdir
    local repo="$WORK_DIR/repo"
    local seed; seed=$(init_repo_with_seed "$repo")
    make_commit "$repo" "a.txt" \
        "Real Person" "1+real@users.noreply.github.com" \
        "Real Person" "1+real@users.noreply.github.com" \
        "$(printf 'Add a\n\nCo-authored-by: Other <2+other@users.noreply.github.com>')" \
        >/dev/null
    set +e
    bash "$DETECT_TRAILERS" --repo "$repo" --range "$seed..HEAD" --json --quiet \
        > "$WORK_DIR/out.json" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        fail "L2" "expected exit 0, got $rc; out=$(cat "$WORK_DIR/out.json"); err=$(cat "$WORK_DIR/err")"
    else
        pass "L2"
    fi
    cleanup
}

# L3 — Co-authored-by with @microsoft.com → exit 1, findings JSON.
test_L3() {
    run_test "L3" "detect-trailer-leaks: Co-authored-by @microsoft.com fails"
    setup_workdir
    local repo="$WORK_DIR/repo"
    local seed; seed=$(init_repo_with_seed "$repo")
    make_commit "$repo" "a.txt" \
        "Real Person" "1+real@users.noreply.github.com" \
        "Real Person" "1+real@users.noreply.github.com" \
        "$(printf 'Add a\n\nCo-authored-by: Brandon Miller <brandom@microsoft.com>')" \
        >/dev/null
    set +e
    bash "$DETECT_TRAILERS" --repo "$repo" --range "$seed..HEAD" --json --quiet \
        > "$WORK_DIR/out.json" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 1 ]]; then
        fail "L3" "expected exit 1, got $rc; out=$(cat "$WORK_DIR/out.json")"
        cleanup; return
    fi
    if ! grep -q '"email": "brandom@microsoft.com"' "$WORK_DIR/out.json"; then
        fail "L3" "JSON missing brandom@microsoft.com finding: $(cat "$WORK_DIR/out.json")"
        cleanup; return
    fi
    if ! grep -qF 'Co-authored-by' "$WORK_DIR/out.json"; then
        fail "L3" "JSON missing context line: $(cat "$WORK_DIR/out.json")"
        cleanup; return
    fi
    pass "L3"
    cleanup
}

# L4 — Bare @microsoft.com email anywhere in body → exit 1.
test_L4() {
    run_test "L4" "detect-trailer-leaks: bare internal email in body fails"
    setup_workdir
    local repo="$WORK_DIR/repo"
    local seed; seed=$(init_repo_with_seed "$repo")
    make_commit "$repo" "a.txt" \
        "Real Person" "1+real@users.noreply.github.com" \
        "Real Person" "1+real@users.noreply.github.com" \
        "$(printf 'Fix bug\n\nReported by sindhura@microsoft.com')" \
        >/dev/null
    set +e
    bash "$DETECT_TRAILERS" --repo "$repo" --range "$seed..HEAD" --json --quiet \
        > "$WORK_DIR/out.json" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 1 ]]; then
        fail "L4" "expected exit 1, got $rc; out=$(cat "$WORK_DIR/out.json")"
    elif ! grep -q '"email": "sindhura@microsoft.com"' "$WORK_DIR/out.json"; then
        fail "L4" "JSON missing sindhura@microsoft.com finding: $(cat "$WORK_DIR/out.json")"
    else
        pass "L4"
    fi
    cleanup
}

# L5 — External email in body → exit 0 (only @microsoft.com is internal).
test_L5() {
    run_test "L5" "detect-trailer-leaks: external email in body passes"
    setup_workdir
    local repo="$WORK_DIR/repo"
    local seed; seed=$(init_repo_with_seed "$repo")
    make_commit "$repo" "a.txt" \
        "Real Person" "1+real@users.noreply.github.com" \
        "Real Person" "1+real@users.noreply.github.com" \
        "$(printf 'Add a\n\nCo-authored-by: Partner <partner@example.com>')" \
        >/dev/null
    set +e
    bash "$DETECT_TRAILERS" --repo "$repo" --range "$seed..HEAD" --json --quiet \
        > "$WORK_DIR/out.json" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        fail "L5" "expected exit 0 (external email), got $rc; out=$(cat "$WORK_DIR/out.json")"
    else
        pass "L5"
    fi
    cleanup
}

# L6 — Mixed: two commits, one clean, one with leak → exit 1, one finding.
test_L6() {
    run_test "L6" "detect-trailer-leaks: mixed range reports only offending commit"
    setup_workdir
    local repo="$WORK_DIR/repo"
    local seed; seed=$(init_repo_with_seed "$repo")
    make_commit "$repo" "a.txt" \
        "Real Person" "1+real@users.noreply.github.com" \
        "Real Person" "1+real@users.noreply.github.com" \
        "clean commit" \
        >/dev/null
    make_commit "$repo" "b.txt" \
        "Real Person" "1+real@users.noreply.github.com" \
        "Real Person" "1+real@users.noreply.github.com" \
        "$(printf 'leak commit\n\nCo-authored-by: X <leaker@microsoft.com>')" \
        >/dev/null
    set +e
    bash "$DETECT_TRAILERS" --repo "$repo" --range "$seed..HEAD" --json --quiet \
        > "$WORK_DIR/out.json" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 1 ]]; then
        fail "L6" "expected exit 1, got $rc"
        cleanup; return
    fi
    # Should have exactly one finding for leaker@.
    local count
    count=$(python3 -c "import json; print(len(json.load(open('$WORK_DIR/out.json'))['trailer_leaks']))")
    if [[ "$count" != "1" ]]; then
        fail "L6" "expected 1 finding, got $count: $(cat "$WORK_DIR/out.json")"
    elif ! grep -q '"email": "leaker@microsoft.com"' "$WORK_DIR/out.json"; then
        fail "L6" "wrong email in finding: $(cat "$WORK_DIR/out.json")"
    else
        pass "L6"
    fi
    cleanup
}

# L7 — Case-varied internal domain (Alias@Microsoft.COM) → exit 1.
# Email domains are case-insensitive and git trailers are free-form text, so a
# mixed-case domain must still be detected; the reported email is normalized to
# lowercase. Regression guard for the case-sensitive-match bypass.
test_L7() {
    run_test "L7" "detect-trailer-leaks: case-varied @Microsoft.COM fails"
    setup_workdir
    local repo="$WORK_DIR/repo"
    local seed; seed=$(init_repo_with_seed "$repo")
    make_commit "$repo" "a.txt" \
        "Real Person" "1+real@users.noreply.github.com" \
        "Real Person" "1+real@users.noreply.github.com" \
        "$(printf 'Add a\n\nCo-authored-by: Kaylie Leung <Kaylie.Leung@Microsoft.COM>')" \
        >/dev/null
    set +e
    bash "$DETECT_TRAILERS" --repo "$repo" --range "$seed..HEAD" --json --quiet \
        > "$WORK_DIR/out.json" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 1 ]]; then
        fail "L7" "expected exit 1, got $rc; out=$(cat "$WORK_DIR/out.json")"
    elif ! grep -q '"email": "kaylie.leung@microsoft.com"' "$WORK_DIR/out.json"; then
        fail "L7" "JSON missing normalized kaylie.leung@microsoft.com finding: $(cat "$WORK_DIR/out.json")"
    else
        pass "L7"
    fi
    cleanup
}

# ──────────────────────────────────────────────────────────────────────────────
# detect-unmapped-emails.sh — range mode (R1–R4)
# Already covered by T-EMPTY in test-fix-unmapped.sh; here we just verify the
# --range argument behaves correctly with the workflow's commit-range pattern.
# ──────────────────────────────────────────────────────────────────────────────

write_mailmap_basic() {
    local path="$1"
    cat > "$path" <<'EOF'
# Test mailmap
Mapped User <100+mapped@users.noreply.github.com> <mapped@microsoft.com>
EOF
}

# R1 — Range with mapped author/committer → exit 0.
test_R1() {
    run_test "R1" "detect-unmapped --range: mapped author passes"
    setup_workdir
    local repo="$WORK_DIR/repo"
    local seed; seed=$(init_repo_with_seed "$repo")
    write_mailmap_basic "$WORK_DIR/mm"
    make_commit "$repo" "a.txt" \
        "Mapped User" "mapped@microsoft.com" \
        "Mapped User" "mapped@microsoft.com" \
        "Mapped commit" >/dev/null
    set +e
    bash "$DETECT_UNMAPPED" --mailmap "$WORK_DIR/mm" --repo "$repo" \
        --range "$seed..HEAD" --json --quiet \
        > "$WORK_DIR/out.json" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        fail "R1" "expected exit 0, got $rc; out=$(cat "$WORK_DIR/out.json")"
    else
        pass "R1"
    fi
    cleanup
}

# R2 — Range with unmapped author → exit 1.
test_R2() {
    run_test "R2" "detect-unmapped --range: unmapped author fails"
    setup_workdir
    local repo="$WORK_DIR/repo"
    local seed; seed=$(init_repo_with_seed "$repo")
    write_mailmap_basic "$WORK_DIR/mm"
    make_commit "$repo" "a.txt" \
        "New Person" "newperson@microsoft.com" \
        "New Person" "newperson@microsoft.com" \
        "Unmapped commit" >/dev/null
    set +e
    bash "$DETECT_UNMAPPED" --mailmap "$WORK_DIR/mm" --repo "$repo" \
        --range "$seed..HEAD" --json --quiet \
        > "$WORK_DIR/out.json" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 1 ]]; then
        fail "R2" "expected exit 1, got $rc; out=$(cat "$WORK_DIR/out.json")"
    elif ! grep -q '"email": "newperson@microsoft.com"' "$WORK_DIR/out.json"; then
        fail "R2" "JSON missing newperson@microsoft.com: $(cat "$WORK_DIR/out.json")"
    else
        pass "R2"
    fi
    cleanup
}

# R3 — Range with unmapped COMMITTER (author OK) → exit 1.
# Catches the case where someone rebased or amended a commit but kept the
# original author identity. filter-stream.py rewrites both — so we must too.
test_R3() {
    run_test "R3" "detect-unmapped --range: unmapped committer fails even if author mapped"
    setup_workdir
    local repo="$WORK_DIR/repo"
    local seed; seed=$(init_repo_with_seed "$repo")
    write_mailmap_basic "$WORK_DIR/mm"
    make_commit "$repo" "a.txt" \
        "Mapped User" "mapped@microsoft.com" \
        "Rebaser Person" "rebaser@microsoft.com" \
        "Author mapped, committer not" >/dev/null
    set +e
    bash "$DETECT_UNMAPPED" --mailmap "$WORK_DIR/mm" --repo "$repo" \
        --range "$seed..HEAD" --json --quiet \
        > "$WORK_DIR/out.json" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 1 ]]; then
        fail "R3" "expected exit 1, got $rc; out=$(cat "$WORK_DIR/out.json")"
    elif ! grep -q '"email": "rebaser@microsoft.com"' "$WORK_DIR/out.json"; then
        fail "R3" "JSON missing rebaser@microsoft.com: $(cat "$WORK_DIR/out.json")"
    else
        pass "R3"
    fi
    cleanup
}

# R4 — Range with non-microsoft email only → exit 0 (external emails pass).
test_R4() {
    run_test "R4" "detect-unmapped --range: external-only emails pass"
    setup_workdir
    local repo="$WORK_DIR/repo"
    local seed; seed=$(init_repo_with_seed "$repo")
    write_mailmap_basic "$WORK_DIR/mm"
    make_commit "$repo" "a.txt" \
        "Outsider" "outsider@example.com" \
        "Outsider" "outsider@example.com" \
        "External-only commit" >/dev/null
    set +e
    bash "$DETECT_UNMAPPED" --mailmap "$WORK_DIR/mm" --repo "$repo" \
        --range "$seed..HEAD" --json --quiet \
        > "$WORK_DIR/out.json" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        fail "R4" "expected exit 0, got $rc; out=$(cat "$WORK_DIR/out.json")"
    else
        pass "R4"
    fi
    cleanup
}

# ──────────────────────────────────────────────────────────────────────────────
# mailmap-precheck-comment.sh — M1 through M4 (with fake gh)
# ──────────────────────────────────────────────────────────────────────────────

install_fake_gh() {
    local bin_dir="$WORK_DIR/bin"
    mkdir -p "$bin_dir"
    FAKE_GH_LOG="$WORK_DIR/fake-gh.log"
    FAKE_GH_LIST_RESPONSE="$WORK_DIR/fake-gh-list.json"
    FAKE_GH_BODY="$WORK_DIR/last-body.txt"
    : > "$FAKE_GH_LOG"
    : > "$FAKE_GH_BODY"
    # Default: list returns empty array.
    echo '[]' > "$FAKE_GH_LIST_RESPONSE"

    cat > "$bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
# Fake gh — log every call, return canned list for `gh api .../comments`.
{
    printf 'gh'
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
} >> "$FAKE_GH_LOG"

# Capture the body of any create/update call so tests can assert on it.
prev=""
for a in "$@"; do
    if [[ "$prev" == "-F" && "$a" == body=@* ]]; then
        cp "${a#body=@}" "$FAKE_GH_BODY" 2>/dev/null || true
    fi
    prev="$a"
done

# Detect: `gh api --paginate repos/.../issues/<N>/comments --jq ...`
# Return the canned list response (the script then filters via jq).
for a in "$@"; do
    case "$a" in
        */comments)
            # If --jq was passed, simulate jq by emitting matching IDs.
            jq_expr=""
            j=1
            while [[ $j -le $# ]]; do
                if [[ "${!j}" == "--jq" ]]; then
                    k=$((j + 1))
                    jq_expr="${!k}"
                    break
                fi
                j=$((j + 1))
            done
            if [[ -n "$jq_expr" ]]; then
                jq -r "$jq_expr" < "$FAKE_GH_LIST_RESPONSE"
            else
                cat "$FAKE_GH_LIST_RESPONSE"
            fi
            exit 0
            ;;
    esac
done
exit 0
STUB
    chmod +x "$bin_dir/gh"
    export PATH="$bin_dir:$PATH"
    export FAKE_GH_LOG FAKE_GH_LIST_RESPONSE FAKE_GH_BODY
}

write_unmapped_json() {
    local path="$1"; shift
    # Each arg is an email to add as an unmapped entry.
    python3 - "$path" "$@" <<'PY'
import json, sys
path = sys.argv[1]
items = [{"email": e, "alias": e.split("@", 1)[0], "suggested_entry": ""} for e in sys.argv[2:]]
with open(path, "w") as f:
    json.dump({"unmapped": items}, f)
PY
}

write_trailers_json() {
    local path="$1"; shift
    python3 - "$path" "$@" <<'PY'
import json, sys
path = sys.argv[1]
items = []
for raw in sys.argv[2:]:
    sha, line, email = raw.split("|", 2)
    items.append({"commit": sha, "line": line, "email": email})
with open(path, "w") as f:
    json.dump({"trailer_leaks": items}, f)
PY
}

# M1 — No prior comment + no findings → no API write (just list).
test_M1() {
    run_test "M1" "comment: no prior, no findings → no write"
    setup_workdir
    install_fake_gh
    write_unmapped_json "$WORK_DIR/unmapped.json"
    write_trailers_json "$WORK_DIR/trailers.json"
    set +e
    bash "$COMMENT_SCRIPT" \
        --pr 42 --repo "owner/repo" \
        --unmapped-json "$WORK_DIR/unmapped.json" \
        --trailers-json "$WORK_DIR/trailers.json" \
        > "$WORK_DIR/out" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        fail "M1" "expected exit 0, got $rc; err=$(cat "$WORK_DIR/err")"
    elif grep -qE 'POST|PATCH' "$FAKE_GH_LOG"; then
        fail "M1" "expected no POST/PATCH call; log=$(cat "$FAKE_GH_LOG")"
    else
        pass "M1"
    fi
    cleanup
}

# M2 — No prior comment + findings → POST new comment.
test_M2() {
    run_test "M2" "comment: no prior, with findings → POST"
    setup_workdir
    install_fake_gh
    write_unmapped_json "$WORK_DIR/unmapped.json" "newperson@microsoft.com"
    write_trailers_json "$WORK_DIR/trailers.json"
    set +e
    bash "$COMMENT_SCRIPT" \
        --pr 42 --repo "owner/repo" \
        --unmapped-json "$WORK_DIR/unmapped.json" \
        --trailers-json "$WORK_DIR/trailers.json" \
        > "$WORK_DIR/out" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        fail "M2" "expected exit 0, got $rc; err=$(cat "$WORK_DIR/err")"
    elif ! grep -qE 'method.*POST.*issues/42/comments' "$FAKE_GH_LOG"; then
        fail "M2" "expected POST to issues/42/comments; log=$(cat "$FAKE_GH_LOG")"
    elif grep -qE 'PATCH' "$FAKE_GH_LOG"; then
        fail "M2" "should not have PATCHed when no prior comment; log=$(cat "$FAKE_GH_LOG")"
    else
        pass "M2"
    fi
    cleanup
}

# M3 — Existing comment + new findings → PATCH.
test_M3() {
    run_test "M3" "comment: prior comment + findings → PATCH existing"
    setup_workdir
    install_fake_gh
    # Seed list response with one comment carrying our marker.
    cat > "$FAKE_GH_LIST_RESPONSE" <<'EOF'
[
  {"id": 9001, "body": "<!-- sync-mailmap-check -->\n### Old failure"}
]
EOF
    write_unmapped_json "$WORK_DIR/unmapped.json" "newperson@microsoft.com"
    write_trailers_json "$WORK_DIR/trailers.json"
    set +e
    bash "$COMMENT_SCRIPT" \
        --pr 42 --repo "owner/repo" \
        --unmapped-json "$WORK_DIR/unmapped.json" \
        --trailers-json "$WORK_DIR/trailers.json" \
        > "$WORK_DIR/out" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        fail "M3" "expected exit 0, got $rc; err=$(cat "$WORK_DIR/err")"
    elif ! grep -qE 'PATCH.*issues/comments/9001' "$FAKE_GH_LOG"; then
        fail "M3" "expected PATCH to comments/9001; log=$(cat "$FAKE_GH_LOG")"
    elif grep -qE 'method.*POST.*issues/42/comments' "$FAKE_GH_LOG"; then
        fail "M3" "should not have POSTed when prior comment exists; log=$(cat "$FAKE_GH_LOG")"
    else
        pass "M3"
    fi
    cleanup
}

# M4 — Existing comment + cleared findings → PATCH to "all clear".
test_M4() {
    run_test "M4" "comment: prior comment + cleared findings → PATCH to all-clear"
    setup_workdir
    install_fake_gh
    cat > "$FAKE_GH_LIST_RESPONSE" <<'EOF'
[
  {"id": 9001, "body": "<!-- sync-mailmap-check -->\n### Old failure"}
]
EOF
    write_unmapped_json "$WORK_DIR/unmapped.json"
    write_trailers_json "$WORK_DIR/trailers.json"
    set +e
    bash "$COMMENT_SCRIPT" \
        --pr 42 --repo "owner/repo" \
        --unmapped-json "$WORK_DIR/unmapped.json" \
        --trailers-json "$WORK_DIR/trailers.json" \
        > "$WORK_DIR/out" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        fail "M4" "expected exit 0, got $rc; err=$(cat "$WORK_DIR/err")"
    elif ! grep -qE 'PATCH.*issues/comments/9001' "$FAKE_GH_LOG"; then
        fail "M4" "expected PATCH to comments/9001; log=$(cat "$FAKE_GH_LOG")"
    else
        pass "M4"
    fi
    cleanup
}

# ──────────────────────────────────────────────────────────────────────────────
# mailmap-precheck-comment.sh — E1 through E3 (internal-error handling)
#
# Missing / empty / invalid detector JSON must NOT render "all clear". The
# comment manager must treat it as an internal error and still create-or-update
# the marker comment with a body that says the check could not run. Guards the
# exact bug the reviewer flagged: an empty .precheck/*.json (e.g. a detector
# that aborted after stdout was truncated) silently mapping to a green comment.
# ──────────────────────────────────────────────────────────────────────────────

# E1 — Missing detector JSON + no prior comment → POST internal-error (not all-clear).
test_E1() {
    run_test "E1" "comment: missing JSON → POST internal-error (not all-clear)"
    setup_workdir
    install_fake_gh
    # unmapped.json intentionally absent; trailers present-and-clean.
    write_trailers_json "$WORK_DIR/trailers.json"
    set +e
    bash "$COMMENT_SCRIPT" \
        --pr 42 --repo "owner/repo" \
        --unmapped-json "$WORK_DIR/unmapped.json" \
        --trailers-json "$WORK_DIR/trailers.json" \
        > "$WORK_DIR/out" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        fail "E1" "expected exit 0, got $rc; err=$(cat "$WORK_DIR/err")"
    elif ! grep -qE 'method.*POST.*issues/42/comments' "$FAKE_GH_LOG"; then
        fail "E1" "expected POST for internal error; log=$(cat "$FAKE_GH_LOG")"
    elif ! grep -q 'could not run' "$FAKE_GH_BODY"; then
        fail "E1" "body should be internal-error; body=$(cat "$FAKE_GH_BODY")"
    elif grep -q 'all clear' "$FAKE_GH_BODY"; then
        fail "E1" "body wrongly rendered all-clear; body=$(cat "$FAKE_GH_BODY")"
    else
        pass "E1"
    fi
    cleanup
}

# E2 — Invalid JSON + no prior comment → POST internal-error.
test_E2() {
    run_test "E2" "comment: invalid JSON → POST internal-error"
    setup_workdir
    install_fake_gh
    printf 'this is not json {{{' > "$WORK_DIR/unmapped.json"
    write_trailers_json "$WORK_DIR/trailers.json"
    set +e
    bash "$COMMENT_SCRIPT" \
        --pr 42 --repo "owner/repo" \
        --unmapped-json "$WORK_DIR/unmapped.json" \
        --trailers-json "$WORK_DIR/trailers.json" \
        > "$WORK_DIR/out" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        fail "E2" "expected exit 0, got $rc; err=$(cat "$WORK_DIR/err")"
    elif ! grep -qE 'method.*POST.*issues/42/comments' "$FAKE_GH_LOG"; then
        fail "E2" "expected POST for internal error; log=$(cat "$FAKE_GH_LOG")"
    elif ! grep -q 'could not run' "$FAKE_GH_BODY"; then
        fail "E2" "body should be internal-error; body=$(cat "$FAKE_GH_BODY")"
    else
        pass "E2"
    fi
    cleanup
}

# E3 — Empty JSON file + existing comment → PATCH to internal-error (never leave stale all-clear/❌).
test_E3() {
    run_test "E3" "comment: empty JSON + prior comment → PATCH to internal-error"
    setup_workdir
    install_fake_gh
    cat > "$FAKE_GH_LIST_RESPONSE" <<'EOF'
[
  {"id": 9001, "body": "<!-- sync-mailmap-check -->\n### Old failure"}
]
EOF
    : > "$WORK_DIR/unmapped.json"           # zero-byte file
    write_trailers_json "$WORK_DIR/trailers.json"
    set +e
    bash "$COMMENT_SCRIPT" \
        --pr 42 --repo "owner/repo" \
        --unmapped-json "$WORK_DIR/unmapped.json" \
        --trailers-json "$WORK_DIR/trailers.json" \
        > "$WORK_DIR/out" 2> "$WORK_DIR/err"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        fail "E3" "expected exit 0, got $rc; err=$(cat "$WORK_DIR/err")"
    elif ! grep -qE 'PATCH.*issues/comments/9001' "$FAKE_GH_LOG"; then
        fail "E3" "expected PATCH to comments/9001; log=$(cat "$FAKE_GH_LOG")"
    elif ! grep -q 'could not run' "$FAKE_GH_BODY"; then
        fail "E3" "body should be internal-error; body=$(cat "$FAKE_GH_BODY")"
    else
        pass "E3"
    fi
    cleanup
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

echo "════════════════════════════════════════════════════"
echo "  Mailmap pre-check test suite"
echo "════════════════════════════════════════════════════"

# Pre-flight: scripts must exist.
for s in "$DETECT_TRAILERS" "$DETECT_UNMAPPED" "$COMMENT_SCRIPT"; do
    if [[ ! -f "$s" ]]; then
        echo "ERROR: missing script: $s" >&2
        exit 1
    fi
done

# Pre-flight: jq must be installed (fake gh uses it). Skip M tests if not.
HAS_JQ=1
if ! command -v jq &>/dev/null; then
    echo "WARN: jq not available — skipping comment-manager tests (M1–M4)." >&2
    HAS_JQ=0
fi

test_L1
test_L2
test_L3
test_L4
test_L5
test_L6
test_L7

test_R1
test_R2
test_R3
test_R4

if [[ $HAS_JQ -eq 1 ]]; then
    test_M1
    test_M2
    test_M3
    test_M4
    test_E1
    test_E2
    test_E3
fi

summary
