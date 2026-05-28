#!/usr/bin/env bash
# compute-unmapped-blocklist.sh — Compute paths to exclude from sync due to unmapped emails.
#
# Instead of hard-failing the sync when unmapped internal emails are found,
# this script identifies which paths those commits touch and outputs them as
# a colon-separated blocklist. The sync pipeline then excludes those paths
# (same mechanism as the validation gate blocklist).
#
# Usage:
#   compute-unmapped-blocklist.sh --mailmap PATH --repo PATH [--since-sha SHA]
#
# Options:
#   --mailmap PATH     Path to sync-mailmap file
#   --repo PATH        Path to git repository to scan
#   --since-sha SHA    Only scan commits after this SHA (incremental). If empty,
#                      scans all commits (full history).
#
# Output (stdout):
#   Colon-separated list of repo-relative paths to exclude, or empty string if
#   no unmapped emails are found.
#
# Stderr:
#   Informational messages (unmapped emails found, affected paths, etc.)
#
# Exit codes:
#   0  No unmapped emails found, or unmapped emails found and blocklist emitted
#   1  Usage/configuration error (missing args, bad mailmap, not a git repo)
#
# Design:
#   For each commit with an unmapped internal author/committer email, ALL paths
#   touched by that commit are included in the blocklist. This ensures that when
#   fast-export applies pathspec exclusions, commits from unmapped authors produce
#   zero file operations and are stripped as empty by filter-stream.py — preventing
#   any unmapped email from appearing in the output stream.

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────

MAILMAP_FILE=""
REPO_DIR=""
SINCE_SHA=""

# ─── Argument parsing ─────────────────────────────────────────────────────────

_require_arg() {
    if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
        echo "ERROR: $1 requires a value" >&2; exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mailmap)    _require_arg "$1" "${2:-}"; MAILMAP_FILE="$2"; shift 2 ;;
        --repo)       _require_arg "$1" "${2:-}"; REPO_DIR="$2"; shift 2 ;;
        --since-sha)  _require_arg "$1" "${2:-}"; SINCE_SHA="$2"; shift 2 ;;
        -h|--help)    head -35 "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
        *)            echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ─── Validation ───────────────────────────────────────────────────────────────

if [[ -z "$MAILMAP_FILE" ]]; then
    echo "compute-unmapped-blocklist: ERROR: --mailmap is required" >&2
    exit 1
fi
if [[ -z "$REPO_DIR" ]]; then
    echo "compute-unmapped-blocklist: ERROR: --repo is required" >&2
    exit 1
fi
if [[ ! -f "$MAILMAP_FILE" ]]; then
    echo "compute-unmapped-blocklist: ERROR: Mailmap file not found: $MAILMAP_FILE" >&2
    exit 1
fi
if ! git -C "$REPO_DIR" rev-parse --git-dir &>/dev/null; then
    echo "compute-unmapped-blocklist: ERROR: Not a git repository: $REPO_DIR" >&2
    exit 1
fi

# ─── Load mailmap (extract mapped internal emails) ────────────────────────────

declare -A mapped_emails=()
_mailmap_re='<[^>]+>[[:space:]]+<([^>]+)>[[:space:]]*$'
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    if [[ "$line" =~ $_mailmap_re ]]; then
        mapped_emails["${BASH_REMATCH[1],,}"]=1
    fi
done < "$MAILMAP_FILE"

