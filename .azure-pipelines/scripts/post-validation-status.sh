#!/usr/bin/env bash
# Post one per-sample validation commit status to GitHub.
#
# Args:
#   1. sample path relative to repo root, e.g. samples/python/chat/quickstart
#   2. state/result: success|failure|error|pending (aliases: passed, failed, timeout)
#   3. target URL for the validation evidence
#   4. short description
#
# Required env:
#   GITHUB_TOKEN  installation token with commit statuses:write
#   GITHUB_SHA    commit SHA that was validated (SHA is accepted as a fallback)
#
# Optional env:
#   GITHUB_OWNER  default: microsoft-foundry
#   GITHUB_REPO   default: foundry-samples-pr
#   GITHUB_API_URL default: https://api.github.com
#   POST_VALIDATION_STATUS_DRY_RUN=1 prints the JSON payload instead of calling GitHub
set -euo pipefail

PIPELINE_ID="ado-build"

usage() {
    cat >&2 <<'USAGE'
Usage: post-validation-status.sh <sample-path> <state> <target-url> <description>

Posts context validation/ado-build/<sample-path> to GitHub.
USAGE
}

# Normalize the sample path for use inside a GitHub status context.
#
# The validation-results contract (docs/validation-results-contract.md) keeps
# '/' in <sample-path> for the ado-build pipeline because GitHub status
# contexts allow '/' and there is no character constraint that forces
# flattening here. Flattening to '--' is reserved for pipelines that need it
# (e.g. display constraints in hosted-agents-e2e). Mixing forms within one
# pipeline would create distinct contexts from the gate's point of view, so
# this helper only strips a leading "./" and any trailing slash.
normalize_sample_path() {
    local sample_path="$1"
    sample_path="${sample_path#./}"
    sample_path="${sample_path%/}"
    printf '%s' "$sample_path"
}

map_validation_state() {
    case "$1" in
        success|passed|pass) printf 'success' ;;
        failure|failed|fail) printf 'failure' ;;
        error|timeout|timed_out) printf 'error' ;;
        pending) printf 'pending' ;;
        *)
            echo "Invalid validation status state: $1" >&2
            return 2
            ;;
    esac
}

build_payload() {
    local sample_path="$1"
    local input_state="$2"
    local target_url="$3"
    local description="$4"
    local state normalized_path context

    state="$(map_validation_state "$input_state")"
    normalized_path="$(normalize_sample_path "$sample_path")"
    context="validation/${PIPELINE_ID}/${normalized_path}"

    if command -v jq >/dev/null 2>&1; then
        jq -nc \
            --arg state "$state" \
            --arg context "$context" \
            --arg target_url "$target_url" \
            --arg description "$description" \
            '{state:$state,context:$context,target_url:$target_url,description:$description}'
    else
        python3 - "$state" "$context" "$target_url" "$description" <<'PY'
import json
import sys
print(json.dumps({
    "state": sys.argv[1],
    "context": sys.argv[2],
    "target_url": sys.argv[3],
    "description": sys.argv[4],
}, separators=(",", ":")))
PY
    fi
}

post_status() {
    local sample_path="$1"
    local input_state="$2"
    local target_url="$3"
    local description="$4"
    local owner repo api_url sha payload

    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        echo "Required environment variable is not set: GITHUB_TOKEN" >&2
        return 2
    fi

    sha="${GITHUB_SHA:-${SHA:-}}"
    if [[ -z "$sha" ]]; then
        echo "Required environment variable is not set: GITHUB_SHA (or SHA)" >&2
        return 2
    fi

    owner="${GITHUB_OWNER:-microsoft-foundry}"
    repo="${GITHUB_REPO:-foundry-samples-pr}"
    api_url="${GITHUB_API_URL:-https://api.github.com}"
    payload="$(build_payload "$sample_path" "$input_state" "$target_url" "$description")"

    if [[ "${POST_VALIDATION_STATUS_DRY_RUN:-}" == "1" ]]; then
        printf '%s\n' "$payload"
        return 0
    fi

    curl --fail-with-body -sS \
        -X POST \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${api_url}/repos/${owner}/${repo}/statuses/${sha}" \
        -d "$payload" >/dev/null
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi

    if [[ $# -ne 4 ]]; then
        usage
        exit 2
    fi

    post_status "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
