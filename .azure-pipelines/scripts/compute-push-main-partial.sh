#!/usr/bin/env bash
# Decide whether the current pipeline run should perform per-sample fan-out
# (carry-over from parent SHA) for tracked samples on push:main.
#
# Outputs "1" (yes, perform fan-out) or "0" (no) on stdout.
#
# Truth table (with VALIDATE_ALL != true):
#   BUILD_SOURCE_BRANCH      | BUILD_REASON              | Result
#   -------------------------+---------------------------+--------
#   refs/heads/main          | IndividualCI / BatchedCI  | 1   (organic push)
#   refs/heads/main          | Manual                    | 1   (re-queue / ad-hoc)
#   refs/heads/main          | Schedule                  | 0   (full validation owns its own posts)
#   refs/heads/main          | PullRequest               | 0   (PRs do not feed sync)
#   refs/heads/<other>       | (any)                     | 0
#   (any)                    | (any) but VALIDATE_ALL=true | 0 (full sweep posts directly)
#
# Driven by env vars (Azure DevOps predefined):
#   BUILD_SOURCE_BRANCH (e.g. refs/heads/main)
#   BUILD_REASON        (e.g. IndividualCI, BatchedCI, Manual, Schedule, PullRequest)
#   VALIDATE_ALL        (true/false; ADO renders booleans inconsistently — normalized here)
#
# This is a behavioural gate, not the publishing logic itself. The fan-out
# loop reads the result and decides whether to fetch parent statuses and
# carry over per-sample results.
#
# Tested by .azure-pipelines/scripts/tests/test-validation-status-helpers.sh
# (cases G1-G5).
set -euo pipefail

branch="${BUILD_SOURCE_BRANCH:-}"
reason="${BUILD_REASON:-}"
validate_all_lc="$(printf '%s' "${VALIDATE_ALL:-false}" | tr '[:upper:]' '[:lower:]')"

if [[ "$branch" == "refs/heads/main" \
      && "$reason" != "Schedule" \
      && "$reason" != "PullRequest" \
      && "$validate_all_lc" != "true" ]]; then
  echo 1
else
  echo 0
fi