if [[ ${#mapped_emails[@]} -eq 0 ]]; then
    echo "compute-unmapped-blocklist: WARNING: No entries loaded from mailmap" >&2
    exit 0
fi

echo "compute-unmapped-blocklist: loaded ${#mapped_emails[@]} mailmap entries" >&2

# ─── Determine scan range ────────────────────────────────────────────────────

GIT_LOG_RANGE=()
if [[ -n "$SINCE_SHA" ]]; then
    # Verify the SHA exists in the repo
    if git -C "$REPO_DIR" rev-parse --verify "${SINCE_SHA}^{commit}" &>/dev/null; then
        GIT_LOG_RANGE=("${SINCE_SHA}..HEAD")
        echo "compute-unmapped-blocklist: scanning commits since ${SINCE_SHA:0:8}" >&2
    else
        echo "compute-unmapped-blocklist: WARNING: --since-sha ${SINCE_SHA:0:12} not found, scanning all commits" >&2
        GIT_LOG_RANGE=("--all")
    fi
else
    GIT_LOG_RANGE=("--all")
    echo "compute-unmapped-blocklist: scanning all commits (no --since-sha)" >&2
fi

# ─── Find commits with unmapped internal emails ──────────────────────────────
# Output: one SHA per line for commits that have unmapped author or committer

declare -A unmapped_commits=()
declare -A unmapped_emails_found=()

# Get all commits with their author and committer emails
while IFS=$'\t' read -r sha ae ce; do
    [[ -z "$sha" ]] && continue
    ae_lower="${ae,,}"
    ce_lower="${ce,,}"

    is_unmapped=0

    # Check author email
    if [[ "$ae_lower" == *@microsoft.com ]]; then
        if [[ -z "${mapped_emails[$ae_lower]:-}" ]]; then
            is_unmapped=1
            unmapped_emails_found["$ae_lower"]=1
        fi
    fi

    # Check committer email
    if [[ "$ce_lower" == *@microsoft.com ]]; then
        if [[ -z "${mapped_emails[$ce_lower]:-}" ]]; then
            is_unmapped=1
            unmapped_emails_found["$ce_lower"]=1
        fi
    fi

    if [[ $is_unmapped -eq 1 ]]; then
        unmapped_commits["$sha"]=1
    fi
done < <(git -C "$REPO_DIR" log --format='%H%x09%ae%x09%ce' "${GIT_LOG_RANGE[@]}" 2>/dev/null)

if [[ ${#unmapped_commits[@]} -eq 0 ]]; then
    echo "compute-unmapped-blocklist: no unmapped internal emails found ✅" >&2
    echo ""
    exit 0
fi

echo "compute-unmapped-blocklist: found ${#unmapped_commits[@]} commit(s) with unmapped emails" >&2
for email in "${!unmapped_emails_found[@]}"; do
    echo "  • $email" >&2
done

# ─── Resolve affected paths ──────────────────────────────────────────────────
# For each unmapped-email commit, find ALL files it touches.
# Then map each file to its sample directory (samples/<lang>/<area>/<feature>/).

declare -A blocked_paths=()

for sha in "${!unmapped_commits[@]}"; do
    while IFS= read -r filepath; do
        [[ -z "$filepath" ]] && continue

        # Resolve to sample directory granularity: samples/<a>/<b>/<c>/
        # If not under samples/, include the file's parent directory.
        if [[ "$filepath" == samples/* ]]; then
            # Extract up to 4 path components: samples/<lang>/<area>/<feature>
            # Note: if the 4th component is a file (not a dir), we still use it;
            # this is conservative — we'd rather over-exclude than under-exclude.
            IFS='/' read -r -a parts <<< "$filepath"
            if [[ ${#parts[@]} -ge 4 ]]; then
                sample_dir="${parts[0]}/${parts[1]}/${parts[2]}/${parts[3]}"
            elif [[ ${#parts[@]} -ge 3 ]]; then
                sample_dir="${parts[0]}/${parts[1]}/${parts[2]}"
            elif [[ ${#parts[@]} -ge 2 ]]; then
                sample_dir="${parts[0]}/${parts[1]}"
            else
                sample_dir="${parts[0]}"
            fi
            blocked_paths["$sample_dir"]=1
        else
            # Non-sample path: include the top-level directory or file directly.
            # Most of these (docs/, .github/, internal/, README.md) are already
            # statically excluded. Including them here is belt-and-suspenders.
            IFS='/' read -r -a parts <<< "$filepath"
            if [[ ${#parts[@]} -ge 2 ]]; then
                blocked_paths["${parts[0]}"]=1
            else
                blocked_paths["$filepath"]=1
            fi
        fi
    done < <(git -C "$REPO_DIR" diff-tree --no-commit-id -r --name-only "$sha" 2>/dev/null)
done

if [[ ${#blocked_paths[@]} -eq 0 ]]; then
    echo "compute-unmapped-blocklist: unmapped commits touch no files (merge commits?) — no paths blocked" >&2
    echo ""
    exit 0
fi

# ─── Output ──────────────────────────────────────────────────────────────────

echo "compute-unmapped-blocklist: blocking ${#blocked_paths[@]} path(s) due to unmapped emails:" >&2
result=""
for path in "${!blocked_paths[@]}"; do
    echo "  ⛔ $path" >&2
    if [[ -z "$result" ]]; then
        result="$path"
    else
        result="$result:$path"
    fi
done

echo "$result"
exit 0
