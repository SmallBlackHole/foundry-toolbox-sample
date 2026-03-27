#!/usr/bin/env bash
#
# verify-sync.sh — Post-sync drift verification.
#
# Usage:
#   verify-sync.sh <private-repo-dir> <public-repo-dir> <sync-config-json> [manifest-json]
#
# Computes the expected state of the public repo by applying the same exclude
# and validation-gating logic used by replay-commits.sh, then diffs against
# the actual public repo contents using rsync --dry-run.
#
# All log output goes to stderr so the Actions log stays readable.
# Only key=value lines are written to the original stdout (fd 3) which
# the caller redirects into $GITHUB_OUTPUT.
#
# When drift is detected, /tmp/drift-files.txt is written with one file per line.
#
set -euo pipefail

exec 3>&1 1>&2

PRIVATE_DIR="$1"
PUBLIC_DIR="$2"
CONFIG_FILE="$3"
MANIFEST_FILE="${4:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sync-lib.sh
source "$SCRIPT_DIR/sync-lib.sh"

# ── Build exclude list ───────────────────────────────────────────────────────

parse_exclude_paths "$CONFIG_FILE"

echo "Exclude dirs:  ${EXCLUDE_DIRS[*]:-<none>}"
echo "Exclude files: ${EXCLUDE_FILES[*]:-<none>}"

write_rsync_excludes

# ── Load validation manifest for gating ─────────────────────────────────────

declare -A VALIDATED_SAMPLES
MANIFEST_COMMIT_SHA=""
GATING_ENABLED=false

if [[ -n "$MANIFEST_FILE" && -f "$MANIFEST_FILE" ]]; then
  GATING_ENABLED=true
  MANIFEST_COMMIT_SHA=$(jq -r '.run.commitSha' "$MANIFEST_FILE")
  echo "Validation gating enabled (manifest commit: ${MANIFEST_COMMIT_SHA:0:12})"

  while IFS=$'\t' read -r path status; do
    VALIDATED_SAMPLES["$path"]="$status"
  done < <(jq -r '.results[] | [.path, .status] | @tsv' "$MANIFEST_FILE")

  echo "Loaded ${#VALIDATED_SAMPLES[@]} sample results from manifest."

  # Handle staleness: if any sample directories were modified after the
  # manifest's commit, remove them from the passed set (treat as unvalidated).
  if git -C "$PRIVATE_DIR" merge-base --is-ancestor "$MANIFEST_COMMIT_SHA" HEAD 2>/dev/null; then
    STALE_FILES=$(git -C "$PRIVATE_DIR" diff --name-only "$MANIFEST_COMMIT_SHA" HEAD -- samples/ 2>/dev/null || true)
    if [[ -n "$STALE_FILES" ]]; then
      while IFS= read -r stale_file; do
        [[ -z "$stale_file" ]] && continue
        stale_dir=$(dirname "$stale_file")
        while [[ "$stale_dir" != "samples" && "$stale_dir" != "." ]]; do
          if [[ -f "$PRIVATE_DIR/$stale_dir/sample.yaml" ]]; then
            if [[ "${VALIDATED_SAMPLES[$stale_dir]:-}" == "passed" ]]; then
              echo "  ⚠ Stale: $stale_dir (modified after validation) — will not sync"
              VALIDATED_SAMPLES["$stale_dir"]="stale"
            fi
            break
          fi
          stale_dir=$(dirname "$stale_dir")
        done
      done <<< "$STALE_FILES"
    fi
  fi

  PASSED_COUNT=0
  for status in "${VALIDATED_SAMPLES[@]}"; do
    [[ "$status" == "passed" ]] && PASSED_COUNT=$((PASSED_COUNT + 1))
  done
  echo "Sync-eligible samples: $PASSED_COUNT"
else
  echo "No validation manifest provided — sync gating disabled."
fi

build_gating_excludes

# ── Drift detection via rsync dry-run ───────────────────────────────────────

echo "═══ rsync dry-run ═══"

DRIFT_OUTPUT=$(rsync -a --delete --dry-run --itemize-changes \
  --exclude-from=/tmp/sync-excludes.txt \
  "$PRIVATE_DIR/" "$PUBLIC_DIR/" 2>&1 || true)

echo "$DRIFT_OUTPUT"

# Filter to lines that represent actual file changes:
#   >f... = file to send (create/update in destination)
#   *deleting = file to remove from destination
# Ignore directory entries (>d...) and attribute-only changes (.f...).
DRIFT_FILES=$(echo "$DRIFT_OUTPUT" \
  | grep -E '^\>f|^\*deleting' \
  | sed 's/^[^ ]* //' \
  | sort || true)

# replay-commits.sh always syncs .github/CODEOWNERS separately after rsync
# (rsync excludes the entire .github/ directory). Check it independently
# so drift in CODEOWNERS is not silently missed.
CODEOWNERS_PRIVATE="$PRIVATE_DIR/.github/CODEOWNERS"
CODEOWNERS_PUBLIC="$PUBLIC_DIR/.github/CODEOWNERS"
if [[ -f "$CODEOWNERS_PRIVATE" ]]; then
  if [[ ! -f "$CODEOWNERS_PUBLIC" ]] \
     || ! diff -q "$CODEOWNERS_PRIVATE" "$CODEOWNERS_PUBLIC" >/dev/null 2>&1; then
    echo "CODEOWNERS drift detected."
    DRIFT_FILES="${DRIFT_FILES}${DRIFT_FILES:+$'\n'}.github/CODEOWNERS"
  fi
fi
DRIFT_FILES=$(printf '%s' "$DRIFT_FILES" | sed '/^$/d' | sort)

echo "---"
if [[ -z "$DRIFT_FILES" ]]; then
  echo "No drift detected. Public repo is in sync. ✓"
  echo "drift=false" >&3
else
  DRIFT_COUNT=$(echo "$DRIFT_FILES" | wc -l | tr -d ' ')
  echo "Drift detected (${DRIFT_COUNT} file(s)):"
  echo "$DRIFT_FILES"
  printf '%s' "$DRIFT_FILES" > /tmp/drift-files.txt
  echo "drift=true"               >&3
  echo "drift_count=$DRIFT_COUNT" >&3
fi
