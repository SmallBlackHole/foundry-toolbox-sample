#!/usr/bin/env bash
# Parse GitHub validation commit statuses.
#
# Default mode (no flag):
#   Output: colon-separated repo-relative sample paths whose latest validation
#           status is failure, error, or pending. Empty output means nothing
#           is blocked. Used by the sync gate (compute-blocklist.sh).
#
# --json mode:
#   Output: JSON array of latest-per-context entries with shape
#           {path, pipeline_id, state, target_url, created_at, context}.
#           All states retained (success/failure/error/pending). Used by
#           the validation Health Board reporting layer.
#
# Input: GitHub statuses-list JSON, or an equivalent object with a `statuses`
# array. Provided as a file path or "-" for stdin.
set -euo pipefail

mode="blocked"
if [[ "${1:-}" == "--json" ]]; then
    mode="json"
    shift
fi

input="${1:--}"

if [[ "$input" != "-" && ! -f "$input" ]]; then
    echo "Status payload not found: $input" >&2
    exit 1
fi

if command -v jq >/dev/null 2>&1; then
    if [[ "$mode" == "json" ]]; then
        jq '
          def status_items:
            if type == "array" then .
            elif (.statuses? | type) == "array" then .statuses
            else []
            end;

          def parse_context($ctx):
            ($ctx | capture("^validation/(?<pipeline>[^/]+)/(?<path>.+)$"))
            | { pipeline_id: .pipeline, path: (.path | gsub("--"; "/")) };

          [ status_items[]?
            | select((.context? | type) == "string")
            | select((.state? | type) == "string")
            | select(.state == "success" or .state == "failure" or .state == "error" or .state == "pending")
            | select(.context | startswith("validation/"))
            | select(.context | test("^validation/[^/]+/.+"))
            | (parse_context(.context)) as $parsed
            | {
                path: $parsed.path,
                pipeline_id: $parsed.pipeline_id,
                state: .state,
                target_url: ((.target_url? // "") | tostring),
                created_at: ((.created_at? // "") | tostring),
                context: .context
              }
          ]
          | sort_by(.context, .created_at)
          | group_by(.context)
          | map(last)
          | sort_by(.path, .pipeline_id)
        ' "$input"
        exit 0
    fi

    jq -r '
      def status_items:
        if type == "array" then .
        elif (.statuses? | type) == "array" then .statuses
        else []
        end;

      def sample_path_from_context:
        (try capture("^validation/[^/]+/(?<path>.+)$").path catch empty)
        | select(length > 0)
        | gsub("--"; "/");

      [ status_items[]?
        | select((.context? | type) == "string")
        | select((.state? | type) == "string")
        | select(.state == "success" or .state == "failure" or .state == "error" or .state == "pending")
        | select(.context | startswith("validation/"))
        | { context, state, created_at: ((.created_at? // "") | tostring) }
      ]
      | sort_by(.context, .created_at)
      | group_by(.context)
      | map(last)
      | map(select(.state == "failure" or .state == "error" or .state == "pending"))
      | map(.context | sample_path_from_context)
      | unique
      | join(":")
      | select(length > 0)
    ' "$input"
    exit 0
fi

python_bin=""
if command -v python3 >/dev/null 2>&1; then
    python_bin="python3"
elif command -v python >/dev/null 2>&1; then
    python_bin="python"
else
    echo "Neither jq nor python is available to parse the status payload" >&2
    exit 127
fi

PYTHON_SCRIPT=$(cat <<'PY'
import json
import os
import re
import sys

VALID_STATES = {"success", "failure", "error", "pending"}
BLOCKING_STATES = {"failure", "error", "pending"}
CONTEXT_RE = re.compile(r"^validation/(?P<pipeline>[^/]+)/(?P<path>.+)$")

MODE = os.environ.get("PARSER_MODE", "blocked")

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError as exc:
    print(f"Invalid JSON status payload: {exc}", file=sys.stderr)
    sys.exit(1)

if isinstance(payload, list):
    statuses = payload
elif isinstance(payload, dict) and isinstance(payload.get("statuses"), list):
    statuses = payload["statuses"]
else:
    statuses = []

latest_by_context = {}
for item in statuses:
    if not isinstance(item, dict):
        continue
    context = item.get("context")
    state = item.get("state")
    if not isinstance(context, str) or not isinstance(state, str):
        continue
    if not context.startswith("validation/") or state not in VALID_STATES:
        continue
    match = CONTEXT_RE.match(context)
    if not match:
        continue
    created_at = str(item.get("created_at", ""))
    target_url = str(item.get("target_url", "") or "")
    previous = latest_by_context.get(context)
    if previous is None or created_at >= previous["created_at"]:
        latest_by_context[context] = {
            "state": state,
            "created_at": created_at,
            "target_url": target_url,
            "pipeline_id": match.group("pipeline"),
            "path": match.group("path").replace("--", "/"),
            "context": context,
        }

if MODE == "json":
    rows = sorted(
        latest_by_context.values(),
        key=lambda r: (r["path"], r["pipeline_id"]),
    )
    json.dump(rows, sys.stdout)
    sys.stdout.write("\n")
else:
    blocked_paths = set()
    for result in latest_by_context.values():
        if result["state"] not in BLOCKING_STATES:
            continue
        blocked_paths.add(result["path"])
    output = ":".join(sorted(blocked_paths))
    if output:
        print(output)
PY
)

env_prefix=()
if [[ "$mode" == "json" ]]; then
    export PARSER_MODE=json
else
    export PARSER_MODE=blocked
fi

if [[ "$input" == "-" ]]; then
    "$python_bin" -c "$PYTHON_SCRIPT"
else
    "$python_bin" -c "$PYTHON_SCRIPT" < "$input"
fi
