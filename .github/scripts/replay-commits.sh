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

# ── Build exclude lists from sync-config.json ────────────────────────────────
# Directory prefixes (trailing /) and exact file matches are stored separately
# for simple string comparison — no regex, no escaping issues.

EXCLUDE_DIRS=()
EXCLUDE_FILES=()

while IFS= read -r path; do
  if [[ "$path" == */ ]]; then
    EXCLUDE_DIRS+=("$path")
  else
    EXCLUDE_FILES+=("$path")
  fi
done < <(jq -r '.exclude_paths[]' "$CONFIG_FILE")

echo "Exclude dirs:  ${EXCLUDE_DIRS[*]:-<none>}"
echo "Exclude files: ${EXCLUDE_FILES[*]:-<none>}"

# Also write an rsync-compatible exclude file for the verification pass.
jq -r '.exclude_paths[]' "$CONFIG_FILE" > /tmp/sync-excludes.txt
echo ".git/" >> /tmp/sync-excludes.txt

# ── Validation-gating rsync excludes ─────────────────────────────────────────
# When gating is enabled we exclude every non-passed sample directory.
# This is appended to /tmp/sync-excludes.txt (--exclude-from syntax) and
# applies to BOTH bootstrap and verification rsync passes.

build_gating_excludes() {
  if [[ "$GATING_ENABLED" != "true" ]]; then
    return
  fi

  # Exclude manifest entries that did not pass validation.
  for spath in "${!VALIDATED_SAMPLES[@]}"; do
    if [[ "${VALIDATED_SAMPLES[$spath]}" != "passed" ]]; then
      echo "/$spath/***" >> /tmp/sync-excludes.txt
    fi
  done

  # Also exclude sample roots under samples/ that are not explicitly marked
  # "passed" in the manifest.  This prevents rsync from reintroducing sample
  # directories that should_sync() blocks as "unknown" during commit replay.
  # Sample roots are assumed to live at depth 2 under samples/
  # (e.g. samples/<group>/<sample>).
  local samples_root="$PRIVATE_DIR/samples"
  if [[ -d "$samples_root" ]]; then
    while IFS= read -r full_path; do
      if [[ "${VALIDATED_SAMPLES[$full_path]:-}" != "passed" ]]; then
        echo "/$full_path/***" >> /tmp/sync-excludes.txt
      fi
    done < <(cd "$PRIVATE_DIR" && find samples -mindepth 3 -maxdepth 3 -type d 2>/dev/null)
  fi

  echo "Validation gating: rsync excludes written for non-passed and unknown samples."
}

# ── Helpers ──────────────────────────────────────────────────────────────────

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

# find_sample_root returns the sample directory for a given file path,
# or empty string if the file is not under a sample directory.
find_sample_root() {
  local file="$1"
  local dir
  dir=$(dirname "$file")
  while [[ "$dir" != "samples" && "$dir" != "." ]]; do
    if [[ -f "$PRIVATE_DIR/$dir/sample.yaml" ]]; then
      echo "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  echo ""
  return 0
}

should_sync() {
  local file="$1"
  # CODEOWNERS is the one .github/ file we always sync.
  [[ "$file" == ".github/CODEOWNERS" ]] && return 0
  # Check directory prefix exclusions.
  for dir in "${EXCLUDE_DIRS[@]}"; do
    [[ "$file" == "$dir"* ]] && return 1
  done
  # Check exact file exclusions.
  for ef in "${EXCLUDE_FILES[@]}"; do
    [[ "$file" == "$ef" ]] && return 1
  done
  # Validation gating: if enabled, check if the file's sample passed validation.
  if [[ "$GATING_ENABLED" == "true" && "$file" == samples/* ]]; then
    local sample_root
    sample_root=$(find_sample_root "$file")
    if [[ -n "$sample_root" ]]; then
      local status="${VALIDATED_SAMPLES[$sample_root]:-unknown}"
      if [[ "$status" != "passed" ]]; then
        return 1
      fi
    else
      # No sample.yaml found walking up. Check if the file falls under any
      # path tracked in the manifest (covers skipped samples that lack
      # sample.yaml). If it matches a non-passed entry, block it.
      for manifest_path in "${!VALIDATED_SAMPLES[@]}"; do
        if [[ "$file" == "$manifest_path"/* ]]; then
          local status="${VALIDATED_SAMPLES[$manifest_path]}"
          if [[ "$status" != "passed" ]]; then
            return 1
          fi
          return 0
        fi
      done
      # No manifest match — block sync to stay consistent with rsync
      # gating (which excludes samples/ paths not in the manifest).
      return 1
    fi
  fi
  return 0
}

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
