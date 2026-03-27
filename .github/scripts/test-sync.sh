#!/usr/bin/env bash
#
# test-sync.sh — Unit and integration tests for the sync pipeline.
#
# Runs against the real sync-lib.sh functions (not a reimplementation).
# Exit code 0 = all tests passed, non-zero = failures.
#
set -euo pipefail

# Ensure jq is on PATH (may be in ~/bin on dev machines)
export PATH="$PATH:$HOME/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sync-lib.sh"

PASS=0
FAIL=0
CURRENT_SUITE=""

# ── Test framework ───────────────────────────────────────────────────────────

suite() { CURRENT_SUITE="$1"; echo ""; echo "═══ $1 ═══"; }

assert_ok() {
  local desc="$1"; shift
  if "$@" 2>/dev/null; then
    echo "  ✓ $desc"; PASS=$((PASS + 1))
  else
    echo "  ✗ $desc  [expected success, got failure]"; FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local desc="$1"; shift
  if "$@" 2>/dev/null; then
    echo "  ✗ $desc  [expected failure, got success]"; FAIL=$((FAIL + 1))
  else
    echo "  ✓ $desc"; PASS=$((PASS + 1))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ✓ $desc"; PASS=$((PASS + 1))
  else
    echo "  ✗ $desc  [expected '$expected', got '$actual']"; FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    echo "  ✓ $desc"; PASS=$((PASS + 1))
  else
    echo "  ✗ $desc  [pattern '$pattern' not found in $file]"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    echo "  ✗ $desc  [pattern '$pattern' unexpectedly found in $file]"; FAIL=$((FAIL + 1))
  else
    echo "  ✓ $desc"; PASS=$((PASS + 1))
  fi
}

# ── Setup: temp directory tree mimicking a private repo ──────────────────────

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

setup_mock_private_dir() {
  PRIVATE_DIR="$TMPDIR_ROOT/private"
  rm -rf "$PRIVATE_DIR"
  mkdir -p "$PRIVATE_DIR"

  # Standard sample with sample.yaml
  mkdir -p "$PRIVATE_DIR/samples/python/quickstart/create-agent"
  echo "name: create-agent" > "$PRIVATE_DIR/samples/python/quickstart/create-agent/sample.yaml"
  echo "print('hello')" > "$PRIVATE_DIR/samples/python/quickstart/create-agent/main.py"
  echo "# Create Agent" > "$PRIVATE_DIR/samples/python/quickstart/create-agent/README.md"

  # Another sample that will be "failed"
  mkdir -p "$PRIVATE_DIR/samples/python/quickstart/chat-agent"
  echo "name: chat-agent" > "$PRIVATE_DIR/samples/python/quickstart/chat-agent/sample.yaml"
  echo "print('chat')" > "$PRIVATE_DIR/samples/python/quickstart/chat-agent/main.py"

  # Container directory with sub-samples (no sample.yaml at container level)
  mkdir -p "$PRIVATE_DIR/samples/csharp/hosted-agents/AgentFramework/AgentsInWorkflows"
  echo "using System;" > "$PRIVATE_DIR/samples/csharp/hosted-agents/AgentFramework/AgentsInWorkflows/Program.cs"
  echo "# Agents" > "$PRIVATE_DIR/samples/csharp/hosted-agents/AgentFramework/AgentsInWorkflows/README.md"
  echo "image: mcr" > "$PRIVATE_DIR/samples/csharp/hosted-agents/AgentFramework/AgentsInWorkflows/agent.yaml"

  mkdir -p "$PRIVATE_DIR/samples/csharp/hosted-agents/AgentFramework/AgentWithTools"
  echo "using System;" > "$PRIVATE_DIR/samples/csharp/hosted-agents/AgentFramework/AgentWithTools/Program.cs"
  echo "# Tools" > "$PRIVATE_DIR/samples/csharp/hosted-agents/AgentFramework/AgentWithTools/README.md"

  # Excluded paths
  mkdir -p "$PRIVATE_DIR/internal/docs"
  echo "secret" > "$PRIVATE_DIR/internal/docs/notes.md"
  mkdir -p "$PRIVATE_DIR/.github"
  echo "* @team" > "$PRIVATE_DIR/.github/CODEOWNERS"
  echo "# Private" > "$PRIVATE_DIR/README.md"
  echo "# Contributing" > "$PRIVATE_DIR/CONTRIBUTING.md"

  # Non-sample file under samples/
  echo "# Samples" > "$PRIVATE_DIR/samples/overview.md"
}

