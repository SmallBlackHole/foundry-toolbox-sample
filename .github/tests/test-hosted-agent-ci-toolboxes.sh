#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
prepare="$repo_root/.github/scripts/prepare-hosted-agent-ci-toolboxes.sh"
cleanup="$repo_root/.github/scripts/cleanup-hosted-agent-ci-toolboxes.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local want=$1 got=$2 message=$3
  [ "$want" = "$got" ] || fail "$message (want=$want got=$got)"
}

command -v yq >/dev/null || fail "yq is required"
command -v jq >/dev/null || fail "jq is required"

cat > "$work/original.yaml" <<'YAML'
name: toolbox-test
services:
  ai-project:
    host: azure.ai.project
  agent-tools:
    host: azure.ai.toolbox
    uses: [ai-project]
    tools:
      - type: code_interpreter
        # This unrelated literal intentionally collides with the toolbox key;
        # only structural toolbox references should be rewritten.
        name: agent-tools
  test-agent:
    host: azure.ai.agent
    uses: [ai-project, agent-tools]
    environmentVariables:
      - name: TOOLBOX_NAME
        value: agent-tools
      - name: TOOLBOX_ENDPOINT
        value: ${TOOLBOX_AGENT_TOOLS_MCP_ENDPOINT}
YAML

cp "$work/original.yaml" "$work/a.yaml"
"$prepare" "$work/a.yaml" "$work/a-state.json" 12345 2 sample-container >/dev/null
name_a=$(jq -r '.toolboxes[0].name' "$work/a-state.json")
[[ "$name_a" == ci-e2e-tb-* ]] || fail "generated name must use the reserved prefix"
[ "${#name_a}" -le 63 ] || fail "generated name exceeds 63 characters"
[[ "$name_a" =~ ^[A-Za-z0-9_-]+$ ]] || fail "generated name contains invalid characters"
assert_eq "$name_a" "$(yq -r '.services | to_entries[] | select(.value.host == "azure.ai.toolbox") | .key' "$work/a.yaml")" "toolbox service key was not rewritten"
assert_eq "$name_a" "$(yq -r '.services.test-agent.uses[1]' "$work/a.yaml")" "uses reference was not rewritten"
assert_eq "$name_a" "$(yq -r '.services.test-agent.environmentVariables[] | select(.name == "TOOLBOX_NAME") | .value' "$work/a.yaml")" "TOOLBOX_NAME was not rewritten"
assert_eq agent-tools "$(yq -r '.services[] | select(.host == "azure.ai.toolbox") | .tools[0].name' "$work/a.yaml")" "unrelated matching scalar must not be rewritten"
expected_endpoint_key=$(jq -r '.toolboxes[0].endpoint_key' "$work/a-state.json")
assert_eq "\${$expected_endpoint_key}" "$(yq -r '.services.test-agent.environmentVariables[] | select(.name == "TOOLBOX_ENDPOINT") | .value' "$work/a.yaml")" "derived endpoint key was not rewritten"

cp "$work/original.yaml" "$work/a-repeat.yaml"
"$prepare" "$work/a-repeat.yaml" "$work/a-repeat-state.json" 12345 2 sample-container >/dev/null
assert_eq "$name_a" "$(jq -r '.toolboxes[0].name' "$work/a-repeat-state.json")" "same cell must generate a deterministic name"

cp "$work/original.yaml" "$work/b.yaml"
"$prepare" "$work/b.yaml" "$work/b-state.json" 12345 2 sample-code >/dev/null
name_b=$(jq -r '.toolboxes[0].name' "$work/b-state.json")
[ "$name_a" != "$name_b" ] || fail "different cells must generate different names"

cat > "$work/no-toolbox.yaml" <<'YAML'
name: no-toolbox
services:
  test-agent:
    host: azure.ai.agent
YAML
"$prepare" "$work/no-toolbox.yaml" "$work/empty-state.json" 12345 1 no-toolbox >/dev/null
assert_eq 0 "$(jq '.toolboxes | length' "$work/empty-state.json")" "manifest without a toolbox must produce empty state"

cat > "$work/multiple.yaml" <<'YAML'
name: multiple-toolboxes
services:
  ai-project:
    host: azure.ai.project
  first-tools:
    host: azure.ai.toolbox
    uses: [ai-project]
  second-tools:
    host: azure.ai.toolbox
    uses: [ai-project]
  test-agent:
    host: azure.ai.agent
    uses: [ai-project, first-tools, second-tools]
YAML
"$prepare" "$work/multiple.yaml" "$work/multiple-state.json" 12345 1 multiple >/dev/null
assert_eq 2 "$(jq '.toolboxes | length' "$work/multiple-state.json")" "all toolbox services must be isolated"
# shellcheck disable=SC2016 # $services is a yq variable, not a shell variable.
assert_eq 0 "$(yq '[.services as $services | .services[] | .uses[]? | select($services[.] == null)] | length' "$work/multiple.yaml")" "multiple-toolbox rewrite left a dangling use"

