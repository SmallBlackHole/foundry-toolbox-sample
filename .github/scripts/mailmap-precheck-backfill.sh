#!/usr/bin/env bash
# mailmap-precheck-backfill.sh — one-time backfill that finds open PRs lacking
# "Check author/committer/trailer emails" on their current head SHA and posts a
# notice comment + label so contributors know to trigger the pre-check.
#
# Usage:
#   mailmap-precheck-backfill.sh [OPTIONS]
#
# Options:
#   --dry-run              Print actions without executing any mutations
#   --cutoff-date DATE     Ignore PRs created on/after DATE (default: 2026-06-29)
#   --include-drafts       Include draft PRs (default: skip drafts)
#   --pr NUMBER            Process only this single PR number (for targeted testing)
#
# Environment:
#   REPO    owner/repo (defaults to current repo via `gh repo view`)
#   GH_TOKEN  must be set with pull-requests:write and issues:write
#
# Exit codes:
#   0  Completed (including dry-run)
#   1  Unrecoverable error

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────

# Must match the job name in mailmap-precheck.yml exactly.
readonly CHECK_NAME="Check author/committer/trailer emails"
# URL-encoded for use in the GitHub API query parameter (?check_name=...).
# Spaces → %20, forward slashes → %2F.
readonly CHECK_NAME_ENCODED="Check%20author%2Fcommitter%2Ftrailer%20emails"

readonly LABEL_NAME="mailmap-precheck-pending"
readonly LABEL_COLOR="e4e669"
readonly LABEL_DESC="Mailmap pre-check has not yet run on this PR's current head commit"
# Unique marker — distinct from <!-- sync-mailmap-check --> used by the normal
# precheck workflow — so the two comment threads don't collide.
readonly MARKER="<!-- mailmap-precheck-backfill -->"

# ─── Defaults ─────────────────────────────────────────────────────────────────

DRY_RUN=0
CUTOFF_DATE="2026-06-29"
INCLUDE_DRAFTS=0
SINGLE_PR=""

# ─── Argument parsing ─────────────────────────────────────────────────────────

_require_arg() {
    if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
        echo "ERROR: $1 requires a value" >&2; exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=1; shift ;;
        --cutoff-date)    _require_arg "$1" "${2:-}"; CUTOFF_DATE="$2"; shift 2 ;;
        --include-drafts) INCLUDE_DRAFTS=1; shift ;;
        --pr)             _require_arg "$1" "${2:-}"; SINGLE_PR="$2"; shift 2 ;;
        -h|--help)        grep '^#' "$0" | sed 's/^# \?//' | sed -n '1,18p'; exit 0 ;;
        *)                echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ─── Prerequisites ────────────────────────────────────────────────────────────

if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI not on PATH" >&2; exit 1
fi
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq not on PATH" >&2; exit 1
fi

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"
if [[ -z "$REPO" ]]; then
    echo "ERROR: REPO not set and could not be inferred from current directory" >&2; exit 1
fi

echo "=== Mailmap precheck backfill ===" >&2
echo "    repo:         $REPO" >&2
echo "    cutoff date:  $CUTOFF_DATE (skip PRs opened on/after this date)" >&2
echo "    include drafts: $INCLUDE_DRAFTS" >&2
if [[ -n "$SINGLE_PR" ]]; then
    echo "    mode:         single PR (#$SINGLE_PR)" >&2
else
    echo "    mode:         all open PRs" >&2
fi
if [[ $DRY_RUN -eq 1 ]]; then
    echo "    DRY RUN — no mutations will be made" >&2
fi
echo "" >&2

# ─── Ensure label exists ──────────────────────────────────────────────────────

ensure_label() {
    local existing
    existing=$(gh api "repos/$REPO/labels?per_page=100" --paginate \
        --jq ".[] | select(.name == \"$LABEL_NAME\") | .name" 2>/dev/null | head -n1 || true)

    if [[ -n "$existing" ]]; then
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY RUN] would create label '$LABEL_NAME'" >&2
        return 0
    fi

    gh api --method POST "repos/$REPO/labels" \
        -F name="$LABEL_NAME" \
        -F color="$LABEL_COLOR" \
        -F description="$LABEL_DESC" > /dev/null
    echo "Created label '$LABEL_NAME'" >&2
}

# ─── Check if "Check author/committer/trailer emails" has run on a given SHA ──

has_check_run_on_sha() {
    local head_sha="$1"
    # Use total_count with per_page=1 for an efficient existence check.
    # The check_name filter is server-side for accuracy.
    local total_count
    total_count=$(gh api \
        "repos/$REPO/commits/$head_sha/check-runs?check_name=${CHECK_NAME_ENCODED}&per_page=1" \
        --jq ".total_count" 2>/dev/null || echo "0")
    [[ "${total_count:-0}" -gt 0 ]]
}

# ─── Post or update the idempotent backfill notice comment ────────────────────

# The MARKER in this heredoc must stay in sync with the MARKER constant above.
read -r -d '' COMMENT_BODY <<'COMMENT' || true
<!-- mailmap-precheck-backfill -->
### ⚠️ Mailmap pre-check has not run on this PR

This PR was opened before the mailmap pre-check workflow was added on
2026-06-29. The check **has never run** on the current state of this branch —
an unmapped internal `@microsoft.com` email could slip through to the public
sync if this merged as-is.

**What to do:**

Push any commit to this branch to trigger the check automatically.
A no-op commit works fine:

```bash
git commit --allow-empty -m "trigger mailmap precheck"
git push
```

If this is a **fork PR** and you do not have direct push access, ask a
maintainer to run the `Mailmap Pre-check` workflow manually on your branch,
or rebase against `main` to trigger the `synchronize` event.

Once the check runs, this comment remains as an audit trail. The
`mailmap-precheck-pending` label is removed automatically when the check
passes clean.

_This is a one-time backfill notice for PRs that predate the June 2026
rollout. PRs opened after 2026-06-29 are not affected._
COMMENT

post_or_update_comment() {
    local pr_num="$1"

    # Find existing backfill comment (take first match across all pages).
    # Use the same head-n1 trick as mailmap-precheck-comment.sh to avoid
    # SIGPIPE under set -o pipefail from a greedy grep cutting the pipe early.
    local existing_id
    existing_id=$(gh api --paginate "repos/$REPO/issues/$pr_num/comments?per_page=100" \
        --jq ".[] | select(.body | contains(\"$MARKER\")) | .id" 2>/dev/null || true)
    existing_id="${existing_id%%$'\n'*}"

    local body_file
    body_file="$(mktemp)"
    printf '%s\n' "$COMMENT_BODY" > "$body_file"

    if [[ -n "$existing_id" ]]; then
        gh api --method PATCH "repos/$REPO/issues/comments/$existing_id" \
            -F body=@"$body_file" > /dev/null
        echo "    Updated existing backfill comment ($existing_id) on PR #$pr_num" >&2
    else
        gh api --method POST "repos/$REPO/issues/$pr_num/comments" \
            -F body=@"$body_file" > /dev/null
        echo "    Posted backfill comment on PR #$pr_num" >&2
    fi

    rm -f "$body_file"
}

add_label_to_pr() {
    local pr_num="$1"
    # POST /issues/:number/labels is idempotent — no-ops if label already present.
    gh api --method POST "repos/$REPO/issues/$pr_num/labels" \
        -F "labels[]=$LABEL_NAME" > /dev/null
    echo "    Added label '$LABEL_NAME' to PR #$pr_num" >&2
}

# ─── Fetch PRs (single or paginated) ─────────────────────────────────────────

fetch_prs() {
    if [[ -n "$SINGLE_PR" ]]; then
        gh api "repos/$REPO/pulls/$SINGLE_PR" \
            --jq '{number: .number, title: .title, created_at: .created_at, draft: .draft, head_sha: .head.sha}'
    else
        gh api --paginate "repos/$REPO/pulls?state=open&per_page=100" \
            --jq '.[] | {number: .number, title: .title, created_at: .created_at, draft: .draft, head_sha: .head.sha}'
    fi
}

# ─── Main loop ────────────────────────────────────────────────────────────────

total=0
skipped_date=0
skipped_draft=0
skipped_has_check=0
notified=0

ensure_label

while IFS= read -r pr_json; do
    pr_num=$(jq -r '.number'     <<< "$pr_json")
    pr_title=$(jq -r '.title'    <<< "$pr_json")
    pr_created=$(jq -r '.created_at' <<< "$pr_json")
    pr_draft=$(jq -r '.draft'    <<< "$pr_json")
    head_sha=$(jq -r '.head_sha' <<< "$pr_json")

    total=$((total + 1))
    pr_date="${pr_created:0:10}"  # Extract YYYY-MM-DD for date comparison

    # Skip PRs opened on/after the cutoff date.
    # The head-SHA check below is the real guard; this is a fast-path skip for
    # PRs that definitely had the check fire on a subsequent push.
    if [[ "$pr_date" > "$CUTOFF_DATE" || "$pr_date" == "$CUTOFF_DATE" ]]; then
        echo "SKIP   #$pr_num [$pr_date >= $CUTOFF_DATE] $pr_title" >&2
        skipped_date=$((skipped_date + 1))
        continue
    fi

    # Skip drafts unless --include-drafts.
    if [[ "$pr_draft" == "true" && $INCLUDE_DRAFTS -eq 0 ]]; then
        echo "SKIP   #$pr_num [draft] $pr_title" >&2
        skipped_draft=$((skipped_draft + 1))
        continue
    fi

    # Skip if the check has already run on the current head SHA.
    if has_check_run_on_sha "$head_sha"; then
        echo "SKIP   #$pr_num [check present on ${head_sha:0:8}] $pr_title" >&2
        skipped_has_check=$((skipped_has_check + 1))
        continue
    fi

    echo "NOTIFY #$pr_num [$pr_date, head=${head_sha:0:8}] $pr_title" >&2

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "    [DRY RUN] would add label + post/update comment" >&2
    else
        add_label_to_pr "$pr_num"
        post_or_update_comment "$pr_num"
    fi

    notified=$((notified + 1))

done < <(fetch_prs)

# ─── Summary ──────────────────────────────────────────────────────────────────

echo "" >&2
echo "=== Summary ===" >&2
printf "  Total PRs examined:  %d\n" "$total" >&2
printf "  Skipped (date):      %d\n" "$skipped_date" >&2
printf "  Skipped (draft):     %d\n" "$skipped_draft" >&2
printf "  Skipped (has check): %d\n" "$skipped_has_check" >&2
printf "  Notified:            %d\n" "$notified" >&2
if [[ $DRY_RUN -eq 1 ]]; then
    echo "  (DRY RUN — no mutations made)" >&2
fi