setup_default_excludes() {
  EXCLUDE_DIRS=("internal/" ".azure-pipelines/" ".github/")
  EXCLUDE_FILES=("CONTRIBUTING.md" "README.md")
}

setup_no_gating() {
  GATING_ENABLED=false
  declare -gA VALIDATED_SAMPLES=()
}

setup_gating_with_manifest() {
  GATING_ENABLED=true
  declare -gA VALIDATED_SAMPLES=(
    ["samples/python/quickstart/create-agent"]="passed"
    ["samples/python/quickstart/chat-agent"]="failed"
    ["samples/csharp/hosted-agents/AgentFramework/AgentsInWorkflows"]="skipped"
  )
}

# ═════════════════════════════════════════════════════════════════════════════
# UNIT TESTS
# ═════════════════════════════════════════════════════════════════════════════

# ── should_sync: exclusion logic (no gating) ─────────────────────────────────

suite "should_sync — exclusion logic (no gating)"
setup_mock_private_dir
setup_default_excludes
setup_no_gating

assert_ok   "regular file syncs"                   should_sync "samples/python/quickstart/create-agent/main.py"
assert_ok   ".github/CODEOWNERS always syncs"       should_sync ".github/CODEOWNERS"
assert_fail "root README.md is excluded"            should_sync "README.md"
assert_fail "root CONTRIBUTING.md is excluded"      should_sync "CONTRIBUTING.md"
assert_ok   "subdirectory README.md is NOT excluded" should_sync "samples/python/quickstart/create-agent/README.md"
assert_fail "internal/ path is excluded"            should_sync "internal/docs/notes.md"
assert_fail ".azure-pipelines/ is excluded"         should_sync ".azure-pipelines/validation.yml"
assert_fail ".github/ non-CODEOWNERS is excluded"   should_sync ".github/workflows/sync.yml"
assert_ok   "top-level file syncs"                  should_sync "tox.ini"
assert_ok   "samples/overview.md syncs"             should_sync "samples/overview.md"

# ── should_sync: gating with manifest ────────────────────────────────────────

suite "should_sync — validation gating"
setup_mock_private_dir
setup_default_excludes
setup_gating_with_manifest

assert_ok   "passed sample file syncs"              should_sync "samples/python/quickstart/create-agent/main.py"
assert_fail "failed sample file is blocked"         should_sync "samples/python/quickstart/chat-agent/main.py"
assert_fail "skipped manifest entry is blocked"     should_sync "samples/csharp/hosted-agents/AgentFramework/AgentsInWorkflows/Program.cs"
assert_ok   "non-sample file under samples/ syncs"  should_sync "samples/overview.md"
assert_ok   "file outside samples/ unaffected"      should_sync "tox.ini"
assert_ok   "CODEOWNERS still syncs with gating"    should_sync ".github/CODEOWNERS"
assert_fail "root README.md still excluded"         should_sync "README.md"

# ── should_sync: no sample.yaml fallthrough ──────────────────────────────────

suite "should_sync — no sample.yaml fallthrough (regression)"
setup_mock_private_dir
setup_default_excludes
# Gating enabled but manifest does NOT include the AgentWithTools path
declare -gA VALIDATED_SAMPLES=(
  ["samples/python/quickstart/create-agent"]="passed"
)
GATING_ENABLED=true

assert_ok "file under unrecognised sample (no sample.yaml, no manifest) syncs" \
  should_sync "samples/csharp/hosted-agents/AgentFramework/AgentWithTools/Program.cs"
assert_ok "README.md under unrecognised sample syncs" \
  should_sync "samples/csharp/hosted-agents/AgentFramework/AgentWithTools/README.md"

# ── find_sample_root ─────────────────────────────────────────────────────────

suite "find_sample_root"
setup_mock_private_dir

result=$(find_sample_root "samples/python/quickstart/create-agent/main.py")
assert_eq "finds sample root with sample.yaml" \
  "samples/python/quickstart/create-agent" "$result"

result=$(find_sample_root "samples/csharp/hosted-agents/AgentFramework/AgentsInWorkflows/Program.cs")
assert_eq "returns empty for dir without sample.yaml" "" "$result"

result=$(find_sample_root "tox.ini")
assert_eq "returns empty for non-sample file" "" "$result"

# ── write_rsync_excludes: anchoring ──────────────────────────────────────────

