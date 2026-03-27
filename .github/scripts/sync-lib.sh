#!/usr/bin/env bash
#
# sync-lib.sh — Shared functions for the private→public sync pipeline.
#
# Sourced by replay-commits.sh (production) and test-sync.sh (tests).
# All functions here are pure logic with no side effects beyond writing
# to /tmp/sync-excludes.txt; they rely on the caller to set globals:
#
#   PRIVATE_DIR          — path to the private repo checkout
#   EXCLUDE_DIRS         — array of directory-prefix exclusions (trailing /)
#   EXCLUDE_FILES        — array of exact-file exclusions
#   GATING_ENABLED       — "true" when a validation manifest is active
#   VALIDATED_SAMPLES    — associative array: sample_path → status
#

# ── Exclude-list parsing ─────────────────────────────────────────────────────

# parse_exclude_paths <config-json>
#   Reads exclude_paths from the given sync-config JSON and populates the
#   global EXCLUDE_DIRS (trailing /) and EXCLUDE_FILES arrays.
parse_exclude_paths() {
  local config_file="$1"
  EXCLUDE_DIRS=()
  EXCLUDE_FILES=()
  while IFS= read -r path; do
    if [[ "$path" == */ ]]; then
      EXCLUDE_DIRS+=("$path")
    else
      EXCLUDE_FILES+=("$path")
    fi
  done < <(jq -r '.exclude_paths[]' "$config_file")
}

# write_rsync_excludes
#   Writes /tmp/sync-excludes.txt from EXCLUDE_DIRS and EXCLUDE_FILES.
#   All entries are anchored with a leading / so rsync only matches at the
#   transfer root.
write_rsync_excludes() {
  : > /tmp/sync-excludes.txt
  for path in "${EXCLUDE_DIRS[@]}"; do
    echo "/$path" >> /tmp/sync-excludes.txt
  done
  for path in "${EXCLUDE_FILES[@]}"; do
    echo "/$path" >> /tmp/sync-excludes.txt
  done
  echo "/.git/" >> /tmp/sync-excludes.txt
}

# ── Validation-gating rsync excludes ─────────────────────────────────────────

# build_gating_excludes
#   Appends rsync exclude rules for non-passed samples to
#   /tmp/sync-excludes.txt.  Only meaningful when GATING_ENABLED=true.
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
  # Only directories containing sample.yaml are treated as sample roots;
  # container directories that merely group sub-samples (e.g.
  # AgentFramework/) are left alone so rsync can still operate on their
  # contents.
  local samples_root="$PRIVATE_DIR/samples"
  if [[ -d "$samples_root" ]]; then
    while IFS= read -r full_path; do
      [[ ! -f "$PRIVATE_DIR/$full_path/sample.yaml" ]] && continue
      if [[ "${VALIDATED_SAMPLES[$full_path]:-}" != "passed" ]]; then
        echo "/$full_path/***" >> /tmp/sync-excludes.txt
      fi
    done < <(cd "$PRIVATE_DIR" && find samples -mindepth 3 -maxdepth 3 -type d 2>/dev/null)
  fi
}

# ── File-level helpers ───────────────────────────────────────────────────────

# find_sample_root <file-path>
#   Walks up from the file's directory looking for sample.yaml.
#   Prints the sample root path (relative) or empty string.
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

# should_sync <file-path>
#   Returns 0 (sync) or 1 (skip) for a given file path.
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
      # No manifest match — allow the file through.  Validation gating
      # only applies to recognised sample roots (sample.yaml) and explicit
      # manifest entries.  Content that falls outside both is treated as
      # non-sample and synced normally.
      return 0
    fi
  fi
  return 0
}
