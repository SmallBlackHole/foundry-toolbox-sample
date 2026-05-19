#!/usr/bin/env bash
# .github/scripts/render-validation-health.sh
#
# Validation Health Board renderer.
#
# Reads per-sample commit-status data for a given SHA, discovers the
# expected tracked-set from the on-disk registry (per
# validation-results-contract.md), and emits a single static markdown
# page surfacing:
#
#   - Tracked pass rate (success / reported-tracked)
#   - Coverage (reported-tracked / (reported-tracked + expected-uncovered))
#   - Per-sample table with multi-reporter precedence (failure/error > pending > success)
#   - Ungated section (expected paths with no reporter signal)
#   - Footer with generated-at, source SHA, refresh model
#
# Usage:
#   render-validation-health.sh <repo> <sha> <output_md> [<repo_root>]
#
# Environment:
#   BLOCKLIST_PAYLOAD_FILE  Optional. If set, skips gh fetch (used for tests).
#   GH_TOKEN                Forwarded to gh api when fetching.
#
# Exit codes:
#   0 — markdown written successfully (including all-green or all-ungated cases)
#   1 — fetch / parse / discovery failure
#   2 — argument error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$SCRIPT_DIR/parse-validation-statuses.sh"

REPO="${1:-}"
SHA="${2:-}"
OUT_MD="${3:-}"
REPO_ROOT="${4:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

if [[ -z "$REPO" || -z "$SHA" || -z "$OUT_MD" ]]; then
    echo "Usage: $0 <owner/repo> <sha> <output_md> [<repo_root>]" >&2
    exit 2
fi

if [[ ! -f "$PARSER" ]]; then
    echo "render-validation-health: parser not found at $PARSER" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PAYLOAD="$WORK/statuses.json"

# ── Fetch ────────────────────────────────────────────────────────────────────
if [[ -n "${BLOCKLIST_PAYLOAD_FILE:-}" ]]; then
    if [[ ! -f "$BLOCKLIST_PAYLOAD_FILE" ]]; then
        echo "render-validation-health: BLOCKLIST_PAYLOAD_FILE not found: $BLOCKLIST_PAYLOAD_FILE" >&2
        exit 1
    fi
    cp "$BLOCKLIST_PAYLOAD_FILE" "$PAYLOAD"
    echo "render-validation-health: using payload from $BLOCKLIST_PAYLOAD_FILE" >&2
else
    if ! command -v gh >/dev/null 2>&1; then
        echo "render-validation-health: gh CLI not available and no BLOCKLIST_PAYLOAD_FILE set" >&2
        exit 1
    fi

    attempt=1; max_attempts=3; backoff=2; fetched=0
    while (( attempt <= max_attempts )); do
        if gh api --paginate "repos/$REPO/commits/$SHA/status" \
            --jq '{state: .state, statuses: .statuses}' \
            > "$WORK/raw.json" 2> "$WORK/gh.err"; then
            fetched=1
            break
        fi
        if grep -qE 'HTTP 5[0-9][0-9]|HTTP 429|connect: |timeout|temporarily' "$WORK/gh.err"; then
            echo "render-validation-health: transient fetch error (attempt $attempt/$max_attempts), backoff ${backoff}s" >&2
            sleep "$backoff"
            backoff=$((backoff * 2))
            attempt=$((attempt + 1))
            continue
        fi
        echo "render-validation-health: fatal fetch error (no retry):" >&2
        cat "$WORK/gh.err" >&2
        exit 1
    done

    if (( fetched != 1 )); then
        echo "render-validation-health: exhausted $max_attempts retries; aborting" >&2
        cat "$WORK/gh.err" >&2
        exit 1
    fi

    # --paginate may emit multiple top-level objects. Mirror compute-blocklist's
    # normalization, but use Python so we don't depend on jq being present.
    python3 - "$WORK/raw.json" "$PAYLOAD" <<'PY'
import json, sys
raw_path, out_path = sys.argv[1], sys.argv[2]
combined = []
with open(raw_path, encoding="utf-8") as f:
    text = f.read().strip()
if not text:
    json.dump({"statuses": []}, open(out_path, "w", encoding="utf-8"))
    sys.exit(0)
decoder = json.JSONDecoder()
idx = 0
while idx < len(text):
    while idx < len(text) and text[idx].isspace():
        idx += 1
    if idx >= len(text):
        break
    obj, end = decoder.raw_decode(text, idx)
    combined.extend(obj.get("statuses") or [])
    idx = end
json.dump({"statuses": combined}, open(out_path, "w", encoding="utf-8"))
PY
fi

# ── Parse into structured rows ───────────────────────────────────────────────
ROWS="$WORK/rows.json"
if ! bash "$PARSER" --json "$PAYLOAD" > "$ROWS" 2> "$WORK/parse.err"; then
    echo "render-validation-health: parser failed:" >&2
    cat "$WORK/parse.err" >&2
    exit 1