suite "write_rsync_excludes — anchoring"
setup_default_excludes
write_rsync_excludes

assert_contains     "internal/ is anchored"     /tmp/sync-excludes.txt "/internal/"
assert_contains     ".github/ is anchored"      /tmp/sync-excludes.txt "/.github/"
assert_contains     "README.md is anchored"     /tmp/sync-excludes.txt "/README.md"
assert_contains     "CONTRIBUTING.md anchored"   /tmp/sync-excludes.txt "/CONTRIBUTING.md"
assert_contains     ".git/ is anchored"         /tmp/sync-excludes.txt "/.git/"
# Verify no unanchored entries (every non-empty line should start with /)
UNANCHORED=$(grep -c '^[^/]' /tmp/sync-excludes.txt 2>/dev/null || true)
assert_eq "all entries are anchored" "0" "$UNANCHORED"

# Specifically verify no bare README.md (without leading /)
BARE_README=$(grep -c '^README.md' /tmp/sync-excludes.txt 2>/dev/null || true)
assert_eq "no bare README.md entry" "0" "$BARE_README"

# ── build_gating_excludes: container directories ─────────────────────────────

suite "build_gating_excludes — container vs sample root (regression)"
setup_mock_private_dir
setup_default_excludes
write_rsync_excludes
setup_gating_with_manifest
build_gating_excludes

# The failed sample should be excluded
assert_contains "failed sample excluded from rsync" \
  /tmp/sync-excludes.txt "/samples/python/quickstart/chat-agent/"

# The skipped manifest entry should be excluded
assert_contains "skipped manifest entry excluded" \
  /tmp/sync-excludes.txt "/samples/csharp/hosted-agents/AgentFramework/AgentsInWorkflows/"

# Container directory AgentFramework should NOT be excluded (no sample.yaml)
assert_not_contains "container dir NOT excluded (regression test)" \
  /tmp/sync-excludes.txt "/samples/csharp/hosted-agents/AgentFramework/***"

# Passed sample should NOT appear in excludes
assert_not_contains "passed sample NOT excluded" \
  /tmp/sync-excludes.txt "/samples/python/quickstart/create-agent/"

# ═════════════════════════════════════════════════════════════════════════════
# INTEGRATION TESTS
# ═════════════════════════════════════════════════════════════════════════════

suite "Integration: bootstrap sync (no .sync-sha)"

# Set up private repo as a real git repo
PRIV="$TMPDIR_ROOT/int-private"
PUB="$TMPDIR_ROOT/int-public"
rm -rf "$PRIV" "$PUB"

# Initialise private repo with content
mkdir -p "$PRIV"
git -C "$PRIV" init -b main --quiet
git -C "$PRIV" config user.name "Test" && git -C "$PRIV" config user.email "test@test.com"

mkdir -p "$PRIV/samples/python/quickstart/my-sample"
echo "name: my-sample" > "$PRIV/samples/python/quickstart/my-sample/sample.yaml"
echo "print(1)" > "$PRIV/samples/python/quickstart/my-sample/app.py"
echo "# My Sample" > "$PRIV/samples/python/quickstart/my-sample/README.md"

mkdir -p "$PRIV/samples/csharp/hosted/Framework/SubSample"
echo "code" > "$PRIV/samples/csharp/hosted/Framework/SubSample/Program.cs"
echo "# Sub" > "$PRIV/samples/csharp/hosted/Framework/SubSample/README.md"

mkdir -p "$PRIV/internal/secret"
echo "nope" > "$PRIV/internal/secret/data.txt"
mkdir -p "$PRIV/.github"
echo "* @team" > "$PRIV/.github/CODEOWNERS"
echo "# Private README" > "$PRIV/README.md"
echo "ok" > "$PRIV/conftest.py"

git -C "$PRIV" add -A && git -C "$PRIV" commit -m "initial" --quiet

# Initialise empty public repo
mkdir -p "$PUB"
git -C "$PUB" init -b main --quiet
git -C "$PUB" config user.name "Test" && git -C "$PUB" config user.email "test@test.com"
# Need at least one commit for public repo
echo "init" > "$PUB/.gitkeep"
git -C "$PUB" add -A && git -C "$PUB" commit -m "init" --quiet

# Write a minimal sync-config.json
cat > "$TMPDIR_ROOT/sync-config.json" <<'EOF'
{
  "exclude_paths": ["internal/", ".github/", "README.md", "CONTRIBUTING.md"],
  "public_repo": { "owner": "test", "name": "test" },
  "sync_branch_prefix": "sync/test"
}
EOF

