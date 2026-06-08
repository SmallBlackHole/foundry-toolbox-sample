# External Partner Contributions

This document defines the interaction model for allowing external partners to contribute code samples to `foundry-samples-pr` and have them published to the public `foundry-samples` repository.

## Contribution Model

External partner contributions follow a **white-glove, curated** model — not open contribution. Partners are onboarded through an explicit process with a named DRI (directly responsible individual) on the Microsoft side.

### Why not open contribution?

- Samples carry the **Azure brand** — quality failures reflect on the platform, not the partner
- Validation checks **build readiness** and reported live-resource validation; functional correctness still needs an owner
- Partners may not have Azure subscriptions, tooling access, or familiarity with our CI system
- Ongoing maintenance burden falls on internal teams when partners don't respond

## Roles and Responsibilities

| Role | Owns | Examples |
|------|------|----------|
| **DevX Engineering** | Repo infrastructure, central validation pipeline, sync process, best-effort build fixes | Fixing a broken `requirements.txt`, updating pipeline config |
| **Feature team DRI** | Functional correctness, partner relationship, escalation handling, team-owned validation if applicable | Verifying a Mistral sample works against the Mistral API; owning a live-resource E2E pipeline |
| **External partner** | Sample code, timely response to issues, keeping code current | Responding to "your sample broke" within SLA |

### Ownership boundaries

- DevX will **fix build breaks** (Level 2–3 failures) on a best-effort basis
- DevX will **not fix functional bugs** — those go to the DRI → partner
- Team-owned validation pipelines are first-class, but the owning team is responsible for keeping those results current and actionable
- If a partner sample repeatedly fails, DevX will escalate, then remove from sync after SLA expires

## Onboarding a Partner

### Prerequisites

1. A named **DRI** on the Microsoft side (usually from the feature team that owns the API the sample uses)
2. Partner has reviewed and agreed to the sample structure requirements
3. DevX and the DRI have agreed which validation path the sample will use: central pipeline, team-owned pipeline, or both

### Process

1. **DRI opens a request** — creates an ADO work item or contacts DevX directly
2. **DevX creates access** — grants partner contributor access to `foundry-samples-pr`
3. **Partner submits PR** — following the same structure as internal samples (see [CONTRIBUTING.md](../CONTRIBUTING.md))
4. **DRI reviews for correctness** — DevX reviews for structure and CI compatibility
5. **Merge and validate** — sample enters the normal validation + sync flow; validation status gates public sync

### What partners must provide

- A `README.md` for the sample explaining prerequisites and usage
- A point of contact for escalations (email or GitHub handle)
- Validation coverage through one or both supported paths:
  - `sample.yaml` meeting the [Validation Contract](validation-contract.md), if using the central ADO pipeline
  - A team-owned pipeline that posts GitHub commit statuses per the [Validation Results Contract](validation-results-contract.md), if bringing your own validation

## Validation Requirements

Partner samples can use more than one validation path. The bar is not lowered; the choice is **who runs the pipeline**, not whether quality matters.

Validation gates sync. A partner-contributed sample is held back from public sync until its reporting pipeline posts a non-failing status for that sample on the `main` HEAD commit that sync evaluates. The grandfather rule applies only to samples with **no** reporting pipeline. Once a team opts in by reporting under `validation/<pipeline-id>/<sample-path>`, that sample is tracked by that pipeline and its status is load-bearing.

See the [Validation Contract](validation-contract.md) for validation levels and sync-gating semantics. See the [Validation Results Contract](validation-results-contract.md) for the status-posting contract, pipeline registry, and onboarding convention.

### Two valid validation paths

| Path | Who runs it | How a sample opts in | What it reports | Best fit |
|------|-------------|----------------------|-----------------|----------|
| **A. Use the central pipeline** | DevX Engineering ADO validation | Add `sample.yaml` in the sample directory | `validation/ado-build/<sample-path>` with L1-L3 status | Path of least resistance for ordinary build/load validation |
| **B. Bring your own pipeline** | Owning feature team / partner team infrastructure | Define the pipeline's tracked set and post statuses per `docs/validation-results-contract.md` | `validation/<pipeline-id>/<sample-path>` with the team's validation result | Live-resource, service-specific, or Level 4 validation |

#### Path A: central pipeline

Add a `sample.yaml` file in the sample directory. The ADO `validation.yml` pipeline discovers sample directories containing `sample.yaml`, validates build readiness through Level 3 (Load), and reports per-sample GitHub commit statuses using pipeline id `ado-build`:

```text
validation/ado-build/<sample-path>
```

This is the default path for most partner samples. It proves that the sample parses, dependencies resolve, and the code loads or builds successfully according to the [Validation Contract](validation-contract.md).

#### Path B: team-owned pipeline

Feature teams may run validation in their own infrastructure: GitHub Actions, Azure DevOps, or another internal system with permission to post commit statuses to `microsoft-foundry/foundry-samples-pr`.

The pipeline must post per-sample GitHub commit statuses following the [Validation Results Contract](validation-results-contract.md):

