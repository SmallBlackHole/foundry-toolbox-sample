#!/usr/bin/env bash
# Decide what validation status to post for an unchanged sample on a push:main
# partial-validation run, given the sample's prior status on the parent commit.
#
# This script encodes the carry-over decision matrix for the ado-build pipeline
# fan-out introduced by ADO 5247751 (D4 prerequisite). See
# docs/validation-story-decisions.md §8 Q4 for context.
#
# Args:
#   1. sample-path           — repo-relative sample directory, e.g. samples/python/foo
#   2. parent-statuses-file  — file containing one "<path>:<state>" line per
#                              ado-build-context-on-parent-SHA, as produced by
#                              fetch-parent-validation-statuses.sh
#
# Stdout (single tab-separated line):
#   <state>\t<description>
#
# Decision matrix:
#   parent success  → success  | "Validation carried over from previous run on unchanged source"
#   parent failure  → failure  | "Sample remains failing on unchanged source from previous run"
#   parent error    → error    | "Sample remained errored on unchanged source from previous run"
#   parent pending  → error    | "Parent had pending validation; treating as no prior decisive result"
#   missing         → error    | "No prior validation result on parent SHA"
#
# Why we carry forward failures (not promote them to error):
#   The sample's source bytes are identical to the parent SHA (it's not in this
#   commit's changed set). Whatever the validation said about the source on the
#   parent SHA is still factually true on this SHA. Carrying forward `failure`
#   preserves that truth and keeps the gate's reading model honest. The user
#   sees the same red they saw before, on the SHA the sync workflow is reading.
#
# Why pending → error:
#   `pending` is currently dormant in production (no pipeline emits it today).
#   If a parent commit somehow has it, treat as no decisive result rather than
#   carrying pending forward indefinitely.

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: decide-carry-over-state.sh <sample-path> <parent-statuses-file>

Outputs one tab-separated line: <state>\t<description>
USAGE
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi

    if [[ $# -ne 2 ]]; then
        usage
        exit 2
    fi

    local sample_path="$1"
    local statuses_file="$2"

    local prior_state=""
    if [[ -f "$statuses_file" ]]; then
        # awk handles "no match" cleanly (exits 0 with empty output) so we
        # don't trip pipefail when looking up a sample with no parent status.
        prior_state="$(awk -F: -v p="$sample_path" '$1 == p {print $2; exit}' "$statuses_file")"
    fi

    local state desc
    case "$prior_state" in
        success)
            state="success"
            desc="Validation carried over from previous run on unchanged source"
            ;;
        failure)
            state="failure"
            desc="Sample remains failing on unchanged source from previous run"
            ;;
        error)
            state="error"
            desc="Sample remained errored on unchanged source from previous run"
            ;;
        pending)
            state="error"
            desc="Parent had pending validation; treating as no prior decisive result"
            ;;
        *)
            state="error"
            desc="No prior validation result on parent SHA"
            ;;
    esac

    printf '%s\t%s\n' "$state" "$desc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
