#!/usr/bin/env bash
# .github/tests/test-doc-links.sh
#
# Lightweight markdown relative-link integrity check for repository docs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✅ PASS: $1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("$1: $2")
    echo "  ❌ FAIL: $1 — $2"
}

run_test() {
    local test_id="$1"
    local test_name="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo "── $test_id: $test_name ──"
}

summary() {
    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  Tests run: $TESTS_RUN  |  Passed: $TESTS_PASSED  |  Failed: $TESTS_FAILED"
    echo "════════════════════════════════════════════════════"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo ""
        echo "Failures:"
        for f in "${FAILURES[@]}"; do
            echo "  • $f"
        done
        exit 1
    fi
    exit 0
}

run_test "D1" "relative markdown links resolve to existing files"

set +e
output=$(python3 - "$REPO_ROOT" <<'PY'
import os
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
link_pattern = re.compile(r'(?<!!)\[[^\]]*\]\(([^)]+)\)')
broken = []
checked = 0

skip_dirs = {'.git', '.github/tests/.work-status-parsing'}

for md in sorted(root.rglob('*.md')):
    rel_parts = set(md.relative_to(root).parts)
    if rel_parts & skip_dirs:
        continue
    try:
        lines = md.read_text(encoding='utf-8').splitlines()
    except UnicodeDecodeError:
        lines = md.read_text(errors='replace').splitlines()

    for line_no, line in enumerate(lines, start=1):
        for match in link_pattern.finditer(line):
            raw = match.group(1).strip()
            if not raw:
                continue
            if raw.startswith('<') and raw.endswith('>'):
                raw = raw[1:-1].strip()
            lower = raw.lower()
            if lower.startswith(('http://', 'https://', 'mailto:', 'tel:', 'javascript:')):
                continue
            if raw.startswith('#'):
                continue
            if raw.startswith('/'):
                continue

            target = raw.split('#', 1)[0].split('?', 1)[0].strip()
            if not target:
                continue
            if '.md' not in target.lower():
                continue
            # Markdown titles are outside the simple relative-link cases we check.
            if ' ' in target and not Path(target).exists():
                target = target.split()[0]
            if not target.lower().endswith('.md'):
                continue

            checked += 1
            resolved = (md.parent / target).resolve()
            try:
                resolved.relative_to(root)
            except ValueError:
                pass
            if not resolved.exists():
                broken.append(f"{md.relative_to(root)}:{line_no}: {raw} -> {target}")

print(f"Checked {checked} relative markdown link(s).")
if broken:
    print("Broken relative markdown links:")
    for item in broken:
        print(f"  {item}")
    sys.exit(1)
PY
)
exit_code=$?
set -e

echo "$output"
if [[ $exit_code -eq 0 ]]; then
    pass "D1"
else
    fail "D1" "broken links found"
fi

summary