```text
validation/<pipeline-id>/<sample-path>
```

This is how a team can add Level 4 (Run) coverage: provision real Azure resources, deploy the sample, and exercise it end-to-end. Level 4 is additive; it does not lower or replace the Level 3 floor.

### Hosted Agents canary

Hosted Agents is the canary shape for team-owned validation. `.github/workflows/hosted-agents-cloud-e2e.yml` discovers Hosted Agents samples, uses federated-OIDC Azure login, runs `azd provision` / `azd deploy` against real Azure resources when configured, and invokes the deployed agent. Per-sample commit-status posting under the External Validation Contract is rolling out via D5 (see `docs/validation-story-decisions.md` §9): an initial single-sample canary on `samples/python/hosted-agents/agent-framework/responses/01-basic`, widened to the full HA matrix after the gate honors a deliberately-failed status end-to-end.

Its status namespace is:

```text
validation/hosted-agents-e2e/<sample-path>
```

Use Hosted Agents as the reference model for any team that wants live-resource validation: own the tracked set, run the infrastructure you need, and post durable per-sample statuses on `main` commits.

### Onboarding a team-owned validation pipeline

Onboarding is intentionally lightweight:

1. Pick a stable `pipeline-id`.
2. Open a doc PR adding the pipeline to the registry in [Validation Results Contract](validation-results-contract.md).
3. Start posting statuses under `validation/<pipeline-id>/<sample-path>`.

No central repo-code change is required for v1 registration. The sync gate honors well-formed validation statuses on the target SHA.

### What validation checks

The central pipeline validates **build readiness level 3 (load)**: it confirms that the sample code parses, dependencies resolve, and the code loads without error. It does **not** execute the sample against live endpoints or verify functional correctness.

Team-owned pipelines may add service-specific checks, including **Level 4 (run)** validation against live resources. Those pipelines own their criteria and must make failures actionable through `target_url` evidence in the posted status.

### Common partner issues

| Issue | Resolution |
|-------|-----------|
| Missing `requirements.txt` / `package.json` | Partner must add dependency manifest |
| Missing `sample.yaml` for Path A | Partner must add `sample.yaml`, or DRI must onboard a Path B reporter |
| Team-owned pipeline does not post status on `main` HEAD | Owning team must fix status publishing before the sample can sync reliably |
| Hardcoded paths or credentials | Partner must use env vars or config files |
| Imports from unpublished packages | Partner must use publicly available packages |
| Sample only works on specific OS | Document requirement; CI runs Linux unless the owning pipeline documents another environment |

## Escalation and SLA

### 4 Business Day SLA

When a partner sample fails validation (scheduled or on push):

1. **Day 0**: Failure detected. DevX determines if it's a build issue (our fix) or functional issue (partner fix).
2. **Day 0–1**: If partner fix needed, DRI notifies partner with details.
3. **Day 4**: If no response or fix, the sample is **removed from sync** — DevX deletes the sample from private `main` (or moves it out of synced paths), so the next sync run propagates the removal to public. The sample's history remains in private repo.
4. **Reinstatement**: Partner can re-enable by fixing the issue and contacting the DRI; the sample is restored via PR.

> Note: "Removed from sync" is a content action (deletion or relocation), not a manifest flip. Validation statuses can hold a sample back from sync while it is failing; permanent removal still requires deleting or relocating the sample. See [Repo Sync Automation](repo-sync-automation.md) for sync mechanics.

### Escalation path

```
Validation failure detected
  → DevX triages (build vs. functional)
    → Build issue: DevX fixes (best-effort)
    → Functional issue:
      → DRI notifies partner (Day 0)
      → No response by Day 4: remove from sync
      → Partner responds: normal PR flow to fix
```

## Removing a Partner Sample

Samples are removed from public sync when:

1. Partner is unresponsive past SLA on a functional failure
2. Partner explicitly requests removal
3. The underlying API or service is deprecated
4. Repeated build failures with no maintainer engagement

Removal is a **content action**: DevX deletes the sample from private `main` (or relocates it to an excluded path like `internal/archive/`). The next sync run propagates the deletion to public. The sample's full history remains in the private repo and can be reinstated via PR.

## Changelog

| Date | Change |
|------|--------|
| 2026-04-29 | Validation framing updated to admit team-owned pipelines as a first-class category. See `docs/validation-story-decisions.md`. |

## Related Documents

- [Validation Story — Phase B Decisions](validation-story-decisions.md) — Locked validation and sync-gating decisions
- [Validation Contract](validation-contract.md) — Validation levels, `sample.yaml`, tracked vs. untracked samples, and sync-gating semantics
- [Validation Results Contract](validation-results-contract.md) — Pipeline registry and GitHub commit status posting convention for central and team-owned pipelines
- [Repo Sync Automation](repo-sync-automation.md) — How validated samples reach the public repo
- [CONTRIBUTING.md](../CONTRIBUTING.md) — Contributor guide (applies equally to partners)
- [Pipeline README](../.azure-pipelines/README.md) — Operational details of the central ADO validation pipeline
