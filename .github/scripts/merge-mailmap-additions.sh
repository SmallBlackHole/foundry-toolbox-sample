#!/usr/bin/env bash
# merge-mailmap-additions.sh — Compute mailmap delta vs an effective mailmap.
#
# Reads JSON output from detect-unmapped-emails.sh --json and emits ONLY the
# mailmap entries that are not already present in the supplied effective
# mailmap. The "effective" mailmap is the current sync-mailmap concatenated
# with whatever entries are already staged in an open auto-fix PR — so when
# multiple sync failures fire before the operator merges, we accumulate new
# authors instead of silently dropping them (see ADO 5356762).
#
# Usage:
#   merge-mailmap-additions.sh --detect-json FILE --effective-mailmap FILE
#
# Options:
#   --detect-json PATH         JSON file produced by `detect-unmapped-emails.sh --json`
#   --effective-mailmap PATH   Mailmap file to dedup against (main's mailmap +
#                              any open auto-fix PR's mailmap concatenated)
#
# Output (stdout):
#   Zero or more mailmap entries (and their VERIFY annotation comments) ready
#   to be inserted verbatim into a mailmap file. Empty output = nothing to add.
#
# Exit codes:
#   0  Success (no-op or one or more entries emitted)
#   2  Argument / IO error (missing files, bad flags)
#
# Pure: no `gh`, no `git push`. Safe to unit test.

set -euo pipefail

DETECT_JSON=""
EFFECTIVE_MAILMAP=""

_usage() {
    head -30 "$0" | grep '^#' | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --detect-json)
            DETECT_JSON="${2:-}"; shift 2
            ;;
        --effective-mailmap)
            EFFECTIVE_MAILMAP="${2:-}"; shift 2
            ;;
        -h|--help)
            _usage; exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$DETECT_JSON" ]]; then
    echo "ERROR: --detect-json is required" >&2; exit 2
fi
if [[ -z "$EFFECTIVE_MAILMAP" ]]; then
    echo "ERROR: --effective-mailmap is required" >&2; exit 2
fi
if [[ ! -f "$DETECT_JSON" ]]; then
    echo "ERROR: detect-json file not found: $DETECT_JSON" >&2; exit 2
fi
if [[ ! -f "$EFFECTIVE_MAILMAP" ]]; then
    echo "ERROR: effective-mailmap file not found: $EFFECTIVE_MAILMAP" >&2; exit 2
fi

# ─── Load mapped internal emails from effective mailmap ──────────────────────
# Same regex as detect-unmapped-emails.sh — match the trailing <internal> on
# each mapping line. Lowercase keys so dedup is case-insensitive.
#
# We also recognise the placeholder comment lines that THIS script emits for
# unresolved aliases (see the `# VERIFY: Needs manual lookup - <email>` line
# below). Without that recognition, the dedup set misses placeholders we
# wrote on a previous run, so every subsequent failing-sync trigger would
# append a duplicate placeholder block to the open auto-fix PR (same
# PR-pollution family as the PR-flood bug ADO 5356762 closed).

declare -A mapped_emails=()
_mailmap_re='<[^>]+>[[:space:]]+<([^>]+)>[[:space:]]*$'
_placeholder_re='^[[:space:]]*#[[:space:]]*VERIFY:[[:space:]]*Needs[[:space:]]+manual[[:space:]]+lookup[[:space:]]*-[[:space:]]*([^[:space:]]+)[[:space:]]*$'
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line// /}" ]] && continue
    # Real mapping line: "Name <safe> <internal>"
    if [[ "$line" =~ $_mailmap_re ]]; then
        mapped_emails["${BASH_REMATCH[1],,}"]=1
        continue
    fi
    # Manual-lookup placeholder we emitted on a previous run — treat the
    # alias as "already represented" so we don't re-emit it every cycle.
    if [[ "$line" =~ $_placeholder_re ]]; then
        mapped_emails["${BASH_REMATCH[1],,}"]=1
        continue
    fi
    # Other comments / unrecognised lines: skip silently.
done < "$EFFECTIVE_MAILMAP"

# Write mapped emails to a temp file (one per line) for Python to read.
# Using a tempfile avoids env-var size limits and quoting headaches.
MAPPED_LIST_FILE="$(mktemp -t merge-mailmap-mapped.XXXXXX)"
trap 'rm -f "$MAPPED_LIST_FILE"' EXIT
for em in "${!mapped_emails[@]}"; do
    printf '%s\n' "$em"
done > "$MAPPED_LIST_FILE"

# ─── Emit delta entries ──────────────────────────────────────────────────────
# Mirrors the formatting that the previous workflow inline-Python step used,
# so the resulting mailmap diff is visually identical when no dedup is needed.

python3 - "$DETECT_JSON" "$MAPPED_LIST_FILE" <<'PY'
import json
import sys

detect_path, mapped_path = sys.argv[1], sys.argv[2]

with open(mapped_path) as f:
    mapped = {line.strip().lower() for line in f if line.strip()}

with open(detect_path) as f:
    data = json.load(f)

out_lines = []
for item in data.get("unmapped", []):
    email = (item.get("email") or "").strip().lower()
    alias = (item.get("alias") or "").strip()
    entry = item.get("suggested_entry") or ""

    if not email:
        continue
    if email in mapped:
        continue
    # Defensive: skip empty-alias rows even if detect somehow lets one through.
    # The authoritative filter lives in detect-unmapped-emails.sh (ADO 5356763).
    if not alias:
        continue

    if entry and not entry.startswith("# UNRESOLVED"):
        # Real two-line entry: VERIFY comment + mapping line.
        out_lines.append(entry.rstrip("\n"))
    else:
        out_lines.append(f"# VERIFY: Needs manual lookup - {alias}@microsoft.com")
        out_lines.append(
            f"# Lookup: https://repos.opensource.microsoft.com/people?q={alias}"
        )

if out_lines:
    sys.stdout.write("\n".join(out_lines))
    sys.stdout.write("\n")
PY

exit 0
