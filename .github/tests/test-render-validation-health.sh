#!/usr/bin/env bash
# .github/tests/test-render-validation-health.sh
#
# Fixture tests for render-validation-health.sh.
#
# Each test:
#   - sets up a synthetic repo_root with sample.yaml / agent.manifest.yaml stubs
#   - writes a status payload
#   - invokes the renderer with BLOCKLIST_PAYLOAD_FILE set
#   - asserts properties of the rendered markdown

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_REAL="$(cd "$SCRIPT_DIR/../.." && pwd)"
RENDER="$REPO_ROOT_REAL/.github/scripts/render-validation-health.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

setup_fixture() {
    local fix="$1"
    mkdir -p "$WORK/$fix/repo/samples/python/quickstart/foo"
    mkdir -p "$WORK/$fix/repo/samples/python/hosted-agents/agent-framework/responses/01-basic"
    mkdir -p "$WORK/$fix/repo/samples/python/hosted-agents/agent-framework/multi"
    : > "$WORK/$fix/repo/samples/python/quickstart/foo/sample.yaml"
    : > "$WORK/$fix/repo/samples/python/hosted-agents/agent-framework/responses/01-basic/agent.manifest.yaml"
    # 'multi' has BOTH sample.yaml AND agent.manifest.yaml in the SAME dir.
    # This is a real shape (e.g. samples/python/hosted-agents/bring-your-own/
    # invocations/event-grid-trigger). It's expected by both ado-build AND
    # hosted-agents-e2e — used to exercise the partial-ungated bug fix.
    : > "$WORK/$fix/repo/samples/python/hosted-agents/agent-framework/multi/sample.yaml"
    : > "$WORK/$fix/repo/samples/python/hosted-agents/agent-framework/multi/agent.manifest.yaml"
}

render() {
    local fix="$1"
    BLOCKLIST_PAYLOAD_FILE="$WORK/$fix/payload.json" \
        bash "$RENDER" owner/repo deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
        "$WORK/$fix/out.md" "$WORK/$fix/repo" \
        > "$WORK/$fix/stdout" 2> "$WORK/$fix/stderr"
}

# ── R1: tracked pass rate vs coverage are separate numbers ───────────────────
echo "── R1: headline math reports both tracked-pass-rate and coverage ──"
setup_fixture R1
cat > "$WORK/R1/payload.json" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/quickstart/foo","state":"success","target_url":"u1","created_at":"2026-05-14T10:00:00Z"}
]}
JSON
render R1
# 1 reporter (ado-build/foo) success. ado-build expects: foo, multi → 2.
# hosted-agents-e2e expects: 01-basic, multi → 2. Total expected pairs = 4.
# reported-tracked = 1. tracked-success = 1. Coverage = 1/4 = 25%.
if grep -q 'Tracked pass rate | \*\*100.0%\*\*' "$WORK/R1/out.md" \
   && grep -q 'Coverage | \*\*25.0%\*\*' "$WORK/R1/out.md"; then
    pass "R1"
else
    fail "R1" "headline numbers wrong; got: $(grep -E 'pass rate|Coverage' $WORK/R1/out.md)"
fi

# ── R2: failure beats success and pending in row precedence ──────────────────
echo "── R2: failure precedence ──"
setup_fixture R2
cat > "$WORK/R2/payload.json" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/quickstart/foo","state":"failure","target_url":"http://example/build/1","created_at":"2026-05-14T10:00:00Z"}
]}
JSON
render R2
if grep -q '🔴 .samples/python/quickstart/foo.' "$WORK/R2/out.md"; then
    pass "R2"
else
    fail "R2" "failure row not red"
fi

# ── R3: pending beats success ────────────────────────────────────────────────
echo "── R3: pending precedence ──"
setup_fixture R3
cat > "$WORK/R3/payload.json" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/quickstart/foo","state":"pending","target_url":"http://example/build/p","created_at":"2026-05-14T10:00:00Z"}
]}
JSON
render R3
if grep -q '🟡 .samples/python/quickstart/foo.' "$WORK/R3/out.md"; then
    pass "R3"
else
    fail "R3" "pending row not yellow"
fi

