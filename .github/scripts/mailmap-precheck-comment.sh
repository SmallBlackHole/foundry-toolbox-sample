#!/usr/bin/env bash
# mailmap-precheck-comment.sh — Idempotent PR comment manager for the
# pre-merge mailmap check workflow.
#
# Reads the JSON outputs of detect-unmapped-emails.sh and detect-trailer-leaks.sh,
# builds a single PR comment body, and creates-or-edits a single comment on the
# target PR identified by the hidden HTML marker `<!-- sync-mailmap-check -->`.
#
# Idempotency contract:
#   - If a comment with the marker already exists, edit it in place.
#   - If no comment exists and there are findings, create one.
#   - If no comment exists and there are no findings, do nothing.
#   - If a comment exists but findings are now empty, edit it to a "resolved"
#     state (don't delete — leaves a visible audit trail).
#
# Usage:
#   mailmap-precheck-comment.sh \
#       --pr <number> --repo <owner/repo> \
#       --unmapped-json <path> --trailers-json <path>
#
# Requires: gh CLI authenticated; GH_TOKEN with issues:write (PR conversation
# comments are created/edited via the Issues Comments API).

set -euo pipefail

PR=""
REPO=""
UNMAPPED_JSON=""
TRAILERS_JSON=""

_require_arg() {
    if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
        echo "ERROR: $1 requires a value" >&2; exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)             _require_arg "$1" "${2:-}"; PR="$2"; shift 2 ;;
        --repo)           _require_arg "$1" "${2:-}"; REPO="$2"; shift 2 ;;
        --unmapped-json)  _require_arg "$1" "${2:-}"; UNMAPPED_JSON="$2"; shift 2 ;;
        --trailers-json)  _require_arg "$1" "${2:-}"; TRAILERS_JSON="$2"; shift 2 ;;
        -h|--help)        head -22 "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
        *)                echo "ERROR: Unknown option: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$PR" ]] || { echo "ERROR: --pr required" >&2; exit 2; }
[[ -n "$REPO" ]] || { echo "ERROR: --repo required" >&2; exit 2; }
[[ -n "$UNMAPPED_JSON" ]] || { echo "ERROR: --unmapped-json required" >&2; exit 2; }
[[ -n "$TRAILERS_JSON" ]] || { echo "ERROR: --trailers-json required" >&2; exit 2; }

if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI not on PATH" >&2; exit 2
fi

MARKER='<!-- sync-mailmap-check -->'

# ─── Build the comment body ───────────────────────────────────────────────────

