#!/usr/bin/env bash
#
# verify-sync.sh — Post-sync drift verification.
#
# Compares the file tree of the private repo's HEAD (after applying
# exclude_pathspecs from sync-config.json) against the public repo's HEAD.
# Drift = any file present in one set but not the other, or with differing
# blob content. Authorship/history is intentionally NOT checked here — that
# is verified separately by the sync workflow's mailmap and filter-stream.
#
# Usage:
#   verify-sync.sh <private-repo-dir> <public-repo-dir> <sync-config-json>
#
# Outputs (to fd 3, which the caller redirects to $GITHUB_OUTPUT):
#   drift=true|false
#   drift_count=<N>
#
# When drift is detected, /tmp/drift-files.txt is written with one
# "<status>\t<path>" line per drifted file:
#   >f          File expected (in private after exclusions) but missing or
#               stale (different content) in public.
#   *deleting   File present in public but should have been excluded/removed.
#
# All log output goes to stderr so the Actions log stays readable.
# Only key=value lines are written to fd 3.
#
set -euo pipefail
exec 3>&1 1>&2

PRIVATE_DIR="${1:?missing private repo dir}"
PUBLIC_DIR="${2:?missing public repo dir}"
CONFIG_FILE="${3:?missing sync-config.json path}"

# ── Load excludes ────────────────────────────────────────────────────────────
mapfile -t EXCLUDE_SPECS < <(jq -r '.exclude_pathspecs[]' "$CONFIG_FILE")

# Convert pathspec (":!path/" or ":(exclude)path") to bare path "path"
spec_to_path() {
    local s="$1"
    s="${s#:!}"
    s="${s#:(exclude)}"
    s="${s%/}"
    printf '%s' "$s"
}

# Pre-compute bare exclude paths for fast membership checks
declare -a EXCLUDE_PATHS=()
for spec in "${EXCLUDE_SPECS[@]:-}"; do
    [[ -z "$spec" ]] && continue
    EXCLUDE_PATHS+=("$(spec_to_path "$spec")")
done

# Test whether a repo-relative path is matched by any exclude (exact match
# for files, prefix-match for directories).
is_excluded() {
    local path="$1"
    for base in "${EXCLUDE_PATHS[@]:-}"; do
        [[ -z "$base" ]] && continue
        if [[ "$path" == "$base" || "$path" == "$base"/* ]]; then
            return 0
        fi
    done
    return 1
}

echo "Private dir:   $PRIVATE_DIR"
echo "Public dir:    $PUBLIC_DIR"
echo "Excludes:      ${EXCLUDE_PATHS[*]:-<none>}"

# ── Build expected and actual maps (path → blob sha) ─────────────────────────
declare -A EXPECTED ACTUAL

while IFS=$'\t' read -r meta path; do
    [[ -z "$path" ]] && continue
    is_excluded "$path" && continue
    sha="${meta##* }"
    EXPECTED["$path"]="$sha"
done < <(git -C "$PRIVATE_DIR" ls-tree -r HEAD)

while IFS=$'\t' read -r meta path; do
    [[ -z "$path" ]] && continue
    # Exclusions are bidirectional: paths that sync doesn't manage should not be
    # checked for drift in either direction. Public may legitimately contain
    # files in excluded paths (e.g., a public-only .github/CODEOWNERS).
    is_excluded "$path" && continue
    sha="${meta##* }"
    ACTUAL["$path"]="$sha"
done < <(git -C "$PUBLIC_DIR" ls-tree -r HEAD)

echo "Expected files: ${#EXPECTED[@]}"
echo "Actual files:   ${#ACTUAL[@]}"

# ── Diff ─────────────────────────────────────────────────────────────────────
DRIFT_FILE=/tmp/drift-files.txt
: > "$DRIFT_FILE"
DRIFT_COUNT=0

for path in "${!EXPECTED[@]}"; do
    if [[ -z "${ACTUAL[$path]:-}" ]]; then
        printf '>f\t%s\n' "$path" >> "$DRIFT_FILE"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
    elif [[ "${EXPECTED[$path]}" != "${ACTUAL[$path]}" ]]; then
        printf '>f\t%s\n' "$path" >> "$DRIFT_FILE"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
    fi
done

for path in "${!ACTUAL[@]}"; do
    if [[ -z "${EXPECTED[$path]:-}" ]]; then
        printf '*deleting\t%s\n' "$path" >> "$DRIFT_FILE"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
    fi
done

# Stable, deterministic ordering
sort -k2 "$DRIFT_FILE" -o "$DRIFT_FILE"

if [[ $DRIFT_COUNT -gt 0 ]]; then
    echo ""
    echo "❌ Drift detected ($DRIFT_COUNT file(s)):"
    sed 's/^/  /' "$DRIFT_FILE"
    echo "drift=true" >&3
    echo "drift_count=$DRIFT_COUNT" >&3
else
    echo "✅ No drift detected."
    echo "drift=false" >&3
    echo "drift_count=0" >&3
fi
