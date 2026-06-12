#!/usr/bin/env bash
# fix-unmapped-emails-orchestrate.sh — Drive the auto-fix mailmap flow.
#
# Wraps the detect → merge → append-or-create lifecycle so the orchestration
# is testable with a fake `gh` on PATH (E1–E3 in test-fix-unmapped.sh).
# Called by .github/workflows/fix-unmapped-emails.yml.
#
# Required env:
#   REPO              owner/repo (e.g. microsoft-foundry/foundry-samples-pr)
#   GH_TOKEN          Token for `gh` CLI calls (`gh pr list`, `gh pr create`,
#                     `gh pr comment`). NOT used for `git fetch` — that
#                     authenticates via whatever credentials the `origin`
#                     remote is configured with (CI: the implicit GITHUB_TOKEN
#                     baked into the actions/checkout step's git config;
#                     local: your global git credential helper).
#   RUN_URL           URL of the triggering sync workflow run (for PR body/comment)
# Optional env:
#   MAILMAP_FILE      Path to repo mailmap (default: .github/sync-mailmap)
#   SCAN_RANGE        Git revision range to scan (default: all commits)
#   PR_BRANCH_PREFIX  Prefix for auto-fix branches (default: auto/fix-unmapped-emails-)
#   DRY_RUN           If 1, do not push or call gh write APIs (default: 0)
#   GIT_USER_NAME     Commit author (default: github-actions[bot])
#   GIT_USER_EMAIL    Commit email  (default: github-actions[bot]@users.noreply.github.com)
#   TRIGGER_LABEL     Human-readable trigger description used in PR body / comment
#                     (default: "sync workflow"). The workflow passes a precise
#                     value (e.g. "Sync to Public Repo failure", "manual dispatch").
#
# Behavior (per ADO 5356762):
#   1. Run detect-unmapped-emails.sh against the current HEAD.
#   2. Find an open `${PR_BRANCH_PREFIX}*` PR via `gh pr list`.
#   3. If found, fetch its branch and use its mailmap as the effective baseline
#      (concatenated with main's mailmap to form the dedup set).
#   4. Run merge-mailmap-additions.sh → new entries (vs. effective).
#   5. Empty → exit 0, nothing to do.
#   6. New entries + no open PR → create branch + PR.
#   7. New entries + open PR → append commit (no force-push) + post PR comment.
#
# Exit codes:
#   0  Success (including no-op / nothing-to-add)
#   1  Detect or merge failed unrecoverably; or git fetch / git push failed
#   2  Argument / env error
#   3  PR discovery failed (e.g. `gh pr list` errored — likely transient auth /
#      rate limit). Failing fast here prevents the "no open PR found, create a
#      new one" silent-degrade path that would reintroduce the PR-flood risk
#      this script was written to eliminate. Treat exit 3 as retry-on-next-trigger.

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

MAILMAP_FILE="${MAILMAP_FILE:-.github/sync-mailmap}"
SCAN_RANGE="${SCAN_RANGE:-}"
PR_BRANCH_PREFIX="${PR_BRANCH_PREFIX:-auto/fix-unmapped-emails-}"
DRY_RUN="${DRY_RUN:-0}"
GIT_USER_NAME="${GIT_USER_NAME:-github-actions[bot]}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-github-actions[bot]@users.noreply.github.com}"
REPO="${REPO:-}"
RUN_URL="${RUN_URL:-}"
TRIGGER_LABEL="${TRIGGER_LABEL:-sync workflow}"

if [[ -z "$REPO" ]]; then
    echo "ERROR: REPO env var required (owner/repo)" >&2; exit 2
fi
if [[ ! -f "$MAILMAP_FILE" ]]; then
    echo "ERROR: MAILMAP_FILE not found: $MAILMAP_FILE" >&2; exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT_SCRIPT="$SCRIPT_DIR/detect-unmapped-emails.sh"
MERGE_SCRIPT="$SCRIPT_DIR/merge-mailmap-additions.sh"

WORK_TMP="$(mktemp -d -t fix-unmapped.XXXXXX)"
trap 'rm -rf "$WORK_TMP"' EXIT

