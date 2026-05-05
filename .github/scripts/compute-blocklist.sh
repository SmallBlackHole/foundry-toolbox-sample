#!/usr/bin/env bash
# .github/scripts/compute-blocklist.sh
#
# Phase D4 sync gate: shared block-list computation.
# Both sync-to-public.yml and verify-sync.yml call this script with the same
# repo + SHA. They produce the same SYNC_BLOCKED_PATHS value, by construction.
#
# What it does:
#   1. Fetch the GitHub combined commit-status payload for <repo>@<sha>.
#   2. Pipe it through parse-validation-statuses.sh (D3).
#   3. Print a colon-separated list of blocked sample paths to stdout.
#   4. Print observability counts to stderr (tracked / per-pipeline / blocked).
#
# Usage:
#   compute-blocklist.sh <repo> <sha>
#   <repo> = owner/name (e.g. microsoft-foundry/foundry-samples-pr)
#   <sha>  = commit SHA whose statuses we read
#
# Environment:
#   BLOCKLIST_PAYLOAD_FILE  Optional. Path to a pre-fetched statuses JSON
#                           payload. If set, the gh fetch is skipped. Used by
#                           tests and to avoid double-fetching across steps.
#   GH_TOKEN                Forwarded to gh api when fetching.
#
# Output:
#   stdout — colon-separated repo-relative paths whose latest validation status
#            is failure/error/pending. Empty output means nothing is blocked
#            (a legitimate result, not an error).
#   stderr — diagnostic lines, including per-pipeline reporter counts.
#
# Exit codes:
#   0 — success (including legitimate empty output).
#   non-zero — fetch or parse failure. Per §8 Q5: caller MUST treat this as
#              fail-closed (abort sync) and not conflate with empty output.
#
# Retry policy:
#   Transient gh fetch errors (5xx, 429, network) retry with exponential
#   backoff up to 3 attempts. Fatal errors (auth, 4xx other than 429) abort.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$SCRIPT_DIR/parse-validation-statuses.sh"

REPO="${1:-}"
SHA="${2:-}"

if [[ -z "$REPO" || -z "$SHA" ]]; then
    echo "Usage: $0 <owner/repo> <sha>" >&2
    exit 2
fi

if [[ ! -x "$PARSER" && ! -f "$PARSER" ]]; then
    echo "compute-blocklist: parse-validation-statuses.sh not found at $PARSER" >&2
    exit 2
fi

# ── Fetch ────────────────────────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PAYLOAD="$WORK/statuses.json"

if [[ -n "${BLOCKLIST_PAYLOAD_FILE:-}" ]]; then
    if [[ ! -f "$BLOCKLIST_PAYLOAD_FILE" ]]; then
        echo "compute-blocklist: BLOCKLIST_PAYLOAD_FILE not found: $BLOCKLIST_PAYLOAD_FILE" >&2
        exit 1
    fi
    cp "$BLOCKLIST_PAYLOAD_FILE" "$PAYLOAD"
    echo "compute-blocklist: using payload from $BLOCKLIST_PAYLOAD_FILE" >&2
else
    if ! command -v gh >/dev/null 2>&1; then
        echo "compute-blocklist: gh CLI not available and no BLOCKLIST_PAYLOAD_FILE set" >&2
        exit 1
    fi

    attempt=1
    max_attempts=3
    backoff=2
    fetched=0
    while (( attempt <= max_attempts )); do
        # gh api exits non-zero on 4xx/5xx. Pagination: combined status endpoint
        # returns up to 1000 statuses per page; we paginate to catch all.
        if gh api --paginate "repos/$REPO/commits/$SHA/status" \
            --jq '{state: .state, statuses: .statuses}' \
            > "$PAYLOAD" 2> "$WORK/gh.err"; then
            fetched=1
            break
        fi
        # Distinguish transient vs fatal. Heuristic: gh prints HTTP code in stderr.
        if grep -qE 'HTTP 5[0-9][0-9]|HTTP 429|connect: |timeout|temporarily' "$WORK/gh.err"; then
            echo "compute-blocklist: transient fetch error (attempt $attempt/$max_attempts), backoff ${backoff}s" >&2
            sleep "$backoff"
            backoff=$((backoff * 2))
            attempt=$((attempt + 1))
            continue
        fi
        echo "compute-blocklist: fatal fetch error (no retry):" >&2
        cat "$WORK/gh.err" >&2
        exit 1
    done

    if (( fetched != 1 )); then
        echo "compute-blocklist: exhausted $max_attempts retries; aborting" >&2
        cat "$WORK/gh.err" >&2
        exit 1
    fi
fi

# Combined-status response under --paginate may emit multiple top-level
# objects, one per page. Concatenate their .statuses arrays into a single
# {statuses:[...]} payload that the parser understands.
NORMALIZED="$WORK/normalized.json"
if ! jq -s '{statuses: (map(.statuses // []) | add // [])}' "$PAYLOAD" > "$NORMALIZED" 2> "$WORK/normalize.err"; then
    echo "compute-blocklist: failed to normalize payload:" >&2
    cat "$WORK/normalize.err" >&2
    exit 1
fi

# ── Observability counts ─────────────────────────────────────────────────────
# Reporter counts are computed per pipeline-id parsed from `validation/<id>/...`.
# Pipelines that posted nothing for this SHA simply don't appear; the gate
# treats their samples as grandfathered (Q3).
COUNT_TRACKED="$(jq '[.statuses[]? | select(.context|startswith("validation/"))] | length' "$NORMALIZED" 2>/dev/null || echo 0)"
COUNT_BY_PIPELINE="$(jq -r '
    [.statuses[]?
        | select(.context|startswith("validation/"))
        | (.context | capture("^validation/(?<id>[^/]+)/").id)
    ]
    | group_by(.)
    | map({pipeline: .[0], count: length})
    | sort_by(.pipeline)
    | .[]
    | "  - \(.pipeline): \(.count)"
' "$NORMALIZED" 2>/dev/null || true)"

echo "compute-blocklist: $COUNT_TRACKED validation status(es) for $REPO@$SHA" >&2
if [[ -n "$COUNT_BY_PIPELINE" ]]; then
    echo "compute-blocklist: per-pipeline reporter counts:" >&2
    echo "$COUNT_BY_PIPELINE" >&2
else
    echo "compute-blocklist: no reporters posted for this SHA (all samples grandfathered)" >&2
fi

# ── Parse and emit ───────────────────────────────────────────────────────────
PARSER_OUT="$WORK/blocked.txt"
if ! bash "$PARSER" "$NORMALIZED" > "$PARSER_OUT" 2> "$WORK/parser.err"; then
    echo "compute-blocklist: parser failed:" >&2
    cat "$WORK/parser.err" >&2
    exit 1
fi

# parse-validation-statuses.sh emits a single line "a:b:c\n" or empty.
BLOCKED="$(cat "$PARSER_OUT")"
COUNT_BLOCKED=0
if [[ -n "$BLOCKED" ]]; then
    # Count colon-separated entries. Empty → 0.
    COUNT_BLOCKED="$(awk -F: '{print NF}' <<< "$BLOCKED")"
fi

echo "compute-blocklist: blocked sample(s): $COUNT_BLOCKED" >&2
if [[ -n "$BLOCKED" ]]; then
    echo "$BLOCKED"
fi