# Run replay-commits.sh (bootstrap path — no .sync-sha)
PRIVATE_DIR="$PRIV"  # reset for sync-lib functions
BOOTSTRAP_EXIT=0
bash "$SCRIPT_DIR/replay-commits.sh" "$PRIV" "$PUB" "$TMPDIR_ROOT/sync-config.json" >/dev/null 2>"$TMPDIR_ROOT/bootstrap.log" || BOOTSTRAP_EXIT=$?
if [[ "$BOOTSTRAP_EXIT" -ne 0 ]]; then
  echo "  ⚠ replay-commits.sh exited $BOOTSTRAP_EXIT — log:"
  head -30 "$TMPDIR_ROOT/bootstrap.log"
fi

# Assertions
assert_ok "sample app.py synced" test -f "$PUB/samples/python/quickstart/my-sample/app.py"
assert_ok "sample README.md synced" test -f "$PUB/samples/python/quickstart/my-sample/README.md"
assert_ok "sub-sample Program.cs synced" test -f "$PUB/samples/csharp/hosted/Framework/SubSample/Program.cs"
assert_ok "sub-sample README.md synced" test -f "$PUB/samples/csharp/hosted/Framework/SubSample/README.md"
assert_ok "conftest.py synced" test -f "$PUB/conftest.py"
assert_ok "CODEOWNERS synced" test -f "$PUB/.github/CODEOWNERS"
assert_ok ".sync-sha written" test -f "$PUB/.github/.sync-sha"
assert_fail "internal/ NOT synced" test -f "$PUB/internal/secret/data.txt"
assert_fail "root README.md NOT synced" test -f "$PUB/README.md"

# ── Integration: commit replay (additions) ───────────────────────────────────

suite "Integration: commit replay — file addition"

echo "new_file" > "$PRIV/samples/csharp/hosted/Framework/SubSample/new.txt"
git -C "$PRIV" add -A && git -C "$PRIV" commit -m "add new file" --quiet

bash "$SCRIPT_DIR/replay-commits.sh" "$PRIV" "$PUB" "$TMPDIR_ROOT/sync-config.json" >/dev/null 2>"$TMPDIR_ROOT/replay-add.log" || echo "  ⚠ replay exit $?"

assert_ok "new file replayed to public" test -f "$PUB/samples/csharp/hosted/Framework/SubSample/new.txt"
CONTENT=$(cat "$PUB/samples/csharp/hosted/Framework/SubSample/new.txt" 2>/dev/null || true)
assert_eq "content matches" "new_file" "$CONTENT"

# ── Integration: commit replay (deletions) ───────────────────────────────────

suite "Integration: commit replay — file deletion"

rm -rf "$PRIV/samples/csharp/hosted/Framework/SubSample"
git -C "$PRIV" add -A && git -C "$PRIV" commit -m "delete SubSample" --quiet

bash "$SCRIPT_DIR/replay-commits.sh" "$PRIV" "$PUB" "$TMPDIR_ROOT/sync-config.json" >/dev/null 2>"$TMPDIR_ROOT/replay-del.log" || echo "  ⚠ replay exit $?"

assert_fail "deleted directory removed from public" test -d "$PUB/samples/csharp/hosted/Framework/SubSample"

# ── Integration: rsync catches drift ─────────────────────────────────────────

suite "Integration: rsync drift correction"

# Introduce stale file directly into public repo (simulating drift)
mkdir -p "$PUB/samples/stale-dir"
echo "stale" > "$PUB/samples/stale-dir/old.txt"
git -C "$PUB" add -A && git -C "$PUB" commit -m "manual drift" --quiet

# Make a trivial change in private to trigger a sync
echo "# updated" >> "$PRIV/conftest.py"
git -C "$PRIV" add -A && git -C "$PRIV" commit -m "trivial change" --quiet

bash "$SCRIPT_DIR/replay-commits.sh" "$PRIV" "$PUB" "$TMPDIR_ROOT/sync-config.json" >/dev/null 2>"$TMPDIR_ROOT/replay-drift.log" || echo "  ⚠ replay exit $?"

assert_fail "stale file removed by rsync" test -f "$PUB/samples/stale-dir/old.txt"

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Results ═══"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILED"
  exit 1
else
  echo "ALL TESTS PASSED"
  exit 0
fi
