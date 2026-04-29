#!/usr/bin/env bash
# .github/scripts/wait-and-merge.sh
#
# Polls a pull request until it is mergeable (no conflicts, no pending checks),
# then merges it directly via `gh pr merge --rebase`.
#
# WHY DIRECT MERGE INSTEAD OF `gh pr merge --auto`:
#   GitHub's auto-merge runs as a system process at merge time, which does NOT
#   inherit the calling app's ruleset bypass. When this script runs from the
#   sync workflow, GH_TOKEN is the foundry-samples-repo-sync app token, so
#   calling `gh pr merge --rebase` directly merges *as the app*, and the app's
#   bypass actor entry on the main branch ruleset applies (including
#   pull_request rule sub-flags like require_last_push_approval and
#   required_approving_review_count).
#   See https://github.com/microsoft-foundry/foundry-samples-pr/issues/195
#
# Args:
#   $1  PR_URL  — full PR URL or number (passed through to gh)
#   $2  REPO    — owner/name of the public repo
#
# Env (with defaults):
#   MERGE_POLL_TIMEOUT   seconds before giving up        (default 600)
#   MERGE_POLL_INTERVAL  seconds between polls           (default 15)
#   GH_TOKEN             required — token with merge permission
#
# Exit codes:
#   0  merged successfully
#   1  conflict / timeout / merge call failed
set -euo pipefail

PR_URL="${1:?PR_URL is required as arg 1}"
REPO="${2:?REPO (owner/name) is required as arg 2}"

TIMEOUT_SECONDS="${MERGE_POLL_TIMEOUT:-600}"
POLL_INTERVAL="${MERGE_POLL_INTERVAL:-15}"
DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))

echo "Polling $PR_URL for mergeability (timeout: ${TIMEOUT_SECONDS}s, interval: ${POLL_INTERVAL}s)..."

while :; do
    if [[ "$(date +%s)" -ge "$DEADLINE" ]]; then
        echo "::error::Timed out waiting for PR to become mergeable after ${TIMEOUT_SECONDS}s."
        gh pr view "$PR_URL" --repo "$REPO" --json mergeable,mergeStateStatus,statusCheckRollup || true
        exit 1
    fi

    VIEW=$(gh pr view "$PR_URL" --repo "$REPO" \
        --json mergeable,mergeStateStatus,statusCheckRollup)

    MERGEABLE=$(echo "$VIEW" | jq -r '.mergeable')
    MERGE_STATE=$(echo "$VIEW" | jq -r '.mergeStateStatus')
    # Count checks still running. Treat empty/missing rollup as 0.
    PENDING=$(echo "$VIEW" | jq '[.statusCheckRollup[]? | select(.status == "PENDING" or .status == "QUEUED" or .status == "IN_PROGRESS")] | length')

    echo "  mergeable=$MERGEABLE mergeStateStatus=$MERGE_STATE pending_checks=$PENDING"

    if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
        echo "::error::PR has merge conflicts. Cannot merge."
        exit 1
    fi

    if [[ "$MERGEABLE" == "MERGEABLE" && "$PENDING" == "0" ]]; then
        echo "PR is mergeable with no pending checks; merging..."
        break
    fi

    sleep "$POLL_INTERVAL"
done

# Direct merge — runs as the app, so the app's ruleset bypass applies.
# Do NOT use --auto here (defeats the whole point of this script) and do NOT
# use --admin (would require the caller to be a bypass actor personally).
gh pr merge "$PR_URL" --repo "$REPO" --rebase
echo "Merged: $PR_URL"