fi

# ── Render via Python ────────────────────────────────────────────────────────
# Discovery + precedence + markdown emission. Embedded Python keeps logic in
# one place and avoids a second tool dependency at runtime.
GENERATED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

python3 - "$ROWS" "$REPO_ROOT" "$REPO" "$SHA" "$GENERATED_AT" "$OUT_MD" <<'PY'
import json, os, sys
from pathlib import Path

rows_path, repo_root, repo, sha, generated_at, out_md = sys.argv[1:7]
repo_root = Path(repo_root)

with open(rows_path, encoding="utf-8") as f:
    rows = json.load(f)

# ── Registry discovery (encodes validation-results-contract.md §pipeline) ───
def discover_ado_build():
    """Dirs under samples/ containing sample.yaml, excluding .ci-skip."""
    found = set()
    samples = repo_root / "samples"
    if not samples.is_dir():
        return found
    for path in samples.rglob("sample.yaml"):
        d = path.parent
        if (d / ".ci-skip").exists():
            continue
        rel = d.relative_to(repo_root).as_posix()
        found.add(rel)
    return found

def discover_hosted_agents():
    """Dirs under samples/{python,csharp}/hosted-agents/ containing agent.manifest.yaml."""
    found = set()
    for lang in ("python", "csharp"):
        root = repo_root / "samples" / lang / "hosted-agents"
        if not root.is_dir():
            continue
        for path in root.rglob("agent.manifest.yaml"):
            d = path.parent
            if (d / ".ci-skip").exists():
                continue
            rel = d.relative_to(repo_root).as_posix()
            found.add(rel)
    return found

expected = {
    "ado-build": discover_ado_build(),
    "hosted-agents-e2e": discover_hosted_agents(),
}

# ── Group rows by (path, pipeline_id) — parser already deduped to one row per
#    context. A single sample may have multiple pipeline reporters. ───────────
reported = {}  # (path, pipeline_id) -> row
for r in rows:
    key = (r["path"], r["pipeline_id"])
    reported[key] = r

reported_paths = {p for (p, _pid) in reported}
all_expected_paths = set().union(*expected.values()) if expected else set()
# Tracked-set = paths that are either expected OR reported.
all_paths = sorted(reported_paths | all_expected_paths)

# ── Per-path precedence: failure/error > pending > success > unreported ─────
def status_rank(state):
    return {"failure": 0, "error": 0, "pending": 1, "ungated": 2, "success": 3}.get(state, 4)

def md_escape(s):
    if s is None:
        return ""
    return (str(s)
            .replace("\\", "\\\\")
            .replace("|", "\\|")
            .replace("`", "\\`")
            .replace("\r", " ")
            .replace("\n", " "))

def md_url(s):
    # Encode characters that would corrupt a markdown table cell when present
    # in a URL inside [text](url). `|` is the cell delimiter, so percent-encode.
    if s is None:
        return ""
    return str(s).replace("|", "%7C").replace("\r", "").replace("\n", "")

def md_code(s):
    # For values rendered inside `...` code spans. Backslash escaping inside
    # code spans is not reliable in CommonMark, so neutralize backticks by
    # replacing them with a similar-looking non-backtick character. Paths
    # under samples/ should never legitimately contain backticks, so this is
    # purely defensive against a malformed context name landing in the
    # status payload.
    if s is None:
        return ""
    return (str(s)
            .replace("`", "'")
            .replace("\r", " ")
            .replace("\n", " "))

# pipeline columns: stable order
pipelines = ["ado-build", "hosted-agents-e2e"]
extra = sorted({pid for (_p, pid) in reported} - set(pipelines))
pipelines = pipelines + extra

def cell(path, pid):
    row = reported.get((path, pid))
    if row is None:
        if path in expected.get(pid, set()):
            return ("ungated", None, None)
        return ("n/a", None, None)
    return (row["state"], row.get("target_url") or "", row)

def emoji(state):
    return {
        "success": "🟢",
        "failure": "🔴",
        "error":   "🔴",
        "pending": "🟡",
        "ungated": "⚪",
        "n/a":     "·",
    }.get(state, "·")

# ── Compute headline numbers ────────────────────────────────────────────────
# Tracked-set semantics per Q5b:
#   - reported-tracked  = reported rows whose path is in some expected set
#                         (i.e., we expected this reporter and got a status)
#   - expected-uncovered = (expected (path,pid) pairs) not reported
#   - tracked-success   = reported-tracked whose state == success
expected_pairs = {(p, pid) for pid, paths in expected.items() for p in paths}
reported_pairs = set(reported.keys())
reported_tracked = reported_pairs & expected_pairs
tracked_success = sum(
    1 for k in reported_tracked if reported[k]["state"] == "success"
)
expected_uncovered = expected_pairs - reported_pairs

def pct(n, d):
    if d == 0:
        return "—"
    return f"{(100 * n / d):.1f}%"

