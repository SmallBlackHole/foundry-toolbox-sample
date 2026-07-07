#!/usr/bin/env bash
# .github/scripts/force-full-direct-push.sh
#
# The force_full recovery "publish" step, extracted from sync-to-public.yml so it
# is unit-testable (test-sync.sh) and so the marks-reseed safety guard (ADO
# 5418305) has a home that both production and tests exercise.
#
# force_full produces an ORPHAN sync branch (full re-export with no mergeable
# common ancestor against public main). A normal PR/merge can't land it, so we
# build a "tree-replacement" commit on main: same tree as the sync branch tip,
# augmented with protected files from public main (e.g. .github/workflows/* that
# are excluded from export), PARENTED on current public main HEAD. History stays
# continuous (this is NOT orphan history on public — the commit descends from
# public main); only content is reset to private's canonical state.
#
# Environment (production defaults preserve the prior in-YAML behavior):
#   PUBLIC_REPO        Public repo checkout to operate in (default: cwd).
#   PRIVATE_REPO       Private repo checkout (default: private-repo). The reseed
#                      guard resolves private HEAD from it.
#   SYNC_BRANCH        Name of the orphan sync branch ref (required).
#   MAIN_REF           Ref to resolve public main from and read protected blobs
#                      from (default: origin/main). Tests pass a local ref.
#   CONFIG_FILE        sync-config.json (source of protected_paths) (required).
#   COMMIT_COUNT       Synced commit count, for the commit message.
#   AUTHORS            Synced authors, for the commit message.
#   ROLLBACK_SHA       Pre-run public main SHA, recorded in the commit message.
#   RUN_URL            CI run URL, recorded in the commit message.
#   MARKS_DIR          Marks cache dir. When set, the reseed guard runs (see
#                      below) and re-anchors marks to NEW_COMMIT before any push.
#                      Unset → guard skipped (no marks cache to anchor).
#   SYNC_BLOCKED_PATHS Effective block-list the export excluded; threaded into the
#                      guard so its tree-equivalence check excludes the same paths.
#   SEED_MARKS_SCRIPT  Path to seed-marks-from-public.sh (default: sibling file).
#   PUBLISH            1 (default): push NEW_COMMIT to origin/main and delete the
#                      remote sync branch. 0: skip the push/delete (tests publish
#                      locally themselves — the push is thin git plumbing). NOTE:
#                      the reseed guard is NOT gated by PUBLISH — whenever
#                      MARKS_DIR is set it runs and rewrites the marks cache, even
#                      under PUBLISH=0, because the guard is logic under test, not
#                      plumbing. A PUBLISH=0 caller that must avoid marks side
#                      effects should leave MARKS_DIR unset.
#
# Emits (to GITHUB_OUTPUT if set, else stderr):
#   new_commit=<sha>   The tree-replacement commit created on main.
#   sync_error=<CODE>  On fail-closed (FORCE_FULL_RESEED_TREE_MISMATCH).

set -euo pipefail

log() {
    echo "[force-full-direct-push] $*" >&2
}

# Emit a key=value pair to GITHUB_OUTPUT if defined; otherwise to stderr.
emit_output() {
    local key="$1" value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "${key}=${value}" >> "$GITHUB_OUTPUT"
    else
        log "OUTPUT ${key}=${value}"
    fi
}

PUBLIC_REPO="${PUBLIC_REPO:-$(pwd)}"
PRIVATE_REPO="${PRIVATE_REPO:-private-repo}"
SYNC_BRANCH="${SYNC_BRANCH:?SYNC_BRANCH is required}"
MAIN_REF="${MAIN_REF:-origin/main}"
CONFIG_FILE="${CONFIG_FILE:?CONFIG_FILE is required}"
COMMIT_COUNT="${COMMIT_COUNT:-0}"
AUTHORS="${AUTHORS:-}"
ROLLBACK_SHA="${ROLLBACK_SHA:-}"
RUN_URL="${RUN_URL:-}"
PUBLISH="${PUBLISH:-1}"

# Reseed-guard inputs (ADO 5418305). When MARKS_DIR is set, the marks cache is
# re-anchored to NEW_COMMIT before the push (see guard block below).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_MARKS_SCRIPT="${SEED_MARKS_SCRIPT:-$SCRIPT_DIR/seed-marks-from-public.sh}"
MARKS_DIR="${MARKS_DIR:-}"
SYNC_BLOCKED_PATHS="${SYNC_BLOCKED_PATHS:-}"

cd "$PUBLIC_REPO"

BRANCH="$SYNC_BRANCH"

# Start with the sync branch's tree.
SYNC_TREE=$(git rev-parse "${BRANCH}^{tree}")
MAIN_SHA=$(git rev-parse "$MAIN_REF")

