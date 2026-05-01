#!/usr/bin/env bash
# .github/scripts/sync-core.sh
#
# Orchestrator for foundry-samples-pr → foundry-samples sync.
# Performs: marks management → fast-export → filter → fast-import →
# CODEOWNERS handling → ref update → optional push.
#
# Required environment variables:
#   PRIVATE_REPO   — path to checked-out private repo (must have full history)
#   PUBLIC_REPO    — path to checked-out public repo (must have full history)
#   SYNC_BRANCH    — name of sync branch on public repo (e.g., sync/private-to-public-YYYYMMDD)
#   MARKS_DIR      — directory to read/write marks files (persists across runs via cache)
#   CONFIG_FILE    — path to .github/sync-config.json
#   MAILMAP_FILE   — path to .github/sync-mailmap
#
# Optional environment variables:
#   DRY_RUN=1            — perform full pipeline but don't push or create PR
#   FORCE_FULL=1         — discard marks and force a full re-export
#   SYNC_BLOCKED_PATHS   — colon-separated repo-relative paths to exclude for this run
#
# Exit codes:
#   0 — success (sync completed, ref updated)
#   1 — error (pipeline failed)
#   2 — no changes (nothing to sync, clean exit)
#
# ── Gotchas ───────────────────────────────────────────────────────────────────
#
# fast-export --refspec=<src>:<dst> rewrites the LITERAL ref name emitted in
# the stream. When given a positional ref arg (e.g. HEAD, a branch name, or a
# SHA), fast-export resolves it to the underlying branch and emits
# `commit refs/heads/<branch>` directives — NOT the literal string you passed.
# So `--refspec=HEAD:refs/heads/main` silently fails to match in CI, where
# HEAD is a detached checkout of a feature branch.
#
# When that happens, the failure mode is silent and confusing:
#   - Stream's commit directives target the original branch name.
#   - Filter's --source-ref/--target-ref also fails to match → no rewrite.
#   - fast-import creates the original branch name in the public repo's
#     local clone (e.g. refs/heads/<feature-branch>), never pushed.
#   - refs/heads/$SYNC_BRANCH is never created by fast-import.
#   - apply_codeowners falls into the "branch missing → create from main"
#     fallback and amends public main's tip. Pushed branch is essentially
#     public main + 1 amend commit, with no imported authorship at all.
#
# Mitigation: run_fast_export pins SOURCE_REF to a fixed temp ref
# (refs/heads/sync-export-source) in the private repo before exporting, so
# the stream deterministically emits `commit refs/heads/main`, and our
# refspec + filter rewrites are predictable.
#
# Defensive check: apply_codeowners hard-fails if has_imports==1 but
# refs/heads/$SYNC_BRANCH is missing — would catch a regression of this bug
# immediately. See T28 in .github/tests/test-sync.sh for the regression test.
#
# Stale marks can also break fast-import when PUBLIC_MARKS references an
# object that no longer exists in the public repo. Because private/export marks
# and public/import marks are paired, import-side recovery discards both files
# and retries the full export → filter → import pipeline from scratch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER_SCRIPT="$SCRIPT_DIR/filter-stream.py"

# Source ref to export from. Default works for local tests where main is a
# local branch; CI sets this to HEAD (detached) or origin/main.
SOURCE_REF="${SOURCE_REF:-refs/heads/main}"

# ── Required env validation ───────────────────────────────────────────────────

require_env() {
    local missing=()
    for var in PRIVATE_REPO PUBLIC_REPO SYNC_BRANCH MARKS_DIR CONFIG_FILE MAILMAP_FILE; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required env vars: ${missing[*]}" >&2
        exit 1
    fi

    for path in "$PRIVATE_REPO" "$PUBLIC_REPO" "$CONFIG_FILE" "$MAILMAP_FILE" "$FILTER_SCRIPT"; do
        if [[ ! -e "$path" ]]; then
            echo "ERROR: Required path not found: $path" >&2
            exit 1
        fi
    done

    if [[ ! -d "$PRIVATE_REPO/.git" ]] || [[ ! -d "$PUBLIC_REPO/.git" ]]; then
        echo "ERROR: PRIVATE_REPO and PUBLIC_REPO must be git repos" >&2
        exit 1
    fi
}