tracked_pass_rate = pct(tracked_success, len(reported_tracked))
coverage_d = len(reported_tracked) + len(expected_uncovered)
coverage = pct(len(reported_tracked), coverage_d)

# ── Worst-state-per-path for the sample column ─────────────────────────────
# Considers BOTH reported pipelines AND expected-but-missing pipelines for
# this path. A path with one successful reporter and one expected-but-missing
# reporter must surface as ungated, not green — that's the silent fail-open
# mode the Health Board is meant to expose (per Q5/Q5b).
def path_worst_state(path):
    states = []
    for pid in pipelines:
        s, _, _ = cell(path, pid)
        if s in ("failure", "error", "pending", "success", "ungated"):
            states.append(s)
    if not states:
        return "ungated"
    return min(states, key=status_rank)

# ── Build markdown ──────────────────────────────────────────────────────────
lines = []
lines.append("# Validation Health Board")
lines.append("")
lines.append(f"_Generated {generated_at} from `{sha[:12]}`._")
lines.append("")
lines.append("| Metric | Value |")
lines.append("|---|---|")
lines.append(f"| Tracked pass rate | **{tracked_pass_rate}** ({tracked_success}/{len(reported_tracked)} reported-tracked checks green) |")
lines.append(f"| Coverage | **{coverage}** ({len(reported_tracked)}/{coverage_d} expected pipeline×sample pairs reporting) |")
lines.append(f"| Samples tracked | {len(all_paths)} |")
lines.append(f"| Refresh model | Daily cron (06:30 UTC) + manual dispatch |")
lines.append("")
lines.append("## Per-sample status")
lines.append("")

header_cols = ["Sample"] + pipelines + ["Evidence"]
lines.append("| " + " | ".join(header_cols) + " |")
lines.append("|" + "|".join(["---"] * len(header_cols)) + "|")

# Sort: red first, then yellow, then ungated, then green. Within each, by path.
state_sort = {"failure": 0, "error": 0, "pending": 1, "ungated": 2, "success": 3}
def sort_key(p):
    return (state_sort.get(path_worst_state(p), 4), p)

rows_md = []
green_rows_md = []

for path in sorted(all_paths, key=sort_key):
    worst = path_worst_state(path)
    sample_cell = f"{emoji(worst)} `{md_code(path)}`"
    pipeline_cells = []
    evidence_links = []
    for pid in pipelines:
        s, url, _row = cell(path, pid)
        pipeline_cells.append(emoji(s))
        if s in ("failure", "error", "pending") and url:
            evidence_links.append(f"[{md_code(pid)}]({md_url(url)})")
    evidence = " · ".join(evidence_links) if evidence_links else "—"
    row_line = "| " + " | ".join([sample_cell] + pipeline_cells + [evidence]) + " |"
    if worst == "success":
        green_rows_md.append(row_line)
    else:
        rows_md.append(row_line)

# All rows — non-green first (sorted by worst-state), then green — in one
# table. Per design intent: keep the full sample list visible at a glance.
lines.extend(rows_md)
lines.extend(green_rows_md)

# ── Ungated section ─────────────────────────────────────────────────────────
if expected_uncovered:
    lines.append("")
    lines.append("## Ungated (expected but unreported)")
    lines.append("")
    lines.append("These pipeline×sample pairs are in the on-disk registry but the")
    lines.append("pipeline has not posted a commit status for this SHA. The gate")
    lines.append("treats these as grandfathered today (fail-open), so they do not")
    lines.append("block sync but are visible here as coverage gaps.")
    lines.append("")
    lines.append("| Pipeline | Sample |")
    lines.append("|---|---|")
    for path, pid in sorted(expected_uncovered, key=lambda x: (x[1], x[0])):
        lines.append(f"| `{md_code(pid)}` | `{md_code(path)}` |")

# ── Footer ──────────────────────────────────────────────────────────────────
lines.append("")
lines.append("---")
lines.append("")
lines.append("**Source:** GitHub commit-status payload for "
             f"[`{sha[:12]}`](https://github.com/{repo}/commit/{sha}) on `main`. ")
lines.append("**Refresh:** auto-regenerated daily at 06:30 UTC by "
             "[`validation-health-refresh.yml`](../../.github/workflows/validation-health-refresh.yml); "
             "trigger a manual refresh via Actions → Validation Health Refresh → Run workflow. ")
lines.append("**Design contract:** see [`docs/validation-reporting-decisions.md`](../../docs/validation-reporting-decisions.md). ")
lines.append("**Renderer:** [`render-validation-health.sh`](../../.github/scripts/render-validation-health.sh).")
lines.append("")

with open(out_md, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(lines))

print(f"render-validation-health: wrote {out_md} "
      f"(samples={len(all_paths)}, reported-tracked={len(reported_tracked)}, "
      f"ungated-pairs={len(expected_uncovered)})", file=sys.stderr)
PY

echo "render-validation-health: ok" >&2
