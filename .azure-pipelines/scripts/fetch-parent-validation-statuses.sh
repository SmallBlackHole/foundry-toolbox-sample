#!/usr/bin/env bash
# Fetch validation/ado-build/* commit statuses on a given SHA from GitHub.
#
# Used by the ado-build pipeline's Report stage to look up the parent commit's
# per-sample validation results when posting carry-over statuses for unchanged
# samples on push:main runs (ADO 5247751, D4 prerequisite).
#
# Output (stdout): one "<sample-path>:<state>" line per ado-build context.
# <state> is one of success | failure | error | pending.
# <sample-path> is the suffix after "validation/ado-build/" (slashes preserved).
#
# Args:
#   1. SHA (commit SHA to query)
#
# Required env (live mode):
#   GITHUB_TOKEN  — installation token with statuses:read on the target repo
#
# Optional env:
#   GITHUB_OWNER     default: microsoft-foundry
#   GITHUB_REPO      default: foundry-samples-pr
#   GITHUB_API_URL   default: https://api.github.com
#
# Test mode:
#   FETCH_STATUSES_FIXTURE=<path>  read the GitHub combined-status JSON from
#       this file instead of calling the API. Lets unit tests inject a known
#       payload without network.
#
# Why combined-status (not list-statuses):
#   The combined-status endpoint returns the latest state per context, so we
#   don't have to dedupe by created_at. Same data the D3 reader consumes
#   (parse-validation-statuses.sh) — staying on this endpoint keeps the two
#   in agreement.

set -euo pipefail

PIPELINE_PREFIX="validation/ado-build/"

usage() {
    cat >&2 <<'USAGE'
Usage: fetch-parent-validation-statuses.sh <sha>

Outputs <sample-path>:<state> per matched ado-build context.
USAGE
}

# Filter a combined-status JSON payload (read from stdin) to ado-build contexts
# and emit one "<sample-path>:<state>" line per match.
#
# Extracted as a function so it's directly testable by piping a fixture file
# through stdin.
filter_payload() {
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg prefix "$PIPELINE_PREFIX" '
            (.statuses // [])[]
            | select(.context | startswith($prefix))
            | "\(.context | sub("^" + $prefix; ""))" + ":" + .state
        '
    else
        python3 -c '
import json, sys
prefix = sys.argv[1]
data = json.load(sys.stdin)
for s in data.get("statuses", []) or []:
    ctx = s.get("context", "")
    if ctx.startswith(prefix):
        sys.stdout.write(ctx[len(prefix):] + ":" + s.get("state", "") + "\n")
' "$PIPELINE_PREFIX"
    fi
}

fetch_page() {
    local sha="$1" page="$2"
    local owner repo api_url

    owner="${GITHUB_OWNER:-microsoft-foundry}"
    repo="${GITHUB_REPO:-foundry-samples-pr}"
    api_url="${GITHUB_API_URL:-https://api.github.com}"

    curl --fail-with-body -sS \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${api_url}/repos/${owner}/${repo}/commits/${sha}/status?per_page=100&page=${page}"
}

# Count statuses in a combined-status JSON payload. Used to drive pagination.
count_statuses() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '(.statuses // []) | length'
    else
        python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("statuses",[]) or []))'
    fi
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi

    if [[ $# -ne 1 ]]; then
        usage
        exit 2
    fi

    local sha="$1"

    # Test mode: read fixture and run the same filter the live path uses.
    # This keeps tests on the actual filter logic (no parallel implementation).
    if [[ -n "${FETCH_STATUSES_FIXTURE:-}" ]]; then
        filter_payload < "$FETCH_STATUSES_FIXTURE"
        return 0
    fi

    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        echo "Required environment variable is not set: GITHUB_TOKEN" >&2
        return 2
    fi

    local page=1
    local payload count
    while :; do
        payload="$(fetch_page "$sha" "$page")"
        count="$(printf '%s' "$payload" | count_statuses)"
        [[ "$count" -eq 0 ]] && break

        printf '%s' "$payload" | filter_payload

        # Combined-status caps per_page at 100; a short page = last page.
        [[ "$count" -lt 100 ]] && break
        page=$((page + 1))
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