# Mock the azd toolbox CRUD surface so cleanup behavior is deterministic and
# does not require Azure credentials.
mkdir -p "$work/bin" "$work/times"
cat > "$work/bin/azd" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = ai ] && [ "$2" = toolbox ] || exit 2
shift 2
case "$1" in
  list)
    cat "$MOCK_AZD_STORE"
    ;;
  delete)
    name=$2
    if [ "$name" != "${MOCK_AZD_DELETE_NOOP_NAME:-}" ]; then
      jq --arg name "$name" '.toolboxes |= map(select(.name != $name))' "$MOCK_AZD_STORE" > "$MOCK_AZD_STORE.tmp"
      mv "$MOCK_AZD_STORE.tmp" "$MOCK_AZD_STORE"
    fi
    jq -n --arg name "$name" '{name:$name,outcome:"deleted"}'
    ;;
  versions)
    [ "$2" = list ] || exit 2
    name=$3
    created=$(cat "$MOCK_AZD_TIMES/$name")
    field=${MOCK_AZD_CREATED_FIELD:-created_at}
    jq -n --arg name "$name" --arg field "$field" --arg created "$created" '
      {toolbox:$name,default_version:"1",versions:[{version:"1"}]} |
      .versions[0][$field] = (if ($created | test("^[0-9]+$")) then ($created | tonumber) else $created end)
    '
    ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$work/bin/azd"
export PATH="$work/bin:$PATH"
export MOCK_AZD_STORE="$work/live.json"
export MOCK_AZD_TIMES="$work/times"

jq -n --arg generated "$name_a" '{toolboxes:[{name:$generated},{name:"external-shared-toolbox"}]}' > "$MOCK_AZD_STORE"
"$cleanup" cell "$work/a-state.json" https://example.test/project "$work/cell-cleanup.json" >/dev/null
assert_eq 0 "$(jq --arg name "$name_a" '[.toolboxes[] | select(.name == $name)] | length' "$MOCK_AZD_STORE")" "cell-owned toolbox was not deleted"
assert_eq 1 "$(jq '[.toolboxes[] | select(.name == "external-shared-toolbox")] | length' "$MOCK_AZD_STORE")" "external toolbox must not be deleted"
assert_eq deleted "$(jq -r '.results[0].outcome' "$work/cell-cleanup.json")" "cleanup result must report deletion"

# Cleanup is idempotent when deploy failed before creating the toolbox.
"$cleanup" cell "$work/a-state.json" https://example.test/project "$work/cell-cleanup-again.json" >/dev/null
assert_eq not_found "$(jq -r '.results[0].outcome' "$work/cell-cleanup-again.json")" "missing toolbox must be a successful no-op"

# A delete that reports success but leaves the resource behind must fail with
# one unambiguous still_present result.
jq -n --arg generated "$name_a" '{toolboxes:[{name:$generated}]}' > "$MOCK_AZD_STORE"
export MOCK_AZD_DELETE_NOOP_NAME="$name_a"
set +e
"$cleanup" cell "$work/a-state.json" https://example.test/project "$work/cell-still-present.json" >/dev/null
cleanup_exit=$?
set -e
unset MOCK_AZD_DELETE_NOOP_NAME
assert_eq 1 "$cleanup_exit" "cleanup must fail when deletion cannot be verified"
assert_eq 1 "$(jq '.results | length' "$work/cell-still-present.json")" "cleanup result must not contain contradictory duplicates"
assert_eq still_present "$(jq -r '.results[0].outcome' "$work/cell-still-present.json")" "cleanup must report the verified final state"

now=$(date +%s)
old_name=ci-e2e-tb-old-000000000001
recent_name=ci-e2e-tb-recent-000000000002
unknown_name=ci-e2e-tb-unknown-000000000003
jq -n --arg old "$old_name" --arg recent "$recent_name" --arg unknown "$unknown_name" \
  '{toolboxes:[{name:$old},{name:$recent},{name:$unknown},{name:"external-shared-toolbox"}]}' > "$MOCK_AZD_STORE"
# Exercise epoch-milliseconds and alternate createdAt casing.
echo $(((now - 90000) * 1000)) > "$MOCK_AZD_TIMES/$old_name"
date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ > "$MOCK_AZD_TIMES/$recent_name"
echo not-a-timestamp > "$MOCK_AZD_TIMES/$unknown_name"
export MOCK_AZD_CREATED_FIELD=createdAt
"$cleanup" orphans https://example.test/project 86400 "$work/orphan-cleanup.json" >/dev/null
unset MOCK_AZD_CREATED_FIELD
assert_eq 0 "$(jq --arg name "$old_name" '[.toolboxes[] | select(.name == $name)] | length' "$MOCK_AZD_STORE")" "stale CI toolbox was not deleted"
assert_eq 1 "$(jq --arg name "$recent_name" '[.toolboxes[] | select(.name == $name)] | length' "$MOCK_AZD_STORE")" "recent CI toolbox must be retained"
assert_eq 1 "$(jq --arg name "$unknown_name" '[.toolboxes[] | select(.name == $name)] | length' "$MOCK_AZD_STORE")" "unknown-age toolbox must be retained"
assert_eq retained_unknown_age "$(jq -r --arg name "$unknown_name" '.results[] | select(.name == $name) | .outcome' "$work/orphan-cleanup.json")" "unknown timestamp must fail closed"
assert_eq 1 "$(jq '[.toolboxes[] | select(.name == "external-shared-toolbox")] | length' "$MOCK_AZD_STORE")" "orphan cleanup must not touch external toolbox"

echo "PASS: hosted-agent CI toolbox lifecycle"