# ── Helpers ───────────────────────────────────────────────────────────────────

log() {
    echo "[sync-core] $*" >&2
}

# Emit a key=value pair to GITHUB_OUTPUT if defined; otherwise to stderr.
emit_output() {
    local key="$1"
    local value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "${key}=${value}" >> "$GITHUB_OUTPUT"
    else
        log "OUTPUT ${key}=${value}"
    fi
}

# Read JSON value from config using python (jq may not be available everywhere)
config_get() {
    local key="$1"
    python3 -c "
import json, sys
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
keys = '$key'.split('.')
val = cfg
for k in keys:
    val = val[k]
if isinstance(val, list):
    print('\n'.join(str(x) for x in val))
else:
    print(val)
"
}

# Normalize a repo-relative path supplied by the validation gate.
normalize_blocked_path() {
    local path="$1"

    while [[ "$path" == ./* ]]; do
        path="${path#./}"
    done
    while [[ "$path" == */ ]]; do
        path="${path%/}"
    done

    [[ -z "$path" || "$path" == "." ]] && return 1
    printf '%s\n' "$path"
}

# Emit normalized dynamic exclusion pathspecs from SYNC_BLOCKED_PATHS.
build_dynamic_pathspecs() {
    local raw normalized
    local -a blocked_paths
    [[ -z "${SYNC_BLOCKED_PATHS:-}" ]] && return 0

    IFS=':' read -r -a blocked_paths <<< "$SYNC_BLOCKED_PATHS"
    for raw in "${blocked_paths[@]}"; do
        [[ -z "$raw" ]] && continue
        if ! normalized=$(normalize_blocked_path "$raw"); then
            continue
        fi
        if [[ -d "$PRIVATE_REPO/$normalized" ]]; then
            printf ':!%s/\n' "$normalized"
        elif [[ -e "$PRIVATE_REPO/$normalized" ]]; then
            printf ':!%s\n' "$normalized"
        fi
    done
}

# Emit all exclusion pathspecs that affect the exported history.
all_exclusion_pathspecs() {
    config_get "exclude_pathspecs"
    build_dynamic_pathspecs
}

# Compute a hash of the pathspecs to detect changes that affect history.
pathspec_hash() {
    all_exclusion_pathspecs | sort | sha256sum | awk '{print $1}'
}

# Get the SHA of the root commit (first commit in private repo's history).
# Used as cache invalidation key — if root changes, all marks are stale.
root_commit_sha() {
    git -C "$PRIVATE_REPO" rev-list --max-parents=0 HEAD | head -1
}

# Build pathspec args from static config plus dynamic validation exclusions.
build_pathspec_args() {
    local -a result=("--" ".")
    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        # Strip pathspec magic to get the bare path for existence check.
        local path="${spec#:!}"
        path="${path#:(exclude)}"
        path="${path%/}"
        if [[ -e "$PRIVATE_REPO/$path" ]]; then
            result+=("$spec")
        else
            log "Skipping non-existent pathspec: $spec"
        fi
    done < <(config_get "exclude_pathspecs")

    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        result+=("$spec")
    done < <(build_dynamic_pathspecs)

    printf '%s\n' "${result[@]}"
}

# ── State management ──────────────────────────────────────────────────────────

# Marks file paths
PRIVATE_MARKS=""
PUBLIC_MARKS=""
HASH_FILE=""
ROOT_FILE=""

setup_marks_state() {
    PRIVATE_MARKS="$MARKS_DIR/private.marks"
    PUBLIC_MARKS="$MARKS_DIR/public.marks"
    HASH_FILE="$MARKS_DIR/pathspec.hash"
    ROOT_FILE="$MARKS_DIR/root.sha"
    mkdir -p "$MARKS_DIR"
}