# ─── Step 1: detect unmapped emails ──────────────────────────────────────────

ARGS=(--mailmap "$MAILMAP_FILE" --json --resolve)
[[ -n "$SCAN_RANGE" ]] && ARGS+=(--range "$SCAN_RANGE")

set +e
DETECT_OUT=$(bash "$DETECT_SCRIPT" "${ARGS[@]}" 2>"$WORK_TMP/detect.err")
DETECT_RC=$?
set -e
cat "$WORK_TMP/detect.err" >&2 || true

if [[ $DETECT_RC -eq 0 ]]; then
    echo "✅ All internal emails are mapped — nothing to do." >&2
    exit 0
fi
if [[ $DETECT_RC -ne 1 ]]; then
    echo "ERROR: detect-unmapped-emails.sh failed with exit code $DETECT_RC" >&2
    exit 1
fi

printf '%s\n' "$DETECT_OUT" > "$WORK_TMP/detect.json"

# ─── Step 2: find existing open auto-fix PR ──────────────────────────────────
# Use the fixture-friendly `--json number,headRefName` form (no --jq) so the
# orchestrator does its own filtering — keeps E1/E2 tests simple.

EXISTING_PR_NUMBER=""
EXISTING_PR_BRANCH=""

# Capture both stdout and stderr; do NOT swallow errors. A failed `gh pr list`
# (auth, rate limit, transient network) used to silently degrade to "no open
# PR" → create a new PR → reintroduces the PR-flood the dedup logic exists to
# prevent. Fail fast instead and let the next sync-failure trigger retry.
_gh_stderr="$WORK_TMP/gh-pr-list.err"
if ! PR_LIST_RAW=$(gh pr list \
    --repo "$REPO" \
    --state open \
    --limit 100 \
    --json number,headRefName 2>"$_gh_stderr"); then
    echo "FATAL: 'gh pr list' failed — cannot determine whether an open auto-fix PR exists." >&2
    echo "       Refusing to proceed (would risk creating a duplicate PR). Stderr:" >&2
    sed 's/^/         /' "$_gh_stderr" >&2 || true
    exit 3
fi

# gh succeeded but returned nothing (extremely unusual — empty body, exit 0) →
# treat as empty list. Distinct from the error path above.
[[ -z "$PR_LIST_RAW" ]] && PR_LIST_RAW="[]"

EXISTING_PR_NUMBER=""
EXISTING_PR_BRANCH=""

# Parse the PR list. Both transport failures (handled above as exit 3) and
# *content* failures must fail fast — if gh ever returns exit-0 with a
# truncated / garbled body, silently degrading to "no open PR" would cause
# the same duplicate-PR-flood the dedup logic exists to prevent. We capture
# stderr to a temp file so we can surface it on a parse error.
set +e
PR_LOOKUP_OUT=$(printf '%s' "$PR_LIST_RAW" | \
    PR_BRANCH_PREFIX="$PR_BRANCH_PREFIX" python3 -c '
import json, os, sys
prefix = os.environ["PR_BRANCH_PREFIX"]
try:
    prs = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f"FATAL: gh pr list returned invalid JSON: {e}", file=sys.stderr)
    sys.exit(3)
for p in prs:
    name = p.get("headRefName", "")
    if name.startswith(prefix):
        number = p["number"]
        print(f"{number} {name}")
        break
' 2>"$WORK_TMP/pr-lookup.err")
PR_LOOKUP_RC=$?
set -e
if [[ $PR_LOOKUP_RC -ne 0 ]]; then
    echo "FATAL: PR discovery failed — gh pr list output could not be parsed." >&2
    echo "       Refusing to proceed (would risk creating a duplicate PR). Stderr:" >&2
    sed 's/^/         /' "$WORK_TMP/pr-lookup.err" >&2 || true
    exit 3
fi

if [[ -n "$PR_LOOKUP_OUT" ]]; then
    read -r EXISTING_PR_NUMBER EXISTING_PR_BRANCH <<< "$PR_LOOKUP_OUT"
fi

# ─── Step 3: build effective mailmap (main ∪ PR additions if PR exists) ──────

