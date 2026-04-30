# Repo Sync Automation

This document describes the automated sync pipeline that publishes content from `foundry-samples-pr` (private) to `foundry-samples` (public).

It owns the **sync workflow mechanics**: export/import, path exclusions, author rewriting, App-authenticated PR creation, wait-and-merge, drift verification, and the sync-time validation gate. The validation rules themselves live in [Validation Contract](validation-contract.md). The contract for pipelines that post validation statuses lives in [Validation Results Contract](validation-results-contract.md).

## Overview

```text
foundry-samples-pr (private)  ──── daily sync ────►  foundry-samples (public)
       │                                                   │
       │  Authors push here                                │  Customers read here
       │  Validation statuses live here                    │  Issues filed here
       │  Internal content lives here                      │
       └───────────────────────────────────────────────────┘
                         One-way sync only
```

- **Direction**: Private → Public only. The public repo never writes back.
- **Schedule**: Daily at 06:00 UTC + manual dispatch.
- **Mechanism**: `git fast-export` / `git fast-import` with path filtering and author rewriting.
- **Validation gate**: Before push, the sync gate filters out samples whose validation has not passed at the private `main` SHA being synced.
- **Automation**: GitHub Actions workflow in `.github/workflows/sync-to-public.yml`.

High-level flow:

```text
private main
  └─ read validation/* statuses on private HEAD
      └─ build per-run blocked-sample exclusions
          └─ fast-export with static + dynamic exclusions
              └─ filter stream / rewrite authors
                  └─ fast-import into public sync branch
                      └─ push branch / open PR / direct rebase merge as App
```

## How It Works

### 1. Evaluate sync gate

At the start of a sync run, the workflow evaluates validation statuses on the private commit being synced, normally `main` HEAD:

```bash
gh api repos/microsoft-foundry/foundry-samples-pr/commits/<sha>/status
```

Statuses whose context matches `validation/*` are interpreted according to [Validation Results Contract](validation-results-contract.md). The gate produces a per-run list of sample roots to hold back from public sync.

This list is **additional** to the static path exclusions in `.github/sync-config.json`. Static exclusions protect internal repo content. Dynamic gate exclusions hold back otherwise-syncable samples until validation is green.

### 2. Export and filter

The sync uses `git fast-export` to stream commits from the private repo, piped through a Python filter (`filter-stream.py`) that:

- Removes excluded paths from both sources:
  - static exclusions from `.github/sync-config.json`
  - dynamic per-run exclusions from the sync gate
- Rewrites author identities using `.github/sync-mailmap` (maps internal aliases to public-facing names)
- Preserves commit history structure where possible (merge commits, ordering)

### 3. Import into public repo

The filtered stream is imported into the public repo via `git fast-import`, creating a sync branch with the rewritten history.

### 4. Incremental sync via marks

The pipeline uses `git fast-export` / `fast-import` marks files to track what's already been synced. These are cached between runs, making subsequent syncs incremental — only new commits are processed.

If marks are unavailable or `force_full` is specified, a full re-export is performed.

Dynamic gate exclusions are per-run state, not durable repo policy. When a blocked sample later becomes unblocked, the next sync must include the now-eligible content. If marks interaction prevents that from happening cleanly, force a full re-export.

### 5. Push and PR

The sync branch is pushed to the public repo and a PR is created automatically:

- Stale sync PRs are closed first
- The new PR includes commit count, authors, and a rollback SHA
- The PR body lists the contributing authors verbatim from rewritten commits

### 6. Wait-and-merge (direct merge as the App)

After the PR is opened, `wait-and-merge.sh` polls the PR's check status and required-review state. Once all required checks pass and reviews are satisfied, the workflow performs a **direct rebase merge** as the GitHub App — it does **not** use `gh pr merge --auto`.

This matters because of how GitHub's branch ruleset bypass interacts with the merge queue. See [Public Repo Branch Protection & App Bypass](#public-repo-branch-protection--app-bypass) below for the full rationale; the short version is that `--auto` schedules the merge for GitHub's system process, which does not inherit the App's bypass-actor permission, so the merge gets blocked by required-reviews even though the App could merge directly.

## The Gate at Sync Time

The sync gate is a **per-sample block-list**. Default = sync. A sample is blocked only when a validation status says it is not safe to publish.

| Input | Behavior |
|-------|----------|
| `validation/<pipeline-id>/<sample-path>` = `success` | Does not block that sample. |
| `validation/<pipeline-id>/<sample-path>` = `failure` | Blocks that sample. |
| `validation/<pipeline-id>/<sample-path>` = `error` | Blocks that sample. |
| `validation/<pipeline-id>/<sample-path>` = `pending` | Blocks that sample; do not publish while validation is in progress. |
| No `validation/*` status for a sample | Grandfathered / untracked; does not block in v1. |

