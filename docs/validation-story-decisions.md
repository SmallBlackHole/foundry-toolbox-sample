# Validation Story — Phase B Decisions

> **Status:** Decided 2026-04-29. This document supersedes the "Validation Results Manifest: Decided Against" and "Sync Gating: Decided Against" sections of `docs/validation-contract.md` and `docs/repo-sync-automation.md`. Those sections will be revised in Phase C with dated changelog entries pointing to this document.
>
> **Internal-only.** Lives under `docs/`, which is excluded from public sync.

## Changelog

| Date | Change |
|------|--------|
| 2026-04-30 | D1 implemented in this PR: ADO `validation.yml` posts per-sample `validation/ado-build/*` GitHub commit statuses. |
| 2026-04-30 | D3 implemented in PR #214: `parse-validation-statuses.sh` reads commit statuses and emits `SYNC_BLOCKED_PATHS`. |
| 2026-04-30 | D2 implemented in PR #215: `sync-core.sh` now honors `SYNC_BLOCKED_PATHS`. |
| 2026-05-01 | Deleted `docs/validation-story-audit.md` (Phase A throwaway artifact); decisions captured here are now the durable record. |
| 2026-05-04 | D4 design lock (§8): sync gate wiring decided. Both `sync-to-public.yml` and `verify-sync.yml` consume statuses; gate fails closed on machinery errors; per-sample bypass via `workflow_dispatch`; run-summary observability only. Implementation tickets: 5015383, 5237815. Prerequisite: 5247751. |

## North Star

**Validation gates sync.** A change to a sample in `foundry-samples-pr` is not eligible for the next sync to `foundry-samples` (public) unless it has passed validation. The purpose is to keep an incredibly high quality bar for samples shown to the public.

## Implementation Principle

**Early wins that bring functionality immediately, while facilitating additive/incremental gains.** Ship the smallest viable version of the gate; layer freshness, override, advisory mode, reporting, and tier-promotion mechanisms onto it as we learn.

## §1 — The Gate Mechanism

### Granularity: per-sample

A sample is the unit of gating. When sample A passes and sample B fails in the same merge commit, sample A still syncs; sample B is held back. This preserves "fix one, ship the rest" and survives multi-team contributions.

### Hold model: block-list

Default = sync. A sample is blocked iff it has at least one reported status with state `failure` / `error` / `pending` at the synced SHA. This is friendly to the existing tree, friendly to grandfathering, and matches "failures are exceptional".

The known caveat (silent-pass on missing reports) is mitigated by the grandfather rule below — only samples whose validation pipelines explicitly report participate in the gate.

### Source of truth: GitHub commit statuses on `main` commits

Statuses are durable (no expiry), signed (by the posting identity), queryable (one API call per commit), and ecumenical (any pipeline — ADO, GHA, future custom — can post via the GitHub Statuses API). No new branch, no manifest schema, no signed-payload endpoint, no separate persistence layer.

### Status context naming convention

All reporters MUST use:

```
validation/<pipeline-id>/<sample-path>
```

Where:

- `pipeline-id` is a documented short slug for the validating pipeline (e.g. `ado-build`, `hosted-agents-e2e`). Encodes *who* validated.
- `sample-path` is the canonical sample directory relative to repo root. If status-context character constraints require it, `/` is preserved where allowed and otherwise flattened to `--`.

State semantics:

- `success` → does not block.
- `failure` / `error` → blocks sync of this sample.
- `pending` → blocks sync of this sample (don't sync mid-validation).

### Bootstrap: grandfather

Day-one behaviour: untracked samples sync ungated; tracked samples are subject to the gate.

A sample is **tracked by a pipeline** iff that pipeline reports a status for it. Each pipeline owns the definition of its tracked set:

- ADO `validation.yml`: tracked = directory containing `sample.yaml`. Already enumerable today (`find samples -name sample.yaml`).
- Hosted Agents `cloud-e2e`: tracked = directory containing `agent.manifest.yaml` and not containing `.ci-skip`. Already enumerable today.
- Future pipelines: tracked set defined by the pipeline itself.

A directory with no reporting pipeline = untracked = grandfathered = syncs unaffected. As teams adopt the gate (by reporting), their samples join the tracked set.

## §2 — Required Validation Tier

### Floor

Build Readiness Level 3 (Load) remains the floor for tracked samples. Level 4 (Run, against live resources) is an *additional* opt-in tier; it does not replace L3.

### Promotion model: implicit, per-pipeline

The gate is mechanism-over-statuses; it does not need a first-class concept of "Level". A status is required by virtue of being reported. A pipeline that posts a status for a sample is signing up for that status to be load-bearing.

L4 promotion follows naturally: a pipeline that runs L4 (e.g., Hosted Agents' cloud E2E) reports for its sample paths → those samples are gated on L4 results. A pipeline that runs only L3 reports L3 results → those samples are gated on L3.

No central registry of "which samples require which level". No glob mapping. The act of reporting is the act of opting in.

### Advisory mode: deferred

If a pipeline wants its results to be visible-but-not-blocking (e.g., during a flakiness investigation), the v1 answer is "don't report". v2 may add an explicit `advisory_contexts` allow-list in `sample.yaml` if the implicit model proves insufficient. Purely additive.

### Default for directories with no `sample.yaml`

Untracked. Grandfathered. Syncs ungated. We are not requiring `sample.yaml` everywhere in v1 — that policy can tighten later via a sweep.

A directory with no `sample.yaml` but with reported external statuses is functionally tracked (because something is reporting on it) and the gate honors those statuses. `sample.yaml` is needed for *our* pipeline's discovery; it's not the only path to being gated.

### Non-sample content

README, LICENSE, CODEOWNERS, top-level helpers — all flow through ungated. They have no `sample.yaml` and no status contexts; the gate has nothing to say about them. Path-based sync exclusions (`internal/`, `docs/`, `.azure-pipelines/`, `.github/`, etc.) remain the only filter for non-sample content.

## §3 — External Validation Contract

### Mechanism

GitHub commit statuses on `main` commits in `foundry-samples-pr`. Locked from §1.

### Trust model: convention-based, documented; no enforced allow-list in v1

Any status posted under the `validation/<pipeline-id>/<sample-path>` convention is honored by the gate, regardless of creator. The realistic creator landscape is one or two bot identities (`github-actions[bot]`, the ADO bot), all backed by repo write access controls and internal MSFT-only contributors.

The hypothetical threat — accidental context-name collision overwriting a real failure — is mitigated by the convention being specific enough that accidental collisions are implausible. The systemic-trust threat is out of scope for an internal-only repo at our scale.

If/when this changes (external contributors directly merging, adversarial scenarios surface, or we observe real collisions), enforcement is a small, additive change: a creator-allow-list in `.github/sync-config.json` consulted by the gate. Reserved as v2.

### Registration: documentation-only

`docs/validation-results-contract.md` (created in Phase C4) maintains an informational table of registered pipelines: `pipeline-id`, owning team, scope (path glob), expected creator identity, evidence pipeline URL. Onboarding a new pipeline = a doc PR + start posting. No code-level gating ceremony.

### ADO `validation.yml` plumbing

Today: results live in ADO build artifacts only. No GitHub Statuses API call.

Required change (additive):

- Add a final per-sample step in each language job that POSTs `state` + `target_url` to `POST /repos/microsoft-foundry/foundry-samples-pr/statuses/{sha}` with context `validation/ado-build/<sample-path>`.
- Credential: **GitHub App** (decided 2026-04-29). Rotateable, auditable, no per-user binding, short-lived installation tokens, survives personnel turnover. PAT was considered and rejected because expiry produces silent fail-open in a gate. App registration + install on `foundry-samples-pr` is a D1 prerequisite.
- Pipeline-id: `ado-build`.

### Hosted Agents canary

Required change to `hosted-agents-cloud-e2e.yml` (additive):

- Add a "Publish status" step at the end of each `cloud-e2e` matrix job. Posts `validation/hosted-agents-e2e/<sample-path>` with state derived from job result. `actions/github-script` with the workflow's existing `${{ secrets.GITHUB_TOKEN }}` is sufficient.
- Add `hosted-agents-e2e` row to the informational registry in `docs/validation-results-contract.md`.

### SHA targeting and freshness

- Pipelines post statuses to whatever SHA they ran against.
- Sync gate runs against `main` HEAD and reads statuses there.
- Both ADO `validation.yml` and Hosted Agents `cloud-e2e` already trigger on `push: main`, so statuses appear on merge commits naturally.
- Scheduled runs (Mon/Wed/Fri ADO, daily Hosted Agents) refresh statuses on `main` HEAD as it stands at run time.
- v1 freshness rule: gate honors whatever status is current at sync time. No max-age. Scheduled runs provide natural refresh. Explicit max-age rule deferred to v2.

### Sync to public — statuses do not propagate

Statuses live on private-repo SHAs. After fast-export + author rewriting + import, public commits have different SHAs. Statuses don't follow, by design — the gate is a private-repo concern; public commits arrive already-validated. Reporting (Phase G) is built against private-repo statuses.

## Reporting (Phase G) — deferred

A "health at a glance" view (chart/table of per-sample current status, evidence links, drill-down by pipeline/team/area) is desirable but not gating any other phase. Deferred to its own phase.

The decisions above happen to be reporting-friendly:

- Live current state is one API call: `gh api repos/microsoft-foundry/foundry-samples-pr/commits/main/status`.
- Context naming convention lets a dashboard parse-and-group without per-pipeline logic.
- Trend / history can layer on later via a daily snapshot job; no schema changes required.

## Implementation footprint of v1

The minimum viable system is genuinely small:

| Change | Where | Size |
|--------|-------|------|
| Post commit statuses per sample | `.azure-pipelines/validation.yml` | ~1 step per language job |
| Post commit statuses per matrix job | `.github/workflows/hosted-agents-cloud-e2e.yml` | ~1 step at end of `cloud-e2e` |
| Read statuses, build dynamic exclude list | `.github/workflows/sync-to-public.yml` + `.github/scripts/sync-core.sh` | ~1 new script + a hook |
| Verify-sync redefines drift | `.github/scripts/verify-sync.sh` | small change to subtract block-list from expected tree |
| Informational registry | `docs/validation-results-contract.md` | new doc |
| Doc realignment | several files (Phase C) | text-only |

Everything else (advisory mode, max-age freshness, allow-list enforcement, dashboard, override/break-glass, requiring `sample.yaml` everywhere) layers on additively without changing the v1 contract.

## §8 — Sync gate v1 (D4) implementation lock

Decided 2026-05-04 in design session ADO 5242816. Locks the wiring that composes D1 (status reporters), D2 (sync-core block-list), and D3 (parser).

### Q1 — Integration points

The gate lives in BOTH `sync-to-public.yml` (the gating action) AND `verify-sync.yml` (drift-aware of the same block-list). PR-time advisory gating is deferred (Feature 5247631).

### Q2 — Status filter

`failure` + `error` + `pending` block; `success` passes. Locked unchanged from §1. `pending` is currently dormant in production (no pipeline emits it today); first production occurrence is to be audited (Task 5247662).

### Q3 — Missing statuses

No status on synced SHA = ungated. Bootstrap rule from §1, confirmed. Run summary surfaces tracked-sample count + per-pipeline reporter counts so silent fail-opens become visible. Frozen-grandfather list to close the new-sample fail-open is deferred to Feature 5247733.

### Q4 — Freshness

Per §1: statuses are SHA-specific; no max-age, no SHA-walking. Confirmed. **Prerequisite for D4 to function:** `validation.yml` must post per-sample statuses for ALL tracked samples on every push:main, not just changed ones (currently posts only changed). Without this, ~99% of samples appear untracked on routine sync SHAs and grandfather through. Tracked in Task 5247751; this MUST land before D4 ships.

> **Errata (post-PR-A merge, 2026-05):** PR-A (5247751) shipped the fan-out logic but production verification showed 0/15 statuses posted on main commits because (a) the pipeline's `trigger.paths: samples/**` filter meant non-samples commits never queued a run, and (b) the `IS_PUSH_MAIN_PARTIAL` gate only accepted `IndividualCI`/`BatchedCI`, so manual re-queues silently skipped fan-out. Fix A removes the `paths:` filter from the main trigger and broadens the gate to accept any non-`Schedule` non-`validateAll` run on `refs/heads/main` (including `Manual` re-queues). This is implementation correction; the locked freshness decision above is unchanged.

### Q5 — Gate-machinery failures: fail closed

When the gate machinery breaks (Statuses API errors, parser crashes, auth failures, malformed payloads, etc.), sync aborts; next nightly retries. Quality > schedule: a 24-hour delay is always preferable to shipping unvalidated content.

Implementation discipline: `set -euo pipefail` around fetch and parse; `SYNC_BLOCKED_PATHS` only set on success. Empty-result (legitimate "no statuses on this SHA") and error (read failed) must NOT be conflated; the former is Q3 grandfathering, the latter aborts.

Retry policy: exponential backoff (~3 retries) for transient errors (5xx, 429, network). Fatal errors (4xx, parser crash) abort immediately.

### Q6 — Override / kill-switch

`workflow_dispatch` on `sync-to-public.yml` with inputs:
- `bypass_samples` (colon-separated paths) — per-sample carve-out
- `bypass_reason` (free-text, required if bypass_samples non-empty)
- `bypass_gate` (boolean) — full gate bypass for cases where the gate itself is broken (Q5) and ship-now is needed

Authorization: anyone with repo write (default `Actions: write`). No additional gating; this is self-serve infrastructure, not a babysat process.

Loudness on every bypass:
- Workflow run summary banner
- Auto-comment on a permanent "Validation gate bypass log" tracking issue
- Footer on the resulting public-facing sync commit message

Bypass does NOT persist across runs. Persistent bypass-with-expiry file is deferred until the gap is observed in practice.

### Q7 — Observability

Default success path: workflow run summary only (no Slack, no email, no auto-issue). Block notifications: none beyond the run summary — teams own correctness; the validation pipeline already alerts owners on its own failure; the gate doesn't re-route.

Sustained-failure auto-issue (after N consecutive fail-closed runs): deferred. Workflow notifications + Q5's loud abort are sufficient v1.

Weekly digest of gate activity: deferred to Task 5247789, fast-follow ~1-2 weeks after D4 ships once we have data shape to design against.

ADO coupling: none. The gate is a GitHub artifact; ADO is the team's planning artifact; they meet at the human, not in code.

### Q8 — D4b coupling

`verify-sync.yml` re-queries the same statuses payload independently and computes the same block-list. No artifact handoff between workflows; no `workflow_run` trigger; no persistent state file. Single source of truth = GitHub statuses themselves.

Implementation: extract status-fetch + parser into a shared script (e.g. `.github/scripts/compute-blocklist.sh`) sourced by both workflows. Prevents the two from drifting in normalization rules (parity is what T50 / 5247633 tests).

Race-condition acceptance: statuses can in theory change between sync's read and verify's read. Bounded, noisy-not-dangerous (false drift report at worst, never silent fail-open), and recoverable on the next cycle. Pinning verify to sync's recorded SHA is deferred unless the race is observed in practice.

### PR strategy

One PR for D4 + D4b combined, separately preceded by the prerequisite PR:

1. **PR-A (5247751)** — `validation.yml` posts statuses for all tracked samples on `push:main`. Lands first; needs to be live in production before D4. Independent of D4 in code, dependent in time.
2. **PR-B (5015383 + 5237815 combined)** — D4 + D4b atomic. Adds shared `compute-blocklist.sh`; threads it into both `sync-to-public.yml` and `verify-sync.yml`; updates `verify-sync.sh` to subtract block-list from EXPECTED; flips T48 from skip-pin to active. Implements bypass mechanism. Adds run-summary block.

Splitting D4 from D4b would create a window where sync excludes blocked samples but verify still expects them in public → red CI on every nightly until D4b lands. Not viable.

## Cross-cutting consequences (handled in later phases)

These fall out of the decisions above but are not Phase B concerns:

- **§4 Staleness & re-validation cadence** — v1 = "no max-age". Revisit if scheduled runs aren't refreshing fast enough in practice.
- **§5 Failure handling & operator UX** — recovery is automatic (next sync after pass); break-glass deferred; PR-time visibility ("what would sync if this merged?") is a Phase D add-on.
- **§6 Sync timing & verify-sync** — sync still runs at 06:00 UTC; gate consumes whatever's recorded then. `verify-sync.sh` redefines drift to subtract validation-blocked samples from the expected tree.
- **§7 Scope** — `samples-classic/` flows ungated (untracked). External-contributions doc (`docs/external-contributions.md`) gets the "no separate path" claim revised to admit team-owned validation as an explicit category.

## Changelog

> **Note:** This changelog mirrors the one at the top of the file. Both should be kept in sync. (The duplication is historical drift; consolidate into one in a future cleanup.)

| Date | Change |
|------|--------|
| 2026-04-30 | D1 implemented: ADO `validation.yml` posts per-sample `validation/ado-build/*` GitHub commit statuses (PR #220). |
| 2026-04-30 | D3 reader implemented in PR #214: `.github/scripts/parse-validation-statuses.sh` now consumes statuses-list payloads and emits SYNC_BLOCKED_PATHS-compatible output. |
| 2026-04-30 | D2 implemented in PR #215: `sync-core.sh` now honors `SYNC_BLOCKED_PATHS`. |
| 2026-05-01 | Deleted `docs/validation-story-audit.md` (Phase A throwaway artifact); decisions captured here are now the durable record. |
| 2026-05-04 | D4 design lock (§8): sync gate wiring decided. Both `sync-to-public.yml` and `verify-sync.yml` consume statuses; gate fails closed on machinery errors; per-sample bypass via `workflow_dispatch`; run-summary observability only. Implementation tickets: 5015383, 5237815. Prerequisite: 5247751. |
