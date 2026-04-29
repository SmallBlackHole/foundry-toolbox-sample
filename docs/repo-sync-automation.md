# Repo Sync Automation

This document describes the automated sync pipeline that publishes content from `foundry-samples-pr` (private) to `foundry-samples` (public).

## Overview

```
foundry-samples-pr (private)  ──── nightly sync ────►  foundry-samples (public)
       │                                                       │
       │  Authors push here                                    │  Customers read here
       │  CI validation runs here                              │  Issues filed here
       │  Internal content lives here                          │
       └───────────────────────────────────────────────────────┘
                         One-way sync only
```

- **Direction**: Private → Public only. The public repo never writes back.
- **Schedule**: Nightly at 06:00 UTC + manual dispatch.
- **Mechanism**: `git fast-export` / `git fast-import` with path filtering and author rewriting.
- **Automation**: GitHub Actions workflow in `.github/workflows/sync-to-public.yml`.

## How It Works

### 1. Export and filter

The sync uses `git fast-export` to stream commits from the private repo, piped through a Python filter (`filter-stream.py`) that:

- Removes excluded paths (see [Exclusions](#exclusions) below)
- Rewrites author identities using `.github/sync-mailmap` (maps internal aliases to public-facing names)
- Preserves commit history structure (merge commits, ordering)

### 2. Import into public repo

The filtered stream is imported into the public repo via `git fast-import`, creating a sync branch with the rewritten history.

### 3. Incremental sync via marks

The pipeline uses `git fast-export` / `fast-import` marks files to track what's already been synced. These are cached between runs, making subsequent syncs incremental — only new commits are processed.

If marks are unavailable or `force_full` is specified, a full re-export is performed.

### 4. Push and PR

The sync branch is pushed to the public repo and a PR is created automatically:

- Stale sync PRs are closed first
- The new PR includes commit count, authors, and a rollback SHA
- The PR body lists the contributing authors verbatim from rewritten commits

### 5. Wait-and-merge (direct merge as the App)

After the PR is opened, `wait-and-merge.sh` polls the PR's check status and required-review state. Once all required checks pass and reviews are satisfied, the workflow performs a **direct rebase merge** as the GitHub App — it does **not** use `gh pr merge --auto`.

This matters because of how GitHub's branch ruleset bypass interacts with the merge queue. See [Public Repo Branch Protection & App Bypass](#public-repo-branch-protection--app-bypass) below for the full rationale; the short version is that `--auto` schedules the merge for GitHub's system process, which does not inherit the App's bypass-actor permission, so the merge gets blocked by required-reviews even though the App could merge directly.

## Exclusions

Paths excluded from sync are defined in `.github/sync-config.json`:

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
| `docs/` | Internal-facing governance/process docs (validation contract, sync runbook, partner contributions). Public consumers don't need this internal-process surface. |
| `.azure-pipelines/` | ADO pipeline config (CI infra is private) |
| `.github/` | Workflows, sync scripts, and config (sync infra is private) |
| `CONTRIBUTING.md` | Private-repo contributing guide (public repo has its own) |
| `README.md` | Private-repo README (public repo has its own) |

### What IS synced

Everything not in the exclusion list, primarily:

- `samples/` — all validated sample code
- `CODEOWNERS` — ownership mappings (note: explicitly synced despite `.github/` exclusion in older versions)
- Any other top-level content (e.g., LICENSE)

## Author Rewriting

The sync rewrites commit author information using `.github/sync-mailmap`. This maps internal Microsoft aliases to public-facing identities, ensuring:

- Commits appear under the author's public GitHub identity
- Internal email addresses are not exposed in public git history
- Attribution is preserved accurately

## Authentication

The sync uses a **GitHub App** (`foundry-samples-repo-sync`) for authentication:

- Short-lived tokens scoped to the public repository only
- No Personal Access Tokens (PATs) — eliminates token rotation burden
- App installation is managed via GitHub org settings

## Workflow Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `dry_run` | boolean | `false` | Builds sync branch and pushes, but does NOT create a PR or update marks cache |
| `force_full` | boolean | `false` | Discards marks cache and performs a full re-export |

## Sync Gating: Decided Against

> **Status: Not pursued.** Sync is intentionally path-based, not validation-based.

Earlier drafts of this pipeline contemplated reading a validation manifest from a `validation-results` branch and gating per-sample sync on `pass`/`fail` status. That design has been **set aside** in favour of a simpler responsibility split:

- **Authors and PR reviewers** are responsible for not merging broken samples to private `main`.
- **The validation pipeline** posts pass/fail signals on PRs to inform that human decision.
- **The sync** ships whatever's on private `main` (minus the path exclusions above), full stop.

Rationale:

1. Manifest gating adds substantial machinery (a separate branch, a manifest schema, staleness checks, graceful-degradation fallbacks) for relatively little marginal safety — most regressions are caught at PR time, not between PR-time and sync-time.
2. Per-sample exclusion creates confusing public-repo states (some files synced, some held back) that are hard to reason about and hard to roll back.
3. The new authorship-preserving pipeline (see [Author Rewriting](#author-rewriting)) and direct-merge model (see [Wait-and-merge](#5-wait-and-merge-direct-merge-as-the-app)) are easier to operate when sync is a deterministic path-based mirror.

See [Validation Contract](validation-contract.md) for the matching change on the validation side.

## Drift Verification

A separate workflow, `.github/workflows/verify-sync.yml`, runs after each sync (and on demand) to confirm that the public repo's `main` matches what private `main` *should* have produced.

The check is intentionally narrow:

- It compares `git ls-tree -r HEAD` of private `main` (with `exclude_pathspecs` applied) against `git ls-tree -r HEAD` of public `main`.
- Drift = path missing in public, blob hash differs, or path present in public that shouldn't be there.
- Output goes to the workflow run summary; persistent drift fails the run.

What drift verification does **not** check:

- **Author identity / mailmap correctness** — that's verified upstream during sync (`filter-stream.py` + `sync-mailmap`) and isn't re-derivable from a tree snapshot.
- **Commit message contents or history shape** — only the file tree at `HEAD` is compared.
- **Validation status** — see [Sync Gating: Decided Against](#sync-gating-decided-against).

The script is `.github/scripts/verify-sync.sh`. It is the post-#183 replacement for an earlier manifest-driven verifier; the older version was deleted alongside the manifest gating design.

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
- **`.github/`-only changes produce no public commits.** `filter-stream.py` drops empty commits, and the path exclusions remove all `.github/` content. So a sync run triggered by a private-only `.github/` change will report success but skip the Push, Create-PR, and Save-Marks steps. This is correct behaviour, but it does mean the sync pipeline can't be smoke-tested by editing only its own infrastructure — you need a real `samples/` change to exercise the merge path.
- **CodeQL `actions` analysis is intentionally disabled on the public repo.** The public repo runs CodeQL via GitHub-managed default setup. The `actions` language is unchecked because the repo has no workflow YAML to analyse (the only workflow file is `CODEOWNERS`); leaving it on produces noisy false-positive alerts. Public CodeQL config is managed in the repo's Code Security settings, not a workflow file.
- **Bot-authored commits are filtered, not preserved.** Anything authored by `github-actions[bot]` or the sync App itself is dropped from the rewritten stream — only real human authors are surfaced in public history.

## Troubleshooting

### Sync didn't run

1. Verify the cron schedule hasn't been modified
2. Check GitHub Actions logs for token generation failures (App private key rotation, installation issues)
3. Confirm the ruleset bypass-actor for the App hasn't been removed

### Sync ran but pushed nothing / opened no PR

This is normal if the only commits since the last sync touched excluded paths (e.g., `.github/`, `internal/`, `.azure-pipelines/`). `filter-stream.py` drops the resulting empty commits, so the Push and Create-PR steps skip with a "no new commits" log line. To verify, check the run's "Filter stream" step output for the commit count.

### Sync PR opened but never merged

1. Check `wait-and-merge.sh` log output for the polling loop's exit reason
2. Confirm required checks on the public repo all completed green
3. Confirm the App is still listed as a bypass actor on the `main` ruleset
4. If `Require approval of the most recent reviewable push` was re-enabled, the App's own pushes may be re-triggering the rule — see [Public Repo Branch Protection & App Bypass](#public-repo-branch-protection--app-bypass)

### Content missing from public repo

1. Verify the file isn't in an excluded path (`.github/sync-config.json`)
2. Verify the commit was on `main` before the sync ran
3. Run the Verify Sync workflow on demand to confirm whether public is actually drifted vs just behind

### Author attribution is wrong

1. Check `.github/sync-mailmap` for the correct mapping
2. Entries follow git mailmap format: `Public Name <public@email> Internal Name <internal@email>`

### Need to rollback a sync

1. Find the rollback SHA from the sync PR description
2. Force-push that SHA to `main` on the public repo
3. Clear the sync marks cache (delete from GitHub Actions cache)

## Related Documents

- [Validation Contract](validation-contract.md) — CI validation spec (note: validation does not gate sync; see [Sync Gating: Decided Against](#sync-gating-decided-against))
- [External Contributions](external-contributions.md) — How partner samples flow through sync
- [Sync Cutover Runbook](sync-cutover-runbook.md) — The one-time authorship-preserving history rewrite of public `main`
- [Sync Config](../.github/sync-config.json) — Exclusion paths and public repo target
- [Sync Core Script](../.github/scripts/sync-core.sh) — The sync implementation
- [Wait-and-merge Script](../.github/scripts/wait-and-merge.sh) — Direct-merge polling logic
- [Verify Sync Script](../.github/scripts/verify-sync.sh) — Drift checker
