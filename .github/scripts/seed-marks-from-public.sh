#!/usr/bin/env bash
# .github/scripts/seed-marks-from-public.sh
#
# Synthesize paired fast-export/fast-import marks after verifying that a private
# commit and public commit are equivalent over the sync include-set.

set -euo pipefail

log() {
    echo "[seed-marks-from-public] $*" >&2
}

usage() {
    cat >&2 <<'EOF'
Usage: seed-marks-from-public.sh --private-sha <sha> --public-sha <sha> --marks-dir <dir>

Environment:
  PRIVATE_REPO   Path to private repo checkout (default: private-repo)
  PUBLIC_REPO    Path to public repo checkout (default: public-repo)
  CONFIG_FILE    Sync config JSON (default: $PRIVATE_REPO/.github/sync-config.json)
EOF
}

PRIVATE_SHA=""
PUBLIC_SHA=""
MARKS_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --private-sha)
            PRIVATE_SHA="${2:-}"
            shift 2
            ;;
        --public-sha)
            PUBLIC_SHA="${2:-}"
            shift 2
            ;;
        --marks-dir)
            MARKS_DIR="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$PRIVATE_SHA" || -z "$PUBLIC_SHA" || -z "$MARKS_DIR" ]]; then
    usage
    echo "ERROR: --private-sha, --public-sha, and --marks-dir are required" >&2
    exit 1
fi

PRIVATE_REPO="${PRIVATE_REPO:-private-repo}"
PUBLIC_REPO="${PUBLIC_REPO:-public-repo}"
CONFIG_FILE="${CONFIG_FILE:-$PRIVATE_REPO/.github/sync-config.json}"

for path in "$PRIVATE_REPO/.git" "$PUBLIC_REPO/.git" "$CONFIG_FILE"; do
    if [[ ! -e "$path" ]]; then
        echo "ERROR: Required path not found: $path" >&2
        exit 1
    fi
done

private_sha_input="$PRIVATE_SHA"
if ! PRIVATE_SHA=$(git -C "$PRIVATE_REPO" rev-parse --verify "$private_sha_input^{commit}" 2>/dev/null); then
    echo "ERROR: cannot resolve private SHA: $private_sha_input" >&2
    exit 1
fi
public_sha_input="$PUBLIC_SHA"
if ! PUBLIC_SHA=$(git -C "$PUBLIC_REPO" rev-parse --verify "$public_sha_input^{commit}" 2>/dev/null); then
    echo "ERROR: cannot resolve public SHA: $public_sha_input" >&2
    exit 1
fi

config_get() {
    local key="$1"
    CONFIG_FILE="$CONFIG_FILE" CONFIG_KEY="$key" python3 - <<'PY'
import json
import os

with open(os.environ["CONFIG_FILE"]) as f:
    cfg = json.load(f)
keys = os.environ["CONFIG_KEY"].split(".")
val = cfg
for k in keys:
    val = val[k]
if isinstance(val, list):
    print("\n".join(str(x) for x in val))
else:
    print(val)
PY
}

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

all_exclusion_pathspecs() {
    config_get "exclude_pathspecs"
    build_dynamic_pathspecs
}

pathspec_hash() {
    # Hash only the *static* exclusion config; dynamic SYNC_BLOCKED_PATHS are
    # per-run state and must not be folded into the durable marks-validity
    # hash. Stays in lockstep with sync-core.sh::pathspec_hash.
    config_get "exclude_pathspecs" | sort | sha256sum | awk '{print $1}'
}

root_commit_sha() {
    git -C "$PRIVATE_REPO" rev-list --max-parents=0 HEAD | head -1
}

spec_to_path() {
    local spec="$1"
    spec="${spec#:!}"
    spec="${spec#:(exclude)}"
    spec="${spec%/}"
    printf '%s\n' "$spec"
}

build_exclude_paths() {
    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        spec_to_path "$spec"
    done < <(all_exclusion_pathspecs)
}

