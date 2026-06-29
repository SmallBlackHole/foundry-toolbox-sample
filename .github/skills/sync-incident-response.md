# Sync Incident Response

Authoritative playbook for diagnosing and recovering from `sync-to-public` pipeline failures.
Read this file completely before taking any action when a sync run fails.

## 1. Get the failure log

```bash
# View the run summary — identify which job/step failed
gh run view <run-id> --repo microsoft-foundry/foundry-samples-pr

# Download the full log (pipe to a file — it can be 50–100KB)
gh run view <run-id> --repo microsoft-foundry/foundry-samples-pr --log > /tmp/sync-run.log
```

The failing step is almost always **"Run sync pipeline"** which calls `sync-core.sh`.
Check `public-overlay/.github/scripts/mirror-back.sh` failures separately via the
`mirror-back` workflow (`microsoft-foundry/foundry-samples` Actions tab).

---

## 2. Identify the failure type

Run these greps against the log in order:

```bash
# Type A — marks drift / object not found
grep -E "object not found|seed-marks recovery|Tree mismatch|fatal:" /tmp/sync-run.log

# Type B — protected-paths guard
grep "Protected-paths guard" /tmp/sync-run.log

# Type C — mirror-back workflow (check separately on PUBLIC repo)
# Go to https://github.com/microsoft-foundry/foundry-samples/actions/workflows/mirror-back.yml
# Look for "Skipping sync-App commit" in recent successful(!)-but-wrong runs
```

| Signal in log | Failure type | Jump to |
|---------------|-------------|---------|
| `object not found: <sha>` during fast-import | Marks drift | §3 |
| `seed-marks recovery failed — likely true drift` | Marks drift | §3 |
| `Protected-paths guard FAILED` | Protected-paths | §4 |
| `mirror-back` run on public shows `Skipping sync-App commit <sha>` for a human commit | Mirror-back false-positive | §5 |

---

## 3. Marks drift — diagnosis and recovery

### What happened

The marks cache references a blob that doesn't exist in the runner's clone of the
public repo. This almost always means public has a commit that mirror-back silently
dropped, causing public to drift from what the marks expected.

### Diagnose the tree mismatch

The seed-marks recovery script prints a diff of what private and public think a
file should contain. Look for lines like:

```
@@  private.tree   public.tree
-   <sha1>   samples/path/to/file   (private blob)
+   <sha2>   samples/path/to/file   (public blob)
```

That file — and those two SHAs — are the entire divergence. Identify who introduced
the public-side change by checking `microsoft-foundry/foundry-samples` commits.

### Confirm mirror-back dropped the commit

1. Find the public commit SHA that introduced the diverging blob (check public repo history).
2. Find the corresponding `mirror-back` workflow run on the public repo.
3. In that run's log, grep for:
   ```
   Skipping sync-App commit <sha>
   ```
   If present, mirror-back falsely classified a human PR as a bot commit. This was the
   root cause in the **2026-06-29 incident** (ADO 5398977, fixed in PR #620).

### Recovery decision table

| Scenario | Recovery action |
|----------|----------------|
| Private is correct, public regressed | `workflow_dispatch` → `force_full: true` |
| Public has a legitimate change not yet in private | Bring to private via PR → merge → `seed_from_public_sha=<public-HEAD>` |
| Trees differ only due to historical block-list | `seed_from_public_sha=<public-HEAD>` + `seed_blocked_paths=<list>` |

**`force_full` details:** Discards the marks cache entirely and does a full re-export
from private. Overwrites public with private's view. Safe when private is authoritative
and public regressed. Triggered via:
```bash
gh workflow run sync-to-public.yml \
  --repo microsoft-foundry/foundry-samples-pr \
  --field force_full=true
```

**`seed_from_public_sha` details:** Re-synthesizes marks from a known-good public SHA
by requiring the trees to be equivalent (or equivalent modulo `seed_blocked_paths`).
Use when you first fix the drift in private, then want to re-anchor without losing history.

---

## 4. Protected-paths guard failure

The guard refused to push because the sync branch would delete or modify a
public-only workflow file (`redirect-pull-requests.yml`, `mirror-back.yml`, or `run-setup.yml`).

Recovery:
1. If the workflow is missing from public main, restore it via a direct human PR on public first.
2. Then re-anchor marks: `workflow_dispatch` → `seed_from_public_sha=<new-public-HEAD>`.

Full procedure in `docs/sync-cutover-runbook.md` and the
[Sync Recovery Runbook](https://msdata.visualstudio.com/Vienna/_git/foundry-devx-eng-docs?path=/operations/sync-recovery-runbook.md).

---

## 5. Mirror-back false-positive

Mirror-back (`public-overlay/.github/scripts/mirror-back.sh`) skips commits whose
**author** matches a sync-bot identity. It does NOT skip based on committer alone.

Relevant identities (`PRIMARY_SYNC_BOT` / `LEGACY_SYNC_BOT` at top of script):
```
PRIMARY_SYNC_BOT = foundry-samples-repo-sync[bot]
LEGACY_SYNC_BOT  = foundry-samples-sync[bot]
```
(and their corresponding `@users.noreply.github.com` emails — check lines 9–10 of the script for current values)

**Known edge case:** When `wait-and-merge.sh` calls `gh pr merge --rebase` as the App,
GitHub records the App as the **committer** but preserves the human as the **author**.
Pre-fix (before PR #620), mirror-back checked all four identity fields and would skip
these commits. Post-fix, only author is checked, so human-authored commits always
produce a mirror branch regardless of committer.

If you suspect other human public PRs were silently dropped before the fix (merged
between ~2026-06-04 and 2026-06-29), audit public repo commits in that range:
```bash
gh api repos/microsoft-foundry/foundry-samples/commits \
  --paginate --jq '.[] | {sha: .sha, author: .author.login, committer: .committer.login, msg: .commit.message}' \
  | grep -v '"author":"foundry-samples-repo-sync\[bot\]"'
```
Any commit whose author is human but that has no corresponding private-side mirror
was likely silently dropped.

---

## 6. Key files reference

| File | Purpose |
|------|---------|
| `.github/scripts/sync-core.sh` | Main sync driver; marks cache load/save, `git fast-import`, auto seed-marks recovery |
| `.github/scripts/seed-marks-from-public.sh` | Synthesizes fresh marks from a known-good public SHA; called by sync-core and manually via `seed_from_public_sha` input |
| `public-overlay/.github/scripts/mirror-back.sh` | Runs on public repo; detects human commits and opens mirror PRs in private |
| `.github/tests/test-mirror-back.sh` | Unit test harness for mirror-back; bash, stubbed `gh`, runs via WSL |
| `.github/sync-config.json` | Public repo target, exclude list, protected paths |
| `docs/repo-sync-automation.md` | Authoritative design doc — marks cache, mirror-back, recovery inputs, troubleshooting |
| `docs/sync-cutover-runbook.md` | One-time surgery procedure (not for routine incidents) |

---

## 7. Running the mirror-back tests

```bash
# From the repo root (WSL required on Windows)
bash .github/tests/test-mirror-back.sh
```

Tests: MB1 clean replay, MB2 no-identity filter, MB3 bot-skip, **MB4 human-author+bot-committer (regression for #620)**, MB5 idempotency, MB6 dry-run, MB7 zero-before, MB8 helpers, MB9 conflict.