log "Creating tree-replacement commit on main"
log "  sync branch tree: $SYNC_TREE"
log "  current main:     $MAIN_SHA"
log "  rollback point:   $ROLLBACK_SHA"

# Augment the sync tree with protected files from public main. The sync branch
# is an orphan that lacks .github/ content (excluded from export). Protected
# paths must survive the reset.
git checkout "$BRANCH" --quiet
PROTECTED_PATHS=$(python3 -c "
import json
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
for p in cfg.get('protected_paths', []):
    print(p)
")

AUGMENTED=0
while IFS= read -r ppath; do
    [[ -z "$ppath" ]] && continue
    # Get the file from public main.
    if git cat-file -e "${MAIN_SHA}:${ppath}" 2>/dev/null; then
        mkdir -p "$(dirname "$ppath")"
        git show "${MAIN_SHA}:${ppath}" > "$ppath"
        git add "$ppath"
        log "  preserved: $ppath"
        AUGMENTED=1
    else
        log "  skip (not on main): $ppath"
    fi
done <<< "$PROTECTED_PATHS"

if [[ $AUGMENTED -eq 1 ]]; then
    # Create a new tree that includes the protected files.
    FINAL_TREE=$(git write-tree)
    log "  augmented tree:   $FINAL_TREE"
else
    FINAL_TREE="$SYNC_TREE"
fi

# Create a new commit with main as parent but the augmented tree.
COMMIT_MSG="chore: force-full sync from private repo ($(date +%Y-%m-%d))

Tree-replacement commit: public main content reset to match private.
This is the force_full recovery path — the sync branch had no mergeable
common ancestor with public main (orphan history from full re-export).

Synced commits: ${COMMIT_COUNT}
Authors: ${AUTHORS}
Rollback point: ${ROLLBACK_SHA}
Run: ${RUN_URL}"

NEW_COMMIT=$(GIT_AUTHOR_NAME="foundry-samples-sync[bot]" \
    GIT_AUTHOR_EMAIL="foundry-samples-sync[bot]@users.noreply.github.com" \
    GIT_COMMITTER_NAME="foundry-samples-sync[bot]" \
    GIT_COMMITTER_EMAIL="foundry-samples-sync[bot]@users.noreply.github.com" \
    git commit-tree "$FINAL_TREE" -p "$MAIN_SHA" -m "$COMMIT_MSG")
log "  new commit:       $NEW_COMMIT"

emit_output "new_commit" "$NEW_COMMIT"

# ── Reseed guard (ADO 5418305) ────────────────────────────────────────────────
# force_full leaves the marks cache anchored to the orphan sync branch we are
# about to delete, which poisons the next incremental run. Before mutating public
# main, prove NEW_COMMIT is a valid incremental anchor for private HEAD and
# OVERWRITE the poisoned marks with a clean anchor (private HEAD <-> NEW_COMMIT).
# seed-marks-from-public.sh writes atomically and only on tree-equivalence
# success, so a mismatch leaves MARKS_DIR untouched and we fail closed BEFORE the
# push — public main and the marks cache both stay put (fail-closed = the exit).
# SYNC_BLOCKED_PATHS is threaded so the equivalence check excludes the same paths
# the export excluded; a raw equality check would false-fail on any block-list.
if [[ -n "$MARKS_DIR" ]]; then
    PRIVATE_HEAD=$(git -C "$PRIVATE_REPO" rev-parse HEAD)
    log "Reseed guard: anchoring marks private $PRIVATE_HEAD <-> public $NEW_COMMIT"
    if ! PRIVATE_REPO="$PRIVATE_REPO" PUBLIC_REPO="$PUBLIC_REPO" CONFIG_FILE="$CONFIG_FILE" \
         SYNC_BLOCKED_PATHS="$SYNC_BLOCKED_PATHS" \
         bash "$SEED_MARKS_SCRIPT" \
             --private-sha "$PRIVATE_HEAD" \
             --public-sha "$NEW_COMMIT" \
             --marks-dir "$MARKS_DIR"; then
        emit_output "sync_error" "FORCE_FULL_RESEED_TREE_MISMATCH"
        log "::error::force_full reseed guard failed — refusing to push or save marks"
        exit 1
    fi
    log "Reseed guard passed — marks anchor is valid; safe to push."
else
    log "MARKS_DIR unset — skipping reseed guard (no marks cache to anchor)."
fi

if [[ "$PUBLISH" == "1" ]]; then
    # Push directly to main. The app token has bypass on the branch ruleset.
    git push origin "${NEW_COMMIT}:refs/heads/main"
    log "Force-full sync complete — public main updated to match private."

    # Clean up the sync branch (no longer needed).
    git push origin --delete "$BRANCH" 2>/dev/null || true
else
    log "PUBLISH=0 — skipping push/delete; caller publishes new_commit=$NEW_COMMIT"
fi