# Three-way state check:
#   - No stored hash + no marks → first run → full export, no warning
#   - Stored hash matches current → incremental, use marks
#   - Stored hash differs → config changed → discard marks, full re-export, warn
# Also discards marks if root commit SHA changed (force-push or repo recreated).
check_marks_validity() {
    local current_hash current_root stored_hash stored_root
    current_hash=$(pathspec_hash)
    current_root=$(root_commit_sha)

    local has_marks=0
    if [[ -f "$PRIVATE_MARKS" && -f "$PUBLIC_MARKS" ]]; then
        has_marks=1
    fi

    local has_state=0
    if [[ -f "$HASH_FILE" && -f "$ROOT_FILE" ]]; then
        has_state=1
        stored_hash=$(cat "$HASH_FILE")
        stored_root=$(cat "$ROOT_FILE")
    fi

    if [[ $has_marks -eq 0 && $has_state -eq 0 ]]; then
        log "First run detected — full export"
        echo "$current_hash" > "$HASH_FILE"
        echo "$current_root" > "$ROOT_FILE"
        return 0
    fi

    if [[ $has_marks -eq 0 || $has_state -eq 0 ]]; then
        log "WARNING: Inconsistent state — marks or hash missing. Forcing full re-export."
        rm -f "$PRIVATE_MARKS" "$PUBLIC_MARKS"
        echo "$current_hash" > "$HASH_FILE"
        echo "$current_root" > "$ROOT_FILE"
        return 0
    fi

    if [[ "$stored_root" != "$current_root" ]]; then
        log "WARNING: Root commit changed ($stored_root → $current_root). Forcing full re-export."
        rm -f "$PRIVATE_MARKS" "$PUBLIC_MARKS"
        echo "$current_hash" > "$HASH_FILE"
        echo "$current_root" > "$ROOT_FILE"
        return 0
    fi

    if [[ "$stored_hash" != "$current_hash" ]]; then
        log "WARNING: Pathspec config changed. Forcing full re-export."
        rm -f "$PRIVATE_MARKS" "$PUBLIC_MARKS"
        echo "$current_hash" > "$HASH_FILE"
        return 0
    fi

    if [[ "${FORCE_FULL:-0}" == "1" ]]; then
        log "FORCE_FULL=1 — discarding marks, full re-export"
        rm -f "$PRIVATE_MARKS" "$PUBLIC_MARKS"
        return 0
    fi

    log "Marks valid — incremental sync"
    return 0
}

# ── Pipeline steps ────────────────────────────────────────────────────────────

