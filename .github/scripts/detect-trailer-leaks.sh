#!/usr/bin/env bash
# detect-trailer-leaks.sh — Detect internal emails embedded in commit message
# bodies (Co-authored-by:, Signed-off-by:, etc.) within a commit range.
#
# WHY THIS IS SEPARATE FROM detect-unmapped-emails.sh:
#   filter-stream.py only rewrites lines starting with `author ` or `committer `
#   in the git fast-export stream. Internal emails that appear in commit
#   MESSAGE BODIES (e.g. `Co-authored-by: Brandon Miller <brandom@microsoft.com>`)
#   pass through verbatim and leak to the public repo. Mailmap does NOT fix
#   this. The remediation is to amend/rewrite the trailer (or remove it).
#
# Usage:
#   detect-trailer-leaks.sh [OPTIONS]
#
# Options:
#   --range RANGE        Git revision range to scan (default: all commits)
#   --repo PATH          Path to git repository to scan (default: cwd)
#   --json               Output JSON instead of human-readable text
#   --quiet              Suppress informational output (only errors/JSON)
#
# Exit codes:
#   0  No trailer leaks found
#   1  Trailer leaks found
#   2  Script error (bad args, not a repo, etc.)

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────

RANGE=""
JSON_OUTPUT=0
QUIET=0
REPO_DIR=""

# ─── Argument parsing ─────────────────────────────────────────────────────────

_require_arg() {
    if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
        echo "ERROR: $1 requires a value" >&2; exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --range)     _require_arg "$1" "${2:-}"; RANGE="$2"; shift 2 ;;
        --repo)      _require_arg "$1" "${2:-}"; REPO_DIR="$2"; shift 2 ;;
        --json)      JSON_OUTPUT=1; shift ;;
        --quiet)     QUIET=1; shift ;;
        -h|--help)   head -25 "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
        *)           echo "ERROR: Unknown option: $1" >&2; exit 2 ;;
    esac
done

GIT_CMD=(git)
if [[ -n "$REPO_DIR" ]]; then
    GIT_CMD=(git -C "$REPO_DIR")
fi

if ! "${GIT_CMD[@]}" rev-parse --git-dir &>/dev/null; then
    echo "ERROR: Not a git repository (cwd=$(pwd), repo=$REPO_DIR)" >&2
    exit 2
fi

# ─── Scan commit message bodies in range ──────────────────────────────────────

# %H = full SHA, %B = raw body (subject + body). We delimit sha-from-body with
# %x00 inside each commit's output, and rely on `-z` (which replaces the
# inter-commit newline separator with NUL) to delimit commits from each
# other. Net layout: <sha>NUL<body>NUL<sha>NUL<body>NUL — two NUL-delimited
# records per commit, consumable with two `read -d ''` calls per iteration.
GIT_LOG_ARGS=(--format='%H%x00%B' -z)
if [[ -n "$RANGE" ]]; then
    GIT_LOG_ARGS+=("$RANGE")
else
    GIT_LOG_ARGS+=(--all)
fi

# Match any <...@microsoft.com> reference anywhere in the message. We accept
# both angle-bracketed (`<alias@microsoft.com>`, the canonical trailer form)
# and bare (`alias@microsoft.com`) forms — the sync filter doesn't rewrite
# either, so either leaks if present.
_INTERNAL_EMAIL_RE='([A-Za-z0-9._%+-]+)@microsoft\.com'

# Tab-separated triples: sha \t context-line \t email
findings_tsv=""

while IFS= read -r -d '' sha && IFS= read -r -d '' body; do
    [[ -z "$sha" ]] && continue
    # Iterate body line-by-line so we can report the trailer line for context.
    while IFS= read -r line; do
        # Scan for internal-email patterns in each message-body line. We match
        # against a lowercased copy of the line so case-varied domains like
        # <Alias@Microsoft.com> are still detected; the original line is preserved
        # for context display.
        line_lc="${line,,}"
        if [[ "$line_lc" =~ $_INTERNAL_EMAIL_RE ]]; then
            local_part="${BASH_REMATCH[1]}"
            email="${local_part,,}@microsoft.com"
            # Trim line to keep output readable
            trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-200)"
            findings_tsv+="${sha}"$'\t'"${trimmed}"$'\t'"${email}"$'\n'
        fi
    done <<< "$body"
done < <("${GIT_CMD[@]}" log "${GIT_LOG_ARGS[@]}")

# ─── Report ───────────────────────────────────────────────────────────────────

count=0
if [[ -n "$findings_tsv" ]]; then
    count=$(printf '%s' "$findings_tsv" | grep -c $'\t' || true)
fi

if [[ $count -eq 0 ]]; then
    [[ $QUIET -eq 0 ]] && echo "✅ No internal-email trailer leaks found." >&2
    if [[ $JSON_OUTPUT -eq 1 ]]; then
        echo '{"trailer_leaks":[]}'
    fi
    exit 0
fi

if [[ $JSON_OUTPUT -eq 1 ]]; then
    printf '%s' "$findings_tsv" | python3 -c "
import json, sys
items = []
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line:
        continue
    parts = line.split('\t', 2)
    if len(parts) < 3:
        continue
    items.append({
        'commit': parts[0],
        'line':   parts[1],
        'email':  parts[2],
    })
print(json.dumps({'trailer_leaks': items}, indent=2))
"
else
    echo "" >&2
    echo "❌ Found $count internal-email reference(s) in commit message bodies:" >&2
    echo "" >&2
    printf '%s' "$findings_tsv" | while IFS=$'\t' read -r sha line email; do
        short="${sha:0:8}"
        echo "  • $short  $email" >&2
        echo "             $line" >&2
    done
    echo "" >&2
    echo "══════════════════════════════════════════════════════════════════════" >&2
    echo "HOW TO FIX:" >&2
    echo "" >&2
    echo "  Mailmap does NOT rewrite commit message bodies — only the author/" >&2
    echo "  committer identity lines. To fix, remove the internal email from" >&2
    echo "  the commit message itself:" >&2
    echo "" >&2
    echo "    git rebase -i <base>      # mark each affected commit as 'reword'" >&2
    echo "    # (or 'edit' + 'git commit --amend' for the most recent commit)" >&2
    echo "" >&2
    echo "  Then either drop the offending trailer or rewrite it to use the" >&2
    echo "  noreply address that's in .github/sync-mailmap:" >&2
    echo "    Co-authored-by: Their Name <12345678+user@users.noreply.github.com>" >&2
    echo "" >&2
    echo "  Force-push the rewritten branch to your PR." >&2
    echo "══════════════════════════════════════════════════════════════════════" >&2
fi

exit 1