EFFECTIVE_MAILMAP="$MAILMAP_FILE"
if [[ -n "$EXISTING_PR_NUMBER" ]]; then
    echo "Found open auto-fix PR #$EXISTING_PR_NUMBER on branch $EXISTING_PR_BRANCH" >&2
    if ! git fetch origin "$EXISTING_PR_BRANCH" --quiet 2>"$WORK_TMP/fetch.err"; then
        echo "ERROR: failed to fetch PR branch $EXISTING_PR_BRANCH" >&2
        cat "$WORK_TMP/fetch.err" >&2
        exit 1
    fi
    PR_MAILMAP_PATH="$WORK_TMP/pr.mailmap"
    if ! git show "origin/$EXISTING_PR_BRANCH:$MAILMAP_FILE" > "$PR_MAILMAP_PATH" 2>/dev/null; then
        echo "WARN: PR branch has no $MAILMAP_FILE; using main mailmap only" >&2
        : > "$PR_MAILMAP_PATH"
    fi
    EFFECTIVE_MAILMAP="$WORK_TMP/effective.mailmap"
    cat "$MAILMAP_FILE" "$PR_MAILMAP_PATH" > "$EFFECTIVE_MAILMAP"
fi

# ─── Step 4: compute delta ───────────────────────────────────────────────────

NEW_ENTRIES_FILE="$WORK_TMP/new_entries.txt"
bash "$MERGE_SCRIPT" \
    --detect-json "$WORK_TMP/detect.json" \
    --effective-mailmap "$EFFECTIVE_MAILMAP" \
    > "$NEW_ENTRIES_FILE"

if [[ ! -s "$NEW_ENTRIES_FILE" ]]; then
    echo "✅ All detected unmapped emails already present in effective mailmap; nothing to add." >&2
    exit 0
fi

# Count actual emails being added. Each detect entry — whether resolved or
# UNRESOLVED — produces a leading `# VERIFY ...` comment line, so counting
# those gives the right number for both the message and the placeholder-only
# case (where there are no `<...> <...>` mapping lines at all). Using
# `|| true` rather than `|| echo 0`: `grep -c` already prints 0 on no-match;
# the `|| echo 0` form would emit `0\n0` (two lines) and break arithmetic
# comparisons downstream.
NEW_ENTRY_COUNT=$(grep -cE '^# VERIFY' "$NEW_ENTRIES_FILE" || true)
NEW_ENTRY_COUNT="${NEW_ENTRY_COUNT:-0}"
echo "Computed $NEW_ENTRY_COUNT new mailmap entries to add." >&2

# Extract @-mentions from noreply emails for the PR body/comment.
MENTIONS=$(python3 - "$NEW_ENTRIES_FILE" <<'PY'
import re, sys
mentions = []
with open(sys.argv[1]) as f:
    for line in f:
        m = re.search(r"\+([^@]+)@users\.noreply", line)
        if m:
            mentions.append(f"@{m.group(1)}")
print(" ".join(mentions))
PY
)

# ─── Helper: insert new entries before the "Vendor accounts" marker ──────────

insert_entries() {
    # $1 = path to mailmap to edit (in place)
    # $2 = path to file with new entries (one entry, possibly multi-line)
    local target="$1" entries_file="$2"
    HEADER_DATE="$(date -u +%Y-%m-%d)" \
    ENTRIES_FILE="$entries_file" \
    python3 - "$target" <<'PY'
import os, sys
target = sys.argv[1]
header = f"# -- Added by fix-unmapped-emails workflow ({os.environ['HEADER_DATE']}) ----"
with open(os.environ["ENTRIES_FILE"]) as f:
    additions = f.read().rstrip("\n")
with open(target) as f:
    content = f.read()
insert_block = f"{header}\n\n{additions}\n\n"
marker = "Vendor accounts"
if marker in content:
    lines = content.split("\n")
    out = []
    inserted = False
    for line in lines:
        if not inserted and marker in line:
            out.append(insert_block.rstrip("\n"))
            inserted = True
        out.append(line)
    content = "\n".join(out)
else:
    content = content.rstrip("\n") + f"\n\n{insert_block}"
with open(target, "w") as f:
    f.write(content)
PY
}