run_fast_export() {
    local stream_file="$1"
    local -a pathspec_args
    mapfile -t pathspec_args < <(build_pathspec_args)

    local -a import_marks_arg=()
    if [[ -f "$PRIVATE_MARKS" ]]; then
        import_marks_arg=("--import-marks=$PRIVATE_MARKS")
    fi

    # fast-export's --refspec rewrites the literal ref name emitted in the stream.
    # When given an arbitrary ref (e.g. "HEAD" or "refs/heads/feature"), fast-export
    # resolves it to the underlying branch name and emits `commit refs/heads/<branch>`.
    # That makes our refspec target ("refs/heads/main") unpredictable. We pin the
    # source by writing a temporary local ref (refs/heads/sync-export-source) so the
    # stream always emits `commit refs/heads/main` after the refspec rewrite.
    local export_ref="refs/heads/sync-export-source"
    local source_sha
    if ! source_sha=$(git -C "$PRIVATE_REPO" rev-parse --verify "$SOURCE_REF^{commit}" 2>/dev/null); then
        log "ERROR: cannot resolve SOURCE_REF=$SOURCE_REF in $PRIVATE_REPO"
        return 1
    fi
    git -C "$PRIVATE_REPO" update-ref "$export_ref" "$source_sha"
    # Make sure the temp ref is cleaned up no matter how this function exits.
    # shellcheck disable=SC2064
    trap "git -C '$PRIVATE_REPO' update-ref -d '$export_ref' 2>/dev/null || true" RETURN

    log "Running fast-export with ${#pathspec_args[@]} pathspec args (source=$SOURCE_REF -> $export_ref @ ${source_sha:0:8})"
    if ! git -C "$PRIVATE_REPO" fast-export \
        "${import_marks_arg[@]}" \
        --export-marks="$PRIVATE_MARKS" \
        --refspec="$export_ref:refs/heads/main" \
        "$export_ref" \
        --tag-of-filtered-object=drop \
        "${pathspec_args[@]}" \
        > "$stream_file" 2>"$stream_file.err"; then

        # Stale marks recovery: if export failed and we had marks, retry without them
        if [[ ${#import_marks_arg[@]} -gt 0 ]]; then
            log "WARNING: fast-export failed with marks — retrying without (stale marks recovery)"
            cat "$stream_file.err" >&2
            rm -f "$PRIVATE_MARKS" "$PUBLIC_MARKS"
            git -C "$PRIVATE_REPO" fast-export \
                --export-marks="$PRIVATE_MARKS" \
                --refspec="$export_ref:refs/heads/main" \
                "$export_ref" \
                --tag-of-filtered-object=drop \
                "${pathspec_args[@]}" \
                > "$stream_file" 2>"$stream_file.err"
        else
            cat "$stream_file.err" >&2
            return 1
        fi
    fi

    local size
    size=$(wc -c < "$stream_file")
    log "Exported $size bytes"
}

run_filter() {
    local input="$1"
    local output="$2"
    local source_ref="${3:-}"
    local target_ref="${4:-}"
    log "Filtering stream"
    local -a ref_args=()
    if [[ -n "$source_ref" && -n "$target_ref" ]]; then
        ref_args=(--source-ref "$source_ref" --target-ref "$target_ref")
    fi
    python3 "$FILTER_SCRIPT" --mailmap "$MAILMAP_FILE" "${ref_args[@]}" \
        < "$input" > "$output" 2>"$output.err" || {
        log "ERROR: Filter failed"
        cat "$output.err" >&2
        return 1
    }
    local size
    size=$(wc -c < "$output")
    log "Filtered output: $size bytes"
}

# Returns 0 if the stream contains at least one commit, 1 otherwise.
stream_has_commits() {
    grep -q "^commit " "$1" 2>/dev/null
}

run_fast_import() {
    local stream="$1"

    if ! stream_has_commits "$stream"; then
        log "No commits in filtered stream — skipping import"
        return 2
    fi

    local -a import_marks_arg=()
    if [[ -f "$PUBLIC_MARKS" ]]; then
        import_marks_arg=("--import-marks=$PUBLIC_MARKS")
    fi

    local import_err="$stream.import.err"
    log "Running fast-import to refs/heads/$SYNC_BRANCH"
    if git -C "$PUBLIC_REPO" fast-import \
        --force \
        "${import_marks_arg[@]}" \
        --export-marks="$PUBLIC_MARKS" \
        < "$stream" > /dev/null 2>"$import_err"; then
        rm -f "$import_err"
        return 0
    fi

    cat "$import_err" >&2

    # Stale marks recovery: if import failed and we had public marks, ask the
    # caller to discard both paired marks files and retry export+filter+import.
    if [[ ${#import_marks_arg[@]} -gt 0 ]]; then
        return 3
    fi

    log "ERROR: fast-import failed"
    return 1
}

# Copy CODEOWNERS from private to public if it changed.
# Returns 0 if a change was made (caller may want to amend or commit), 1 if unchanged.
sync_codeowners() {
    local src="$PRIVATE_REPO/.github/CODEOWNERS"
    local dst="$PUBLIC_REPO/.github/CODEOWNERS"

    if [[ ! -f "$src" ]]; then
        log "No CODEOWNERS in private repo — skipping"
        return 1
    fi

    # Check the public repo's HEAD on the sync branch (or main if branch doesn't exist yet)
    local ref="$SYNC_BRANCH"
    if ! git -C "$PUBLIC_REPO" rev-parse --verify "refs/heads/$ref" >/dev/null 2>&1; then
        ref="main"
    fi

    local existing=""
    if existing=$(git -C "$PUBLIC_REPO" show "$ref:.github/CODEOWNERS" 2>/dev/null); then
        if [[ "$existing" == "$(cat "$src")" ]]; then
            log "CODEOWNERS unchanged"
            return 1
        fi
    fi

    log "CODEOWNERS differs — will sync"
    return 0
}

# Apply CODEOWNERS as a commit on the sync branch.
# If the sync branch already has imported commits, amend into the last one.
# If no imported commits exist, create a standalone bot commit.
apply_codeowners() {
    local src="$PRIVATE_REPO/.github/CODEOWNERS"
    local has_imports="$1"  # "1" if imports happened, "0" otherwise

    # If imports happened, the sync branch already exists — check it out without -B
    # (which would reset it to HEAD and lose the imported commits).
    # If no imports happened, create the sync branch from main.
    if git -C "$PUBLIC_REPO" rev-parse --verify "refs/heads/$SYNC_BRANCH" >/dev/null 2>&1; then
        git -C "$PUBLIC_REPO" checkout "$SYNC_BRANCH" --quiet
    elif [[ "$has_imports" == "1" ]]; then
        # Imports were reported as successful but the sync branch is missing.
        # This means fast-import wrote the imported commits to a different ref —
        # almost certainly the refspec rewrite didn't take effect. Fail loudly
        # rather than silently creating an empty branch from main.
        log "ERROR: imports reported but refs/heads/$SYNC_BRANCH is missing"
        log "  fast-import likely wrote to a different ref name. Existing refs:"
        git -C "$PUBLIC_REPO" for-each-ref --format='    %(refname)' refs/heads >&2 || true
        return 1
    else
        # No imports — create sync branch from main
        git -C "$PUBLIC_REPO" checkout -B "$SYNC_BRANCH" main --quiet 2>/dev/null || \
        git -C "$PUBLIC_REPO" checkout -B "$SYNC_BRANCH" --quiet
    fi

    mkdir -p "$PUBLIC_REPO/.github"
    cp "$src" "$PUBLIC_REPO/.github/CODEOWNERS"
    git -C "$PUBLIC_REPO" add .github/CODEOWNERS

    if ! git -C "$PUBLIC_REPO" diff --cached --quiet; then
        if [[ "$has_imports" == "1" ]]; then
            log "Amending CODEOWNERS into last imported commit"
            GIT_COMMITTER_NAME="foundry-samples-sync[bot]" \
            GIT_COMMITTER_EMAIL="foundry-samples-sync[bot]@users.noreply.github.com" \
            git -C "$PUBLIC_REPO" commit --amend --no-edit --quiet
        else
            log "Creating standalone bot commit for CODEOWNERS"
            GIT_AUTHOR_NAME="foundry-samples-sync[bot]" \
            GIT_AUTHOR_EMAIL="foundry-samples-sync[bot]@users.noreply.github.com" \
            GIT_COMMITTER_NAME="foundry-samples-sync[bot]" \
            GIT_COMMITTER_EMAIL="foundry-samples-sync[bot]@users.noreply.github.com" \
            git -C "$PUBLIC_REPO" commit -m "chore: sync CODEOWNERS" --quiet
        fi
        return 0
    else
        log "No CODEOWNERS staging diff — nothing to commit"
        return 1
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    require_env
    setup_marks_state
    check_marks_validity

    # Capture public repo state BEFORE any modifications (for rollback)
    local public_head_before=""
    if git -C "$PUBLIC_REPO" rev-parse --verify main >/dev/null 2>&1; then
        public_head_before=$(git -C "$PUBLIC_REPO" rev-parse main)
    fi
    emit_output "public_head_before" "$public_head_before"

    local tmp_dir
    tmp_dir="$MARKS_DIR/sync-core-tmp-$$"
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    trap "rm -rf '$tmp_dir'" EXIT

    local export_stream="$tmp_dir/export.stream"
    local filtered_stream="$tmp_dir/filtered.stream"

    # Step 1: Export from private
    run_fast_export "$export_stream"

    # Step 2: Filter the stream (rewrite refs/heads/main -> refs/heads/$SYNC_BRANCH safely)
    run_filter "$export_stream" "$filtered_stream" \
        "refs/heads/main" "refs/heads/$SYNC_BRANCH"

    # Step 3: Check CODEOWNERS BEFORE deciding "nothing to sync"
    # (CODEOWNERS-only changes need a commit even when no code changed)
    local codeowners_changed=0
    if sync_codeowners; then
        codeowners_changed=1
    fi

    # Step 4: Import (if there are commits)
    local has_imports=0
    local import_result=0
    run_fast_import "$filtered_stream" && import_result=$? || import_result=$?
    if [[ $import_result -eq 3 ]]; then
        log "WARNING: fast-import failed with marks — discarding paired marks and retrying full export+import (stale marks recovery)"
        rm -f "$PRIVATE_MARKS" "$PUBLIC_MARKS"
        run_fast_export "$export_stream"
        run_filter "$export_stream" "$filtered_stream" \
            "refs/heads/main" "refs/heads/$SYNC_BRANCH"
        import_result=0
        run_fast_import "$filtered_stream" && import_result=$? || import_result=$?
    fi

    if [[ $import_result -eq 0 ]]; then
        has_imports=1
    elif [[ $import_result -eq 1 || $import_result -eq 3 ]]; then
        log "ERROR: fast-import failed"
        emit_output "has_changes" "false"
        exit 1
    fi
    # import_result==2 means no commits, that's fine

    # Step 5: Decide whether to do anything else
    if [[ $has_imports -eq 0 && $codeowners_changed -eq 0 ]]; then
        log "Nothing to sync — clean exit"
        emit_output "has_changes" "false"
        emit_output "commit_count" "0"
        emit_output "authors" ""
        exit 0
    fi

    # Step 6: Apply CODEOWNERS (if changed)
    if [[ $codeowners_changed -eq 1 ]]; then
        apply_codeowners "$has_imports"
    fi

    # Step 7: Verify sync branch exists
    if ! git -C "$PUBLIC_REPO" rev-parse --verify "refs/heads/$SYNC_BRANCH" >/dev/null 2>&1; then
        log "ERROR: Sync branch $SYNC_BRANCH was not created"
        emit_output "has_changes" "false"
        exit 1
    fi

    # Step 8: Emit summary outputs
    local commit_count authors
    if [[ -n "$public_head_before" ]]; then
        commit_count=$(git -C "$PUBLIC_REPO" rev-list --count "${public_head_before}..${SYNC_BRANCH}" 2>/dev/null || echo 0)
        authors=$(git -C "$PUBLIC_REPO" log "${public_head_before}..${SYNC_BRANCH}" --format="%an" 2>/dev/null | sort -u | paste -sd ", " - || echo "")
    else
        commit_count=$(git -C "$PUBLIC_REPO" rev-list --count "$SYNC_BRANCH" 2>/dev/null || echo 0)
        authors=$(git -C "$PUBLIC_REPO" log "$SYNC_BRANCH" --format="%an" 2>/dev/null | sort -u | paste -sd ", " - || echo "")
    fi
    emit_output "has_changes" "true"
    emit_output "commit_count" "$commit_count"
    emit_output "authors" "$authors"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "DRY_RUN=1 — sync branch built locally"
        log "Sync branch: $SYNC_BRANCH"
        log "Commits on sync branch:"
        git -C "$PUBLIC_REPO" log --oneline "$SYNC_BRANCH" -10 >&2 || true
        exit 0
    fi

    log "Sync complete. Branch $SYNC_BRANCH ready in $PUBLIC_REPO"
    log "Caller is responsible for: git push, gh pr create, gh pr merge --auto"
    exit 0
}

main "$@"
