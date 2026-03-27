#!/usr/bin/env bash
#
# replay-commits.sh — Replay private-repo commits onto public-repo preserving authorship.
#
# Usage:
#   replay-commits.sh <private-repo-dir> <public-repo-dir> <sync-config-json> [manifest-json]
#
# The optional 4th argument is a validation manifest produced by the ADO
# pipeline.  When provided, only samples that passed validation are synced;
# all other samples/ content is excluded from both commit replay and rsync.
#
# All command output goes to stderr so the Actions log stays readable.
# Only key=value lines are written to the original stdout (fd 3) which
# the caller redirects into $GITHUB_OUTPUT.
#
set -euo pipefail

# Save original stdout for step-output lines, then redirect stdout → stderr.
exec 3>&1 1>&2

PRIVATE_DIR="$1"
PUBLIC_DIR="$2"
CONFIG_FILE="$3"
MANIFEST_FILE="${4:-}"

SYNC_SHA_FILE="$PUBLIC_DIR/.github/.sync-sha"
BOT_NAME="foundry-samples-repo-sync[bot]"
BOT_EMAIL="foundry-samples-repo-sync[bot]@users.noreply.github.com"

# ── Source shared function library ───────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sync-lib.sh"

# ── Build exclude lists from sync-config.json ────────────────────────────────

parse_exclude_paths "$CONFIG_FILE"

echo "Exclude dirs:  ${EXCLUDE_DIRS[*]:-<none>}"
echo "Exclude files: ${EXCLUDE_FILES[*]:-<none>}"

write_rsync_excludes

# ── Load validation manifest for sync gating ─────────────────────────────────
# When a manifest is provided, only samples that passed validation are eligible
# to sync. Files not under a sample directory are unaffected.

declare -A VALIDATED_SAMPLES   # sample_path → "passed" | "failed" | "skipped" | "stale" (modified after validation)
MANIFEST_COMMIT_SHA=""
GATING_ENABLED=false

if [[ -n "$MANIFEST_FILE" && -f "$MANIFEST_FILE" ]]; then
  GATING_ENABLED=true
  MANIFEST_COMMIT_SHA=$(jq -r '.run.commitSha' "$MANIFEST_FILE")
  echo "Validation gating enabled (manifest commit: ${MANIFEST_COMMIT_SHA:0:12})"

  # Load per-sample results into an associative array
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
        # Walk up to find the sample root for this changed file
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

# Build rsync gating excludes after manifest is loaded + staleness resolved.
build_gating_excludes

# ── Configure git committer identity ────────────────────────────────────────

git -C "$PUBLIC_DIR" config user.name  "$BOT_NAME"
git -C "$PUBLIC_DIR" config user.email "$BOT_EMAIL"

# ── Determine sync state ────────────────────────────────────────────────────

PRIVATE_HEAD=$(git -C "$PRIVATE_DIR" rev-parse HEAD)

if [[ -f "$SYNC_SHA_FILE" ]]; then
  LAST_SYNC_SHA=$(tr -d '[:space:]' < "$SYNC_SHA_FILE")

  if ! git -C "$PRIVATE_DIR" merge-base --is-ancestor "$LAST_SYNC_SHA" HEAD 2>/dev/null; then
    echo "⚠  Stored SHA ($LAST_SYNC_SHA) is unreachable — falling back to full rsync."
    LAST_SYNC_SHA=""
  elif [[ "$LAST_SYNC_SHA" == "$PRIVATE_HEAD" ]]; then
    echo "No new commits since last sync (${LAST_SYNC_SHA:0:12})."
    echo "has_changes=false" >&3
    exit 0
  else
    echo "Last synced SHA: ${LAST_SYNC_SHA:0:12}"
  fi
else
  echo "No .sync-sha found — first run, using full rsync bootstrap."
  LAST_SYNC_SHA=""
fi

# ── Bootstrap (first run or unreachable SHA) ─────────────────────────────────

if [[ -z "$LAST_SYNC_SHA" ]]; then
  echo "═══ Bootstrap: full rsync ═══"

  rsync -a --delete \
    --exclude-from=/tmp/sync-excludes.txt \
    "$PRIVATE_DIR/" "$PUBLIC_DIR/"

  # .github/ is excluded from rsync, so we must ensure the directory exists
  # before copying CODEOWNERS into it (matters on first-ever bootstrap).
  mkdir -p "$PUBLIC_DIR/.github"
  cp "$PRIVATE_DIR/.github/CODEOWNERS" "$PUBLIC_DIR/.github/CODEOWNERS"

  git -C "$PUBLIC_DIR" add -A
  if ! git -C "$PUBLIC_DIR" diff --cached --quiet; then
    git -C "$PUBLIC_DIR" commit -m "Sync from private repository (bootstrap)"
  fi

  mkdir -p "$(dirname "$SYNC_SHA_FILE")"
  echo "$PRIVATE_HEAD" > "$SYNC_SHA_FILE"
  git -C "$PUBLIC_DIR" add .github/.sync-sha
  git -C "$PUBLIC_DIR" commit -m "Record sync state" --allow-empty

  echo "has_changes=true" >&3
  exit 0
fi

# Snapshot public repo HEAD before making changes — used to detect whether
# any commits were actually added (more robust than counting).
PUBLIC_HEAD_BEFORE=$(git -C "$PUBLIC_DIR" rev-parse HEAD)

# ── Replay commits ───────────────────────────────────────────────────────────