Rules:

1. The workflow queries the combined commit status for the private SHA being synced.
2. Only contexts matching `validation/*` participate in sync gating.
3. The sample path is parsed from the context convention defined in [Validation Results Contract](validation-results-contract.md).
4. If any validation context for a sample is `failure`, `error`, or `pending`, that sample root is added to the block-list.
5. The block-list is converted into per-run additional path exclusions.
6. The additional exclusions are layered on top of `.github/sync-config.json`.
7. Samples with no reporting pipeline are grandfathered: untracked = ungated.

Example:

```text
validation/ado-build/samples/python/quickstart-chat = success
validation/hosted-agents-e2e/samples/python/hosted-agents/echo-agent = pending
validation/ado-build/samples/python/hosted-agents/echo-agent = success
```

Result: `samples/python/quickstart-chat` can sync. `samples/python/hosted-agents/echo-agent` is held back because one reporting pipeline is still pending.

## Implementation Surface (v1)

The minimum implementation surface is intentionally small and additive.

| Component | Responsibility |
|-----------|----------------|
| Status reader | New script or inlined workflow step in `.github/workflows/sync-to-public.yml` that calls the GitHub Statuses API for private `main` HEAD and emits blocked sample paths with blocking contexts. |
| Dynamic exclusions | `sync-core.sh` accepts a per-run exclusion list in addition to the static `exclude_pathspecs` in `.github/sync-config.json`. |
| Drift verification | `verify-sync.yml` / `verify-sync.sh` subtract gate-blocked samples from the expected public tree, so an intentional validation hold is not reported as drift. |
| Run summary | Each sync run emits a workflow log / job summary listing blocked samples and the non-success contexts that caused the block. Phase G can add richer reporting later. |

<!-- TODO(C2): Wire the status reader and dynamic exclusion input into sync-to-public.yml. -->
<!-- TODO(C2): Extend sync-core.sh to consume a dynamic per-run exclusion list. -->
<!-- E-tests: Phase E pins the dynamic exclusion input as SYNC_BLOCKED_PATHS, a colon-separated list of repo-relative path roots. -->
<!-- TODO(C2): Extend verify-sync.sh so drift excludes currently gate-blocked samples. -->

## Exclusions

Static paths excluded from sync are defined in `.github/sync-config.json`:

```json
{
  "exclude_pathspecs": [
    ":!internal/",
    ":!docs/",
    ":!.azure-pipelines/",
    ":!.github/",
    ":!CONTRIBUTING.md",
    ":!README.md"
  ]
}
```

| Excluded path | Reason |
|---------------|--------|
| `internal/` | Internal tooling, scripts, and docs not for public consumption |
| `docs/` | Internal governance, validation, and sync documentation |
| `.azure-pipelines/` | ADO pipeline config (CI infra is private) |
| `.github/` | Workflows, sync scripts, and config (sync infra is private) |
| `CONTRIBUTING.md` | Private-repo contributing guide (public repo has its own) |
| `README.md` | Private-repo README (public repo has its own) |

Dynamic validation exclusions are generated at sync time. They must not be added to `.github/sync-config.json` unless the path should be permanently internal.

### What IS synced

Everything not in the static exclusion list and not blocked by validation, primarily:

- `samples/` — sample code that is either passing validation or untracked / grandfathered
- `CODEOWNERS` — ownership mappings, handled specially despite `.github/` exclusion
- Any other top-level public content, such as `LICENSE`

## Author Rewriting

The sync rewrites commit author information using `.github/sync-mailmap`. This maps internal Microsoft aliases to public-facing identities, ensuring:

- Commits appear under the author's public GitHub identity
- Internal email addresses are not exposed in public git history
- Attribution is preserved accurately

Validation statuses are not part of author rewriting. They remain attached to private-repo SHAs and are consumed before export.

## Authentication

The sync uses a **GitHub App** (`foundry-samples-repo-sync`) for authentication to the public repo:

- Short-lived tokens scoped to the public repository only
- No Personal Access Tokens (PATs) for public sync — eliminates token rotation burden
- App installation is managed via GitHub org settings

The status-reading step queries statuses in the private repo. It should use credentials available to the workflow with read access to `microsoft-foundry/foundry-samples-pr`. The status-posting credentials for validation pipelines are defined in [Validation Results Contract](validation-results-contract.md).

## Workflow Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `dry_run` | boolean | `false` | Builds sync branch and pushes, but does NOT create a PR or update marks cache |
| `force_full` | boolean | `false` | Discards marks cache and performs a full re-export |

