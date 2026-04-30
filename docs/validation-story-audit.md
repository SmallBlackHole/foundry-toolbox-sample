# Validation Story Audit

> **Internal-only.** This file lives under `docs/`, which is excluded from public sync. It is a Phase A artifact for the validation realignment plan and is expected to be deleted once the realignment lands.

## Purpose

Capture, in one place, what the docs and the code currently *say* about validation and sync, where they disagree, and what gap led to this audit being commissioned. The document drives the Phase B decisions: live-resource validation, sync gating, and the external-results contract.

## Scope of sources read

**Docs:**
- `docs/validation-contract.md`
- `docs/repo-sync-automation.md`
- `docs/external-contributions.md`
- `CONTRIBUTING.md`
- `README.md`
- `.azure-pipelines/README.md`
- `.github/copilot-instructions.md`

**Pipelines / workflows:**
- `.azure-pipelines/validation.yml` (the canonical sample validation pipeline; runs in ADO)
- `.github/workflows/sync-to-public.yml` (nightly sync to public repo)
- `.github/workflows/verify-sync.yml` (post-sync drift verification)
- `.github/workflows/hosted-agents-cloud-e2e.yml` (the team-owned live-validation workflow that prompted this audit)

## What each source says

### `docs/validation-contract.md`

- Validation tops out at **Build Readiness Level 3 (Load)**.
- "Why Level 3 and not 'runs end-to-end'?" — explicitly states that full execution requires Azure credentials / live endpoints and "isn't feasible in CI".
- A "Validation Results Manifest" was contemplated and is **explicitly Decided Against**. The schema is preserved as historical record only.
- "Sync Gating" is **explicitly Decided Against**. Sync is path-based; gating is an author/PR-review responsibility.
- Implementation Status table marks the structured manifest, sync gating, and `lastValidatedCommit` rows as ❌ Not pursued.

### `docs/repo-sync-automation.md`

- Same "Sync Gating: Decided Against" stance as the contract doc; cross-linked.
- Drift verification (`verify-sync.yml`) is intentionally narrow: tree-equality only, **does not check validation status**.
- The earlier manifest-driven verifier was deleted alongside the manifest gating design.

### `docs/external-contributions.md`

- Partner samples go through "the **same validation pipeline** as internal samples. There is no separate path or lower bar."
- Validation is described as Level 3 only; live-endpoint execution is explicitly out of scope ("It does **not** execute the sample against live endpoints or verify functional correctness.").
- This is the doc that most directly forecloses the team-owned-validation pattern that Hosted Agents is now exercising.

### `CONTRIBUTING.md` *(out of date)*

This file is the headline source of drift. It still says:

- "Validation results **gate the nightly sync to public** — only samples that pass validation reach `foundry-samples`." *(line 187)*
- "Results are collected into a **validation manifest** and pushed to the `validation-results` branch. The nightly sync workflow reads this manifest and decides what to sync." *(lines 193–194)*

Both statements are flatly contradicted by `docs/validation-contract.md` and `docs/repo-sync-automation.md`. The manifest doesn't exist; the `validation-results` branch doesn't exist; `sync-to-public.yml` doesn't read any such manifest.

The "What happens when…" table later in the same file *correctly* says "Validation fails → Sample still syncs (validation is PR-time only)" — directly contradicting line 187 four screens earlier.

### `README.md`

- Concise, accurate. Says "build readiness level 3 — code parses, deps resolve, code loads".
- No mention of live validation or external team contributions.

### `.azure-pipelines/README.md`

- Accurate operational description of `validation.yml`. No claims about sync gating or manifests.
- Cross-references `docs/validation-contract.md` for the full contract.

### `.github/copilot-instructions.md`

- "build readiness levels (1–3). The sync threshold is Level 3 (Load)." — mirrors the contract.
- "Every sample must have a `sample.yaml` in its root directory. The pipeline discovers samples by finding these files." — matches `validation.yml` behaviour.

### `.azure-pipelines/validation.yml`

What it actually does:

- Triggers on PR / push to `main` / Mon-Wed-Fri schedule / manual `validateAll`.
- Discovers samples via `find samples -name sample.yaml`.
- Per language: parses optional `build` / `validate` / `test` from `sample.yaml`; otherwise applies language defaults.
- Publishes a `ChangedSamples` artifact and per-language `passed_*.txt` / `failed_*.txt` lists as build artifacts.
- **Results live only in the ADO build artifacts.** They are not pushed to a branch, not surfaced as GitHub commit statuses, and not consumed by any other workflow.

### `.github/workflows/sync-to-public.yml`

- Reads `sync-config.json`, generates an App token, runs `sync-core.sh`, pushes a sync branch, opens a PR, and direct-merges as the App.
- **Reads no validation signal.** No reference to `validation-results`, no manifest fetch, no per-sample exclusion logic. Path exclusions come from `sync-config.json` only.

### `.github/workflows/verify-sync.yml`

- Triggered by `workflow_run` after `sync-to-public.yml` completes.
- Runs `verify-sync.sh` to compare `git ls-tree -r HEAD` of private (with exclusions) vs public.
- Opens a deduplicated `sync-drift` issue if drift is detected.
- **No validation awareness.** Drift = tree mismatch, full stop.

### `.github/workflows/hosted-agents-cloud-e2e.yml`

This is the workflow that motivated the audit. Key facts:

- **Owned by:** Hosted Agents team (CODEOWNERS for `samples/*/hosted-agents/`).
- **Triggers:** PR / push to `main` / daily 09:00 UTC / manual.
- **Path-scoped:** Only runs against `samples/{python,csharp}/hosted-agents/**`.
- **Gated by:** `vars.CLOUD_E2E_ENABLED == 'true'` (org-level kill switch).
- **Auth:** OIDC federated identity (`vars.AZURE_CLIENT_ID` + `AZURE_TENANT_ID` + `AZURE_SUBSCRIPTION_ID`) — **the kind of internal ARM connection the private/public split was originally built to enable.**
- **Mechanism:** `azd ai agent init` → `azd provision` (or `SKIP_PROVISION=true` against an existing Foundry project) → `azd deploy` against real Azure resources, then exercises the deployed agent.
- **Schema:** Uses `agent.yaml` + `agent.manifest.yaml` (a hosted-agents-specific schema), **not** `sample.yaml`. Has its own opt-out file (`.ci-skip`).
- **Where results go:** GitHub Actions run results / PR check status. **Not** ingested by `sync-to-public.yml`. **Not** ingested by ADO `validation.yml`. **Not** stored anywhere durable beyond GHA's normal retention.

This is, in effect, a **Level 4 (Run) validation that already exists** — it's just running outside the contract.

## Where the sources disagree

| Topic | What `docs/` says | What `CONTRIBUTING.md` says | What the code does |
|-------|-------------------|------------------------------|--------------------|
| Validation tops out at Level 3 | Yes (explicit) | Yes (in level table) | `validation.yml`: yes. `hosted-agents-cloud-e2e.yml`: **no — runs Level 4** |
| Sync is gated by validation | **No, Decided Against** | **Yes** (line 187) — *and* No (later table) | **No** — sync is path-based |
| There is a validation manifest | **No, Decided Against** | **Yes** (line 193) — `validation-results` branch | **No** — no such branch, no such file |
| External teams use the same pipeline | Yes (`external-contributions.md`) | (silent) | **No** — Hosted Agents has its own end-to-end workflow with its own schema |
| Validation results are durable | (silent) | "validation manifest" implies durable | **No** — only GHA / ADO build artifacts; nothing cross-run |

## The gap that matters

The repo's *infrastructure choices* anticipated live-resource validation as a first-class capability:

- The private/public split was justified in part because the private repo can hold **internal ARM service connections** that the public repo cannot.
- The Hosted Agents team has now operationalised that capability with `hosted-agents-cloud-e2e.yml` — federated OIDC against an internal subscription, real `azd provision` / `azd deploy`, real agent invocation against deployed resources.
- The `docs/` declared this out of scope (Level 3 cap, Sync Gating: Decided Against) on practicality grounds — but did so before the team-owned-validation pattern existed as a real, working example.

The result is a system that:

1. **Can do** live-resource validation (proven by Hosted Agents).
2. **Doesn't admit** that capability in its contract.
3. **Doesn't honour** the results in its sync decisions.
4. **Doesn't define** a contract for additional teams to plug in the same way.

Phase B has to decide how to reconcile this — by promoting live validation into the contract (and defining its results contract), by formalising a "team brings its own validation, we ingest the results" pattern, or both.

## Specific drift-fix list (mechanical, regardless of Phase B outcome)

These items are wrong *today* and must be corrected even in the most conservative outcome of Phase B:

1. `CONTRIBUTING.md` line 187 — "validation results gate the nightly sync to public". Wrong; sync is path-based. Replace with the same wording as the "What happens when…" table later in the file.
2. `CONTRIBUTING.md` lines 193–194 — manifest / `validation-results` branch description. Delete; describe the actual flow (PR-time signal only, results in ADO build artifacts).
3. `docs/external-contributions.md` "no separate path or lower bar" claim — at minimum needs a footnote acknowledging that team-owned validation pipelines exist and are expected to grow.
4. `README.md` is *not* wrong but is silent on the live-validation capability. Update only if Phase B promotes Level 4 into the contract.

## Inputs to Phase B

The audit confirms the three Phase B questions are well-posed and the answers are not pre-determined by current implementation:

- **B1 (Level 4):** A working example exists (`hosted-agents-cloud-e2e.yml`). The credential model, cost, and eligibility shape are knowable from that example. Decision is whether to promote it into the contract as an opt-in tier.
- **B2 (Sync gating):** The current "Decided Against" rationale (manifest machinery is heavy for marginal safety) was correct *at the time*. With at least one team now producing real Level-4 results, the cost/benefit shifts. The hybrid block-list option is the lightest mechanism that honours real failure signals without re-introducing the full manifest design.
- **B3 (External-results contract):** Needs a schema and an ingestion mechanism. The Hosted Agents workflow already produces results (in GHA run state); the question is *how* those reach a durable, sync-consultable location. Three credible mechanisms (commit statuses, results branch, signed payload endpoint) are on the table.

## Open questions that should not block Phase B

These came up while reading the sources but don't gate the realignment decision:

- Should `agent.yaml` / `agent.manifest.yaml` be folded into `sample.yaml`'s schema, or stay separate? (Likely stay separate — different lifecycle, different audience.)
- Should `validation.yml` (ADO) and the GHA team-owned workflows ever converge into one orchestrator? (Probably not — they have different runtime needs and different ownership.)
- Is the `samples-classic/` corpus ever going to be validated? (Currently called out as ❌ in the contract. Out of scope for this realignment.)