BODY=$(
python3 - "$UNMAPPED_JSON" "$TRAILERS_JSON" <<'PY'
import json
import sys
from pathlib import Path

unmapped_path = Path(sys.argv[1])
trailers_path = Path(sys.argv[2])

def load(p, label):
    if not p.exists():
        errors.append(f"{label} missing: {p}")
        return {}
    text = p.read_text()
    if not text.strip():
        errors.append(f"{label} empty: {p}")
        return {}
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        errors.append(f"{label} invalid JSON: {e}")
        return {}

errors = []
unmapped = load(unmapped_path, "unmapped-json").get("unmapped", [])
trailers = load(trailers_path, "trailer-leaks-json").get("trailer_leaks", [])

lines = ['<!-- sync-mailmap-check -->']

if errors:
    # Detailed diagnostics go to stderr (workflow log) for maintainers; the
    # contributor — who can't see our CI logs — gets a generic CI-side message.
    for e in errors:
        print(f"mailmap-precheck: {e}", file=sys.stderr)
    lines += [
        '### ⚠️ Mailmap pre-check — could not run',
        '',
        'This check hit a CI-side error and could not complete. This is **not** '
        'something wrong with your PR — a maintainer will take a look.',
        '',
        '_Detailed diagnostics are in the workflow logs._',
    ]
    print('\n'.join(lines))
    raise SystemExit(0)

if not unmapped and not trailers:
    lines += [
        '### ✅ Mailmap pre-check — all clear',
        '',
        'No unmapped internal emails or trailer leaks detected in this PR\'s commits.',
        '',
        '_If you previously saw a failure on this PR, the latest push resolved it._',
    ]
else:
    lines += [
        '### ❌ Mailmap pre-check failed',
        '',
        'This PR introduces commits with `@microsoft.com` author, committer, or '
        'trailer emails that are not covered by `.github/sync-mailmap`. The '
        'public sync would fail (or worse, leak internal emails) if this merged '
        'as-is.',
        '',
        '**The fix lives in this PR — push it on this branch and the check will go green.**',
        '',
    ]

    if unmapped:
        lines += [
            '#### Unmapped author/committer emails',
            '',
            'These need a new line in `.github/sync-mailmap`:',
            '',
            '| Internal email | Suggested entry |',
            '| --- | --- |',
        ]
        for item in unmapped:
            email = item.get('email', '')
            alias = item.get('alias', '') or (email.split('@', 1)[0] if email else '')
            suggested = item.get('suggested_entry', '')
            cell = f'`{suggested}`' if suggested else (
                f'Look up your GitHub noreply at '
                f'<https://github.com/settings/emails> '
                f'(format: `12345678+{alias}@users.noreply.github.com`)'
            )
            lines.append(f'| `{email}` | {cell} |')
        lines += [
            '',
            '**To fix this PR:**',
            '',
            '1. Find your GitHub noreply email at <https://github.com/settings/emails> '
            '(under "Keep my email addresses private" — format `12345678+user@users.noreply.github.com`).',
            '2. Add a line to `.github/sync-mailmap`:',
            '   ```',
            '   Your Name <12345678+username@users.noreply.github.com> <alias@microsoft.com>',
            '   ```',
            '3. Commit and push to this branch.',
            '',
            '**To prevent it next time** (so other repos and future PRs don\'t hit this), set your '
            'local git email to the noreply address:',
            '```bash',
            'git config --global user.email "12345678+username@users.noreply.github.com"',
            '```',
            '',
        ]

    if trailers:
        lines += [
            '#### Internal-email trailer leaks (separate failure mode)',
            '',
            'These commits contain `@microsoft.com` references inside the commit '
            '**message body** (e.g. `Co-authored-by:` or `Signed-off-by:` trailers). '
            'The sync filter does **not** rewrite message bodies — a mailmap entry '
            'will not fix these. You\'ll need to rewrite the commit messages.',
            '',
            '| Commit | Email | Context |',
            '| --- | --- | --- |',
        ]
        for item in trailers:
            sha = (item.get('commit') or '')[:8]
            email = item.get('email', '')
            line = item.get('line', '').replace('|', '\\|').replace('`', '')
            lines.append(f'| `{sha}` | `{email}` | `{line}` |')
        lines += [
            '',
            '**To fix:**',
            '',
            '```bash',
            'git rebase -i <base>   # mark each affected commit as "reword" (or use --amend for HEAD)',
            '```',
            '',
            'Then either drop the offending trailer or replace the internal '
            'email with the contributor\'s GitHub noreply address.',
            '',
        ]

    lines += [
        '---',
        '',
        '_This check runs automatically on every push. Once your fix lands, this '
        'comment will update to ✅ — no need to re-request._',
    ]

print('\n'.join(lines))
PY
)

# ─── Find existing comment with our marker ────────────────────────────────────

# `gh api` paginates with --paginate; comments endpoint returns up to 100/page.
# Body contains the marker if it's one of ours.
EXISTING_ID=$(
    gh api --paginate "repos/$REPO/issues/$PR/comments" \
        --jq ".[] | select(.body | contains(\"$MARKER\")) | .id"
)
# Take the first match. Avoid `| head -n1` here: under `set -o pipefail` it
# can SIGPIPE (141) the upstream `gh api` once head closes the pipe, aborting
# the script right after a marker comment is found but before we update it.
EXISTING_ID="${EXISTING_ID%%$'\n'*}"

# Determine whether we have findings (or an internal error) so we can choose
# between create/skip. Missing/empty/invalid detector output is treated as an
# internal error that still warrants a comment.
HAS_FINDINGS=0
if python3 - "$UNMAPPED_JSON" "$TRAILERS_JSON" <<'PY' 2>/dev/null; then
import json
import sys
from pathlib import Path


def load(path):
    p = Path(path)
    if not p.exists():
        return None
    text = p.read_text()
    if not text.strip():
        return None
    try:
        return json.loads(text)
    except Exception:
        return None


u = load(sys.argv[1])
t = load(sys.argv[2])

# Missing/empty/invalid outputs => treat as "needs a comment" (internal error).
if u is None or t is None:
    raise SystemExit(0)

if u.get("unmapped") or t.get("trailer_leaks"):
    raise SystemExit(0)

raise SystemExit(1)
PY
    HAS_FINDINGS=1
fi

if [[ -z "$EXISTING_ID" && $HAS_FINDINGS -eq 0 ]]; then
    echo "No prior comment and no findings — nothing to do." >&2
    exit 0
fi

# Write body to a tempfile so gh handles huge bodies / special chars cleanly.
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT
printf '%s\n' "$BODY" > "$BODY_FILE"

if [[ -n "$EXISTING_ID" ]]; then
    echo "Editing existing comment $EXISTING_ID on PR #$PR..." >&2
    gh api --method PATCH "repos/$REPO/issues/comments/$EXISTING_ID" \
        -F body=@"$BODY_FILE" > /dev/null
else
    echo "Creating new comment on PR #$PR..." >&2
    gh api --method POST "repos/$REPO/issues/$PR/comments" \
        -F body=@"$BODY_FILE" > /dev/null
fi

echo "Comment updated." >&2