## Drift Verification

A separate workflow, `.github/workflows/verify-sync.yml`, runs after each sync and on demand to confirm that the public repo's `main` matches what private `main` *should* have produced.

The check is intentionally narrow:

- It compares `git ls-tree -r HEAD` of private `main` after exclusions against `git ls-tree -r HEAD` of public `main`.
- Expected private state applies both static exclusions and the current validation block-list.
- Drift = path missing in public, blob hash differs, or path present in public that should not be there.
- Output goes to the workflow run summary; persistent drift fails the run.

What drift verification does **not** check:

- **Author identity / mailmap correctness** — that's verified upstream during sync (`filter-stream.py` + `sync-mailmap`) and isn't re-derivable from a tree snapshot.
- **Commit message contents or history shape** — only the file tree at `HEAD` is compared.
- **Historical validation status** — v1 checks the current private `main` statuses. If a sample is currently gate-blocked, missing/stale public content for that sample is intentional, not drift.

The script is `.github/scripts/verify-sync.sh`.

## Operational Behavior

| Scenario | Behavior |
|----------|----------|
| Daily sync | Runs at 06:00 UTC. The gate consumes whatever statuses are current on private `main` HEAD at that moment. |
| Manual sync | Same gate behavior as scheduled sync. |
| Sample blocked at one sync | The sample is omitted from that sync. It recovers automatically at the next sync after its validation statuses go green. |
| Re-run validation flips status | Latest write wins for the same `(commit, context)`. A later `success` can unblock the sample for the next sync. |
| No reporting pipeline | Grandfathered in v1; the sample syncs unless another validation context reports a block for it. |
| Need to ship despite red validation | No break-glass override in v1. Fix validation or the sample. Break-glass is deferred to v2. |

Each run should emit a sync-time UX summary listing:

- blocked sample path
- blocking context(s)
- blocking state(s)
- `target_url` when provided by the reporter

For v1, workflow logs and `$GITHUB_STEP_SUMMARY` are sufficient. Phase G owns richer reporting / dashboard work.

## Public Repo Branch Protection & App Bypass

The public repo has a branch ruleset on `main` that requires PR reviews and a green required-checks set. The sync App (`foundry-samples-repo-sync`) is configured as a **bypass actor** so it can merge sync PRs without a human reviewer.

There are two non-obvious things about this setup:

### Bypass-actor permission is not inherited by GitHub's merge queue

`gh pr merge --auto` does **not** merge the PR right then; it schedules the PR for GitHub's internal merge process to complete once conditions clear. That internal process runs as GitHub's system, **not** as the requesting actor — so the App's bypass permission is not applied, required-reviews is enforced, and the merge fails.

The fix (implemented in `wait-and-merge.sh`) is to skip `--auto` entirely: poll until conditions are satisfied, then call `gh pr merge --rebase` directly while authenticated as the App. The merge happens immediately, as the bypass actor, and succeeds.

### `Require approval of the most recent reviewable push` and the App

If `Require approval of the most recent reviewable push` is enabled in the ruleset, the App's own commits-as-author can re-trigger the requirement, defeating bypass. The pragmatic resolution is to keep this rule **off** while the App is the merger, and re-enable it only if the merger model changes. The rule's intent (catching last-minute pushes by an author who already self-approved) doesn't apply to a sync PR opened and merged by an App.

## Design Decisions & Gotchas

A short list of things that are easy to get wrong, captured for future-you:

- **Refspec literal names matter.** `git push <remote> sync-tmp:refs/heads/sync-branch` works; `git push <remote> sync-tmp:sync-branch` does not consistently resolve to the intended ref on a fresh remote. Always use the fully-qualified `refs/heads/...` form on the right-hand side.
- **`fast-export --refspec` rewrites literal emitted ref names, not arbitrary source arguments.** `sync-core.sh` pins the export source to `refs/heads/sync-export-source` before exporting so the stream deterministically emits `commit refs/heads/main`. Do not simplify this back to `--refspec=HEAD:refs/heads/main`; detached CI checkouts silently write imports to the wrong ref and can produce a public branch with no imported authorship. See the gotchas block at the top of `.github/scripts/sync-core.sh` and regression T28 in `.github/tests/test-sync.sh`.
- **`.github/`-only changes produce no public commits.** `filter-stream.py` drops empty commits, and the path exclusions remove all `.github/` content. So a sync run triggered by a private-only `.github/` change will report success but skip the Push, Create-PR, and Save-Marks steps. This is correct behaviour, but it does mean the sync pipeline can't be smoke-tested by editing only its own infrastructure — you need a real public-path change to exercise the merge path.
- **CodeQL `actions` analysis is intentionally disabled on the public repo.** The public repo runs CodeQL via GitHub-managed default setup. The `actions` language is unchecked because the repo has no workflow YAML to analyse (the only workflow file under `.github/` is `CODEOWNERS`); leaving it on produces noisy false-positive alerts. Public CodeQL config is managed in the repo's Code Security settings, not a workflow file.
- **Bot-authored commits are filtered, not preserved.** Anything authored by `github-actions[bot]` or the sync App itself is dropped from the rewritten stream — only real human authors are surfaced in public history.
- **Statuses live on private SHAs.** Do not try to propagate validation statuses to the public repo after author rewriting. Public commits have different SHAs; this is correct. The gate is a private-repo concern.
- **`pending` blocks sync.** This is intentional. If a reporter posts `pending`, the sample should not ship mid-validation.
- **Latest write wins on `(commit, context)`.** A re-run can flip a sample from blocked to unblocked at the next sync by posting `success` to the same SHA and context.
- **Renames create a hole.** A renamed sample path is a new status context from the gate's perspective. During transition, report under both old and new paths when practical.
- **Multi-pipeline samples require all green.** If any validation context for a sample is `failure`, `error`, or `pending`, the sample is blocked. L4 canary failures block even when L3 build validation passes.

## Troubleshooting

### Sync didn't run

1. Verify the cron schedule is still `0 6 * * *`.
2. Check GitHub Actions logs for token generation failures (App private key rotation, installation issues).
3. Confirm the ruleset bypass-actor for the App hasn't been removed.

### Sync ran but pushed nothing / opened no PR

This is normal if the only commits since the last sync touched excluded paths (e.g., `.github/`, `internal/`, `docs/`, `.azure-pipelines/`) or if all otherwise-new public-path changes are currently gate-blocked. `filter-stream.py` drops the resulting empty commits, so the Push and Create-PR steps skip with a "no new commits" log line.

To verify, check:

1. The run summary for blocked samples.
2. The sync-core log for export/filter/import commit counts.
3. Whether the changed paths are static-excluded in `.github/sync-config.json`.

### Sample did not appear in public repo

1. Verify the path isn't statically excluded (`.github/sync-config.json`).
2. Verify the commit was on `main` before the sync ran.
3. Check the sync run summary for validation-blocked samples.
4. Query the private commit status for the synced SHA and inspect `validation/*` contexts.
5. If statuses are now green, wait for the next sync or run sync manually.

### Sync PR opened but never merged

1. Check `wait-and-merge.sh` log output for the polling loop's exit reason.
2. Confirm required checks on the public repo all completed green.
3. Confirm the App is still listed as a bypass actor on the `main` ruleset.
4. If `Require approval of the most recent reviewable push` was re-enabled, the App's own pushes may be re-triggering the rule — see [Public Repo Branch Protection & App Bypass](#public-repo-branch-protection--app-bypass).

### Author attribution is wrong

1. Check `.github/sync-mailmap` for the correct mapping.
2. Entries follow git mailmap format: `Public Name <public@email> Internal Name <internal@email>`.

### Need to rollback a sync

1. Find the rollback SHA from the sync PR description.
2. Force-push that SHA to `main` on the public repo.
3. Clear the sync marks cache (delete from GitHub Actions cache).

Rollback affects public content. It does not rewrite private validation statuses; fix or re-run validation separately if the rollback is related to gate behavior.

## Changelog

| Date | Change |
|------|--------|
| 2026-04-29 | Reopened sync-gating decision; sync now honors GitHub commit statuses per `docs/validation-results-contract.md`. See `docs/validation-story-decisions.md`. |

## Related Documents

- [Validation Story — Phase B Decisions](validation-story-decisions.md) — Locked decisions that supersede earlier validation/sync-gating text.
- [Validation Contract](validation-contract.md) — Validation behavior and gate contract.
- [Validation Results Contract](validation-results-contract.md) — How validation pipelines post per-sample GitHub commit statuses.
- [External Contributions](external-contributions.md) — How partner samples flow through sync.
- [Sync Cutover Runbook](sync-cutover-runbook.md) — The one-time authorship-preserving history rewrite of public `main`.
- [Sync Config](../.github/sync-config.json) — Static exclusion paths and public repo target.
- [Sync Core Script](../.github/scripts/sync-core.sh) — The sync implementation.
- [Wait-and-merge Script](../.github/scripts/wait-and-merge.sh) — Direct-merge polling logic.
- [Verify Sync Script](../.github/scripts/verify-sync.sh) — Drift checker.