echo "═══ Replaying commits: ${LAST_SYNC_SHA:0:12}..${PRIVATE_HEAD:0:12} ═══"

COMMITS=$(git -C "$PRIVATE_DIR" log --first-parent --reverse --format='%H' \
  "${LAST_SYNC_SHA}..${PRIVATE_HEAD}")

REPLAY_COUNT=0

for SHA in $COMMITS; do
  AUTHOR_NAME=$(git  -C "$PRIVATE_DIR" log -1 --format='%an' "$SHA")
  AUTHOR_EMAIL=$(git -C "$PRIVATE_DIR" log -1 --format='%ae' "$SHA")
  AUTHOR_DATE=$(git  -C "$PRIVATE_DIR" log -1 --format='%aI' "$SHA")
  COMMIT_MSG=$(git   -C "$PRIVATE_DIR" log -1 --format='%B' "$SHA")
  SHORT_MSG=$(git    -C "$PRIVATE_DIR" log -1 --format='%s' "$SHA")

  # Files changed in this commit (vs its first parent).
  CHANGED_FILES=$(git -C "$PRIVATE_DIR" diff-tree --no-commit-id -r --name-only "$SHA" 2>/dev/null || true)
  [[ -z "$CHANGED_FILES" ]] && continue

  HAS_SYNCABLE=false

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    should_sync "$file" || continue
    HAS_SYNCABLE=true

    if git -C "$PRIVATE_DIR" cat-file -e "${SHA}:${file}" 2>/dev/null; then
      # File exists in this commit — copy it.
      mkdir -p "$PUBLIC_DIR/$(dirname "$file")"
      git -C "$PRIVATE_DIR" show "${SHA}:${file}" > "$PUBLIC_DIR/$file"

      # Preserve the executable bit.
      FILE_MODE=$(git -C "$PRIVATE_DIR" ls-tree "$SHA" -- "$file" | awk '{print $1}')
      if [[ "$FILE_MODE" == "100755" ]]; then
        chmod +x "$PUBLIC_DIR/$file"
      else
        chmod -x "$PUBLIC_DIR/$file"
      fi

      git -C "$PUBLIC_DIR" add -- "$file"
    else
      # File was deleted in this commit.
      git -C "$PUBLIC_DIR" rm -f --ignore-unmatch -- "$file"
    fi
  done <<< "$CHANGED_FILES"

  [[ "$HAS_SYNCABLE" == "false" ]] && continue

  # Commit with the original author identity.
  if ! git -C "$PUBLIC_DIR" diff --cached --quiet 2>/dev/null; then
    export GIT_AUTHOR_NAME="$AUTHOR_NAME"
    export GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL"
    export GIT_AUTHOR_DATE="$AUTHOR_DATE"
    export GIT_COMMITTER_DATE="$AUTHOR_DATE"
    git -C "$PUBLIC_DIR" commit -m "$COMMIT_MSG"
    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_DATE

    REPLAY_COUNT=$((REPLAY_COUNT + 1))
    echo "  ✓ ${SHA:0:12} — ${AUTHOR_NAME} — ${SHORT_MSG:0:72}"
  fi
done

echo "Replayed $REPLAY_COUNT commit(s)."

# ── Verification: rsync pass to catch drift ──────────────────────────────────
# If the replay diverged from the expected rsync state (e.g. due to merge
# commits or edge cases), a fixup commit corrects the delta.
# Non-validated sample directories are excluded from rsync to avoid
# re-introducing files that were gated out during replay.

echo "═══ Verification: rsync pass ═══"

rsync -a --delete \
  --exclude-from=/tmp/sync-excludes.txt \
  "$PRIVATE_DIR/" "$PUBLIC_DIR/"

mkdir -p "$PUBLIC_DIR/.github"
cp "$PRIVATE_DIR/.github/CODEOWNERS" "$PUBLIC_DIR/.github/CODEOWNERS"

git -C "$PUBLIC_DIR" add -A
if ! git -C "$PUBLIC_DIR" diff --cached --quiet 2>/dev/null; then
  echo "⚠  Drift detected — creating fixup commit:"
  git -C "$PUBLIC_DIR" diff --cached --stat
  git -C "$PUBLIC_DIR" commit -m "fixup: correct drift after commit replay"
  REPLAY_COUNT=$((REPLAY_COUNT + 1))
else
  echo "  No drift detected. ✓"
fi

# ── Record sync state ────────────────────────────────────────────────────────

mkdir -p "$(dirname "$SYNC_SHA_FILE")"
echo "$PRIVATE_HEAD" > "$SYNC_SHA_FILE"
git -C "$PUBLIC_DIR" add -- .github/.sync-sha
if ! git -C "$PUBLIC_DIR" diff --cached --quiet 2>/dev/null; then
  git -C "$PUBLIC_DIR" commit -m "Update sync state to ${PRIVATE_HEAD:0:12}"
fi

# ── Output ───────────────────────────────────────────────────────────────────
# Compare HEAD before/after to determine if any commits were added.
# This catches content replays, fixup commits, and sync-state-only updates.

PUBLIC_HEAD_AFTER=$(git -C "$PUBLIC_DIR" rev-parse HEAD)
if [[ "$PUBLIC_HEAD_BEFORE" != "$PUBLIC_HEAD_AFTER" ]]; then
  echo "has_changes=true" >&3
else
  echo "has_changes=false" >&3
fi