# ─── Step 6/7: append (existing PR) or create (no PR) ────────────────────────

if [[ -n "$EXISTING_PR_NUMBER" ]]; then
    echo "Appending to existing PR #$EXISTING_PR_NUMBER (no force-push)..." >&2
    git checkout -B "$EXISTING_PR_BRANCH" "origin/$EXISTING_PR_BRANCH" --quiet
    insert_entries "$MAILMAP_FILE" "$NEW_ENTRIES_FILE"
    git add "$MAILMAP_FILE"
    git -c "user.name=$GIT_USER_NAME" -c "user.email=$GIT_USER_EMAIL" \
        commit -m "fix(sync): append $NEW_ENTRY_COUNT unmapped email(s) to sync-mailmap

Triggered by sync run: ${RUN_URL:-unknown}

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" \
        --quiet

    if [[ "$DRY_RUN" != "1" ]]; then
        git push origin "$EXISTING_PR_BRANCH" --quiet
    else
        echo "DRY_RUN=1: would push to origin/$EXISTING_PR_BRANCH" >&2
    fi

    COMMENT_BODY="## 🔧 Appended $NEW_ENTRY_COUNT new mailmap entries

The sync pipeline failed again with **new** unmapped \`@microsoft.com\` authors that weren't already covered by this PR. Entries were appended to this branch (no force-push).

${MENTIONS:+**People to verify:** $MENTIONS}

---
*Triggered by: $TRIGGER_LABEL*
*Run: ${RUN_URL:-unknown}*"

    if [[ "$DRY_RUN" != "1" ]]; then
        gh pr comment "$EXISTING_PR_NUMBER" \
            --repo "$REPO" \
            --body "$COMMENT_BODY" >/dev/null
    else
        echo "DRY_RUN=1: would post comment to PR #$EXISTING_PR_NUMBER" >&2
    fi
    exit 0
fi

# ── Create-new path ──────────────────────────────────────────────────────────

NEW_BRANCH="${PR_BRANCH_PREFIX}$(date -u +%Y%m%d-%H%M%S)"
echo "No open auto-fix PR — creating new branch $NEW_BRANCH" >&2

git checkout -b "$NEW_BRANCH" --quiet
insert_entries "$MAILMAP_FILE" "$NEW_ENTRIES_FILE"
git add "$MAILMAP_FILE"
git -c "user.name=$GIT_USER_NAME" -c "user.email=$GIT_USER_EMAIL" \
    commit -m "fix(sync): add unmapped emails to sync-mailmap

Automated fix for unmapped internal emails detected by the sync pipeline.
Entries marked VERIFY need manual confirmation.

Triggered by sync run: ${RUN_URL:-unknown}

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" \
    --quiet

if [[ "$DRY_RUN" != "1" ]]; then
    git push origin "$NEW_BRANCH" --quiet
else
    echo "DRY_RUN=1: would push origin/$NEW_BRANCH" >&2
fi

PR_BODY="## 🔧 Automated Mailmap Fix

The sync pipeline failed because new \`@microsoft.com\` commit author emails
are not mapped in \`.github/sync-mailmap\`.

This PR adds proposed mappings. **Please verify** the GitHub username is correct
for each entry before approving.

### How to verify
1. Check each \`# VERIFY\` entry
2. Look up the person at [repos.opensource.microsoft.com](https://repos.opensource.microsoft.com/people)
3. Confirm their GitHub username matches the noreply email in the entry

${MENTIONS:+**People to verify:** $MENTIONS}

---
*Triggered by: $TRIGGER_LABEL*
*Run: ${RUN_URL:-unknown}*"

if [[ "$DRY_RUN" != "1" ]]; then
    gh pr create \
        --repo "$REPO" \
        --title "fix(sync): add unmapped emails to sync-mailmap" \
        --body "$PR_BODY" \
        --base main \
        --head "$NEW_BRANCH" >/dev/null
else
    echo "DRY_RUN=1: would gh pr create for $NEW_BRANCH" >&2
fi

exit 0