# ── R4: partial-ungated multi-reporter sample is ungated, NOT collapsed green ─
echo "── R4: partial-ungated multi-reporter sample stays visible (not green) ──"
setup_fixture R4
cat > "$WORK/R4/payload.json" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/hosted-agents/agent-framework/multi","state":"success","target_url":"http://example/build/m","created_at":"2026-05-14T10:00:00Z"}
]}
JSON
render R4
# The 'multi' sample has BOTH sample.yaml AND agent.manifest.yaml in the same
# dir, so it's expected by both ado-build AND hosted-agents-e2e. Only ado-build
# reported (success). Per the bug fix: the row must surface as ungated (⚪) at
# sample-cell level (NOT 🟢). Also assert the renderer never emits a <details>
# collapse block — green rows stay inline per design.
#
# Strategy: the row containing 🟢 (the only success in this fixture) must be
# the main-table row for 'multi'. If it starts with ⚪ as the sample-cell
# emoji, the partial-ungated bug is fixed. If it starts with 🟢 (i.e. the
# entire row is treated as green), the bug is present.
green_row="$(grep -F '🟢' "$WORK/R4/out.md" | grep -F 'multi' | head -1 || true)"
if [[ -z "$green_row" ]]; then
    fail "R4" "no row containing 🟢 and 'multi' found — fixture or renderer broken"
elif [[ "$green_row" == *"| 🟢 \`samples/python/hosted-agents/agent-framework/multi\`"* ]]; then
    fail "R4" "partial-ungated row marked green at sample-cell (bug present): $green_row"
elif [[ "$green_row" == *"| ⚪ \`samples/python/hosted-agents/agent-framework/multi\`"* ]]; then
    if grep -qF '<details>' "$WORK/R4/out.md"; then
        fail "R4" "renderer emitted <details> collapse block — green rows must stay inline"
    else
        pass "R4"
    fi
else
    fail "R4" "unexpected row shape: $green_row"
fi

# ── R5: evidence column carries non-success target_urls only ────────────────
echo "── R5: evidence column contents ──"
setup_fixture R5
cat > "$WORK/R5/payload.json" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/quickstart/foo","state":"failure","target_url":"http://example/build/F","created_at":"2026-05-14T10:00:00Z"},
  {"context":"validation/hosted-agents-e2e/samples--python--hosted-agents--agent-framework--responses--01-basic","state":"success","target_url":"http://example/build/S","created_at":"2026-05-14T10:00:00Z"}
]}
JSON
render R5
foo_line="$(grep 'samples/python/quickstart/foo' "$WORK/R5/out.md" | head -1)"
basic_line="$(grep 'samples/python/hosted-agents/agent-framework/responses/01-basic' "$WORK/R5/out.md" | head -1)"
ok=1
if ! echo "$foo_line"   | grep -q 'http://example/build/F'; then ok=0; fail "R5" "failure row missing its target_url: $foo_line"; fi
if echo "$basic_line"   | grep -q 'http://example/build/S'  ; then ok=0; fail "R5" "success row leaked target_url into evidence: $basic_line"; fi
(( ok == 1 )) && pass "R5"

# ── R6: ungated section lists expected pairs with no reporter ────────────────
echo "── R6: ungated section ──"
setup_fixture R6
cat > "$WORK/R6/payload.json" <<'JSON'
{"statuses":[]}
JSON
render R6
if grep -q '## Ungated' "$WORK/R6/out.md" \
   && grep -q '| .ado-build. | .samples/python/quickstart/foo. |' "$WORK/R6/out.md" \
   && grep -q '| .hosted-agents-e2e. | .samples/python/hosted-agents/agent-framework/responses/01-basic. |' "$WORK/R6/out.md"; then
    pass "R6"
else
    fail "R6" "ungated section missing or incomplete"
fi

# ── R7: markdown escaping for pipe in path (defensive — shouldn't occur in practice) ─
echo "── R7: markdown pipe escaping in evidence url ──"
setup_fixture R7
cat > "$WORK/R7/payload.json" <<'JSON'
{"statuses":[
  {"context":"validation/ado-build/samples/python/quickstart/foo","state":"failure","target_url":"http://x/a|b","created_at":"2026-05-14T10:00:00Z"}
]}
JSON
render R7
if grep -q 'http://x/a%7Cb' "$WORK/R7/out.md"; then
    pass "R7"
else
    fail "R7" "pipe in target_url not URL-encoded (would break table); evidence cell: $(grep -F 'samples/python/quickstart/foo' $WORK/R7/out.md)"
fi

echo
echo "════════════════════════════════════════════════════"
echo "  Renderer tests run: $((PASS+FAIL))  |  Passed: $PASS  |  Failed: $FAIL"
echo "════════════════════════════════════════════════════"
exit $(( FAIL > 0 ? 1 : 0 ))
