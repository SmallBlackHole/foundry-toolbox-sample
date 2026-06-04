#!/usr/bin/env bash
# .github/tests/test-mirror-back.sh
#
# Local tests for the public→private mirror helper. The tests use only local git
# repositories and a stubbed gh executable; no network tokens are required.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MIRROR_SCRIPT="$REPO_ROOT/public-overlay/.github/scripts/mirror-back.sh"
WORK_ROOT="$SCRIPT_DIR/.mirror-back-work"

TESTS_RUN=0
TESTS_FAILED=0
FAILURES=()

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo "── MB$TESTS_RUN: $1 ──"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("$1")
    echo "  ❌ FAIL: $1"
}

pass() {
    echo "  ✅ PASS: $1"
}

summary() {
    echo ""
    echo "Tests run: $TESTS_RUN | Failed: $TESTS_FAILED"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        printf '  • %s\n' "${FAILURES[@]}"
        exit 1
    fi
}

cleanup() {
    rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

setup_pair() {
    cleanup
    mkdir -p "$WORK_ROOT/bin"
    PUBLIC="$WORK_ROOT/public"
    PRIVATE="$WORK_ROOT/private"
    GH_LOG="$WORK_ROOT/gh.log"
    GH_PR_LIST_JSON="$WORK_ROOT/pr-list.json"
    printf '[]\n' > "$GH_PR_LIST_JSON"

    git init --initial-branch=main "$PUBLIC" >/dev/null 2>&1
    git init --initial-branch=main "$PRIVATE" >/dev/null 2>&1
    for repo in "$PUBLIC" "$PRIVATE"; do
        git -C "$repo" config user.name "Test Runner"
        git -C "$repo" config user.email "test@example.com"
        echo "base" > "$repo/file.txt"
        git -C "$repo" add file.txt
        git -C "$repo" commit -m "Initial baseline" --quiet
    done

    cat > "$WORK_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${GH_LOG:?GH_LOG is required}"
echo "gh $*" >> "$GH_LOG"
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    for arg in "$@"; do
        if [[ "$arg" == "--head" ]]; then
            printf '%s\n' "${GH_HEAD_JSON:-[]}"
            exit 0
        fi
        if [[ "$arg" == "--search" ]]; then
            cat "${GH_PR_LIST_JSON:?GH_PR_LIST_JSON is required}"
            exit 0
        fi
    done
    cat "${GH_PR_LIST_JSON:?GH_PR_LIST_JSON is required}"
    exit 0
fi
if [[ "$1" == "api" ]]; then
    echo '[{"number":745,"title":"Updating naming","html_url":"https://github.com/brandom-test/mirror-fixture-public/pull/745"}]'
    exit 0
fi
if [[ "$1" == "pr" && "$2" == "create" ]]; then
    echo "https://github.com/brandom-test/mirror-fixture-private/pull/1"
    exit 0
fi
if [[ "$1" == "pr" && "$2" == "edit" ]]; then
    exit 0
fi
if [[ "$1" == "issue" && "$2" == "create" ]]; then
    echo "https://github.com/brandom-test/mirror-fixture-private/issues/1"
    exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 2
STUB
    chmod +x "$WORK_ROOT/bin/gh"
}

commit_public() {
    local name="$1" email="$2" subject="$3" content="$4"
    echo "$content" > "$PUBLIC/file.txt"
    git -C "$PUBLIC" add file.txt
    GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" \
    GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
        git -C "$PUBLIC" commit -m "$subject" --quiet
    git -C "$PUBLIC" rev-parse HEAD
}

run_mirror() {
    env \
        PATH="$WORK_ROOT/bin:$PATH" \
        GH_LOG="$GH_LOG" \
        GH_PR_LIST_JSON="$GH_PR_LIST_JSON" \
        PUBLIC_REPO_PATH="$PUBLIC" \
        PRIVATE_REPO_PATH="$PRIVATE" \
        PUBLIC_REPO="brandom-test/mirror-fixture-public" \
        PRIVATE_REPO="brandom-test/mirror-fixture-private" \
        MIRROR_SKIP_PUSH=1 \
        bash "$MIRROR_SCRIPT" "$@"
}

test_clean_replay() {
    run_test "clean replay opens a private PR branch with preserved author"
    setup_pair
    local sha short branch
    sha=$(commit_public "Alice Example" "123+alice@users.noreply.github.com" "Add public change" "from public")
    short="${sha:0:8}"

    PUBLIC_SHA="$sha" DRY_RUN=0 run_mirror
    branch=$(git -C "$PRIVATE" branch --format='%(refname:short)' | grep "mirror/public-$short")

    [[ -n "$branch" ]] || { fail "mirror branch was not created"; return; }
    [[ "$(git -C "$PRIVATE" show "$branch:file.txt")" == "from public" ]] || { fail "private branch did not contain replayed content"; return; }
    [[ "$(git -C "$PRIVATE" log -1 --format='%an <%ae>' "$branch")" == "Alice Example <123+alice@users.noreply.github.com>" ]] || { fail "replay commit author was not preserved"; return; }
    grep -q -- '--label public-mirror' "$GH_LOG" || { fail "PR was not labeled public-mirror"; return; }
    grep -q "Mirror: Updating naming (foundry-samples@$short)" "$GH_LOG" || { fail "PR title did not use public PR title"; return; }
    pass "clean replay"
}

test_bot_skip() {
    run_test "sync bot commits are skipped to prevent mirror loops"
    setup_pair
    local sha
    sha=$(commit_public "foundry-samples-sync[bot]" "foundry-samples-sync[bot]@users.noreply.github.com" "Automated sync" "bot change")
    PUBLIC_SHA="$sha" DRY_RUN=0 run_mirror
    if git -C "$PRIVATE" branch --format='%(refname:short)' | grep -q '^mirror/'; then
        fail "bot-authored commit created a mirror branch"
        return
    fi
    pass "bot skip"
}

test_idempotency_marker() {
    run_test "existing PR body marker skips replay even when closed"
    setup_pair
    local sha
    sha=$(commit_public "Alice Example" "123+alice@users.noreply.github.com" "Add public change" "from public")
    cat > "$GH_PR_LIST_JSON" <<JSON
[{"headRefName":"some/closed-branch","body":"Already handled <!-- public-mirror-sha:$sha -->"}]
JSON
    PUBLIC_SHA="$sha" DRY_RUN=0 run_mirror
    if git -C "$PRIVATE" branch --format='%(refname:short)' | grep -q '^mirror/'; then
        fail "existing body marker did not suppress replay"
        return
    fi
    pass "idempotency marker"
}

test_dry_run() {
    run_test "dry-run prints the proposed PR body and makes no branch"
    setup_pair
    local sha output
    sha=$(commit_public "Alice Example" "123+alice@users.noreply.github.com" "Add public change" "from public")
    output=$(PUBLIC_SHA="$sha" DRY_RUN=1 run_mirror)
    echo "$output" | grep -q "public-mirror-sha:$sha" || { fail "dry-run output omitted marker"; return; }
    if git -C "$PRIVATE" branch --format='%(refname:short)' | grep -q '^mirror/'; then
        fail "dry-run created a branch"
        return
    fi
    pass "dry-run"
}

test_zero_before_replays_after_only() {
    run_test "push event with zero before SHA replays the after commit only"
    setup_pair
    local sha zero short
    sha=$(commit_public "Alice Example" "123+alice@users.noreply.github.com" "Add public change" "from public")
    short="${sha:0:8}"
    zero="0000000000000000000000000000000000000000"
    BEFORE_SHA="$zero" AFTER_SHA="$sha" DRY_RUN=0 run_mirror
    git -C "$PRIVATE" branch --format='%(refname:short)' | grep -q "mirror/public-$short" || { fail "zero-before push did not replay after commit"; return; }
    pass "zero before"
}

test_slug_and_assignee_helpers() {
    run_test "slugging and noreply login extraction are deterministic"
    local slug assignee
    slug=$(bash "$MIRROR_SCRIPT" --slug "Updating naming: Foundry AI/Teammate → Autopilot Agent!!!")
    assignee=$(bash "$MIRROR_SCRIPT" --assignee-from-email "42854725+brandom-msft@users.noreply.github.com")
    [[ "$slug" == "updating-naming-foundry-ai-teammate-autopilot-agent" ]] || { fail "unexpected slug: $slug"; return; }
    [[ "$assignee" == "brandom-msft" ]] || { fail "unexpected assignee: $assignee"; return; }
    pass "helpers"
}

test_conflict_creates_draft_and_issue() {
    run_test "conflicting replay creates a draft PR and private triage issue"
    setup_pair
    echo "private divergent" > "$PRIVATE/file.txt"
    git -C "$PRIVATE" add file.txt
    git -C "$PRIVATE" commit -m "Diverge privately" --quiet
    local sha
    sha=$(commit_public "Alice Example" "123+alice@users.noreply.github.com" "Conflicting public change" "public divergent")

    PUBLIC_SHA="$sha" DRY_RUN=0 run_mirror || true
    grep -q -- '--draft' "$GH_LOG" || { fail "conflict PR was not draft"; return; }
    grep -q "issue create" "$GH_LOG" || { fail "conflict did not create tracking issue"; return; }
    grep -q -- '--assignee alice' "$GH_LOG" || { fail "conflict PR was not assigned to noreply login"; return; }
    pass "conflict handling"
}

test_clean_replay_without_local_git_identity() {
    run_test "clean replay succeeds when private repo has no local git identity (CI runner case)"
    setup_pair
    local sha short branch committer
    sha=$(commit_public "Alice Example" "123+alice@users.noreply.github.com" "Add public change" "from public")
    short="${sha:0:8}"

    # Strip the identity that setup_pair seeded so git am must rely on env vars
    # set by the script. Mirrors a fresh GitHub Actions runner with no
    # preconfigured user.name/user.email.
    git -C "$PRIVATE" config --unset user.name
    git -C "$PRIVATE" config --unset user.email

    PUBLIC_SHA="$sha" DRY_RUN=0 run_mirror
    branch=$(git -C "$PRIVATE" branch --format='%(refname:short)' | grep "mirror/public-$short")

    [[ -n "$branch" ]] || { fail "mirror branch was not created without local git identity"; return; }
    committer=$(git -C "$PRIVATE" log -1 --format='%cn <%ce>' "$branch")
    [[ "$committer" == "foundry-samples-repo-sync[bot] <foundry-samples-repo-sync[bot]@users.noreply.github.com>" ]] \
        || { fail "committer was not set to sync bot identity: $committer"; return; }
    pass "clean replay without local git identity"
}

test_clean_replay
test_clean_replay_without_local_git_identity
test_bot_skip
test_idempotency_marker
test_dry_run
test_zero_before_replays_after_only
test_slug_and_assignee_helpers
test_conflict_creates_draft_and_issue
summary