is_excluded_path() {
    local path="$1"
    local base
    for base in "${EXCLUDE_PATHS[@]:-}"; do
        [[ -z "$base" ]] && continue
        if [[ "$path" == "$base" || "$path" == "$base"/* ]]; then
            return 0
        fi
    done
    return 1
}

write_filtered_tree() {
    local repo="$1"
    local sha="$2"
    local output="$3"
    while IFS=$'\t' read -r meta path; do
        [[ -z "$path" ]] && continue
        is_excluded_path "$path" && continue
        printf '%s\t%s\n' "$meta" "$path"
    done < <(git -C "$repo" ls-tree -r --full-tree "$sha") | sort > "$output"
}

compare_codeowners() {
    local private_blob public_blob
    if ! private_blob=$(git -C "$PRIVATE_REPO" rev-parse "$PRIVATE_SHA:.github/CODEOWNERS" 2>/dev/null); then
        return 0
    fi
    if ! public_blob=$(git -C "$PUBLIC_REPO" rev-parse "$PUBLIC_SHA:.github/CODEOWNERS" 2>/dev/null); then
        # Recoverable: a prior sync may have wiped CODEOWNERS from public, but
        # sync-core's codeowners-sync step amends it back into the imported
        # commit on every run. Warn rather than abort so the seed primitive is
        # usable after a degraded-public state (which is exactly when graft
        # recovery is needed). T58 still hard-fails on differing blobs.
        log "WARNING: public is missing .github/CODEOWNERS — codeowners-sync will restore it on next run; continuing"
        return 0
    fi
    if [[ "$private_blob" != "$public_blob" ]]; then
        echo "CODEOWNERS differs: private .github/CODEOWNERS blob $private_blob, public blob $public_blob" >&2
        return 1
    fi
}

main() {
    local -a EXCLUDE_PATHS
    mapfile -t EXCLUDE_PATHS < <(build_exclude_paths)

    local parent_dir tmp_dir private_tree public_tree
    parent_dir=$(dirname "$MARKS_DIR")
    mkdir -p "$parent_dir"
    tmp_dir="$parent_dir/.seed-marks-from-public.$$"
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    trap "rm -rf '$tmp_dir'" EXIT

    private_tree="$tmp_dir/private.tree"
    public_tree="$tmp_dir/public.tree"

    write_filtered_tree "$PRIVATE_REPO" "$PRIVATE_SHA" "$private_tree"
    write_filtered_tree "$PUBLIC_REPO" "$PUBLIC_SHA" "$public_tree"

    local mismatch=0
    if ! diff -u "$private_tree" "$public_tree" >&2; then
        echo "Tree mismatch between private $PRIVATE_SHA and public $PUBLIC_SHA over sync include-set" >&2
        mismatch=1
    fi
    if ! compare_codeowners; then
        mismatch=1
    fi
    if [[ $mismatch -ne 0 ]]; then
        echo "Refusing to synthesize marks; marks-dir left unchanged: $MARKS_DIR" >&2
        exit 1
    fi

    printf ':1 %s\n' "$PRIVATE_SHA" > "$tmp_dir/private.marks"
    printf ':1 %s\n' "$PUBLIC_SHA" > "$tmp_dir/public.marks"
    pathspec_hash > "$tmp_dir/pathspec.hash"
    root_commit_sha > "$tmp_dir/root.sha"

    mkdir -p "$MARKS_DIR"
    mv "$tmp_dir/private.marks" "$MARKS_DIR/private.marks"
    mv "$tmp_dir/public.marks" "$MARKS_DIR/public.marks"
    mv "$tmp_dir/pathspec.hash" "$MARKS_DIR/pathspec.hash"
    mv "$tmp_dir/root.sha" "$MARKS_DIR/root.sha"

    log "Seeded paired marks for private ${PRIVATE_SHA:0:8} ↔ public ${PUBLIC_SHA:0:8}"
}

main "$@"
