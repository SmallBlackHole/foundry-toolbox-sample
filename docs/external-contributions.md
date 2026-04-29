# External Partner Contributions

This document defines the interaction model for allowing external partners to contribute code samples to `foundry-samples-pr` and have them published to the public `foundry-samples` repository.

## Contribution Model

External partner contributions follow a **white-glove, curated** model — not open contribution. Partners are onboarded through an explicit process with a named DRI (directly responsible individual) on the Microsoft side.

### Why not open contribution?

- Samples carry the **Azure brand** — quality failures reflect on the platform, not the partner
- The validation pipeline checks **build readiness**, not functional correctness
- Partners may not have Azure subscriptions, tooling access, or familiarity with our CI system
- Ongoing maintenance burden falls on internal teams when partners don't respond

## Roles and Responsibilities

| Role | Owns | Examples |
|------|------|----------|
| **DevX Engineering** | Repo infrastructure, validation pipeline, sync process, best-effort build fixes | Fixing a broken `requirements.txt`, updating pipeline config |
| **Feature team DRI** | Functional correctness, partner relationship, escalation handling | Verifying a Mistral sample works against the Mistral API |
| **External partner** | Sample code, timely response to issues, keeping code current | Responding to "your sample broke" within SLA |

### Ownership boundaries

- DevX will **fix build breaks** (Level 2–3 failures) on a best-effort basis
- DevX will **not fix functional bugs** — those go to the DRI → partner
- If a partner sample repeatedly fails, DevX will escalate, then remove from sync after SLA expires

## Onboarding a Partner

### Prerequisites

1. A named **DRI** on the Microsoft side (usually from the feature team that owns the API the sample uses)
2. Partner has reviewed and agreed to the sample structure requirements
3. DevX has confirmed the language and tooling are supported by the validation pipeline

### Process

1. **DRI opens a request** — creates an ADO work item or contacts DevX directly
2. **DevX creates access** — grants partner contributor access to `foundry-samples-pr`
3. **Partner submits PR** — following the same structure as internal samples (see [CONTRIBUTING.md](../CONTRIBUTING.md))
4. **DRI reviews for correctness** — DevX reviews for structure and CI compatibility
5. **Merge and validate** — sample enters the normal validation + sync flow

### What partners must provide

- A `sample.yaml` file meeting the [validation contract](validation-contract.md)
- A `README.md` for the sample explaining prerequisites and usage
- A point of contact for escalations (email or GitHub handle)

## Escalation and SLA

### 4 Business Day SLA

When a partner sample fails validation (scheduled or on push):

1. **Day 0**: Failure detected. DevX determines if it's a build issue (our fix) or functional issue (partner fix).
2. **Day 0–1**: If partner fix needed, DRI notifies partner with details.
3. **Day 4**: If no response or fix, the sample is **removed from sync** — DevX deletes the sample from private `main` (or moves it out of synced paths), so the next sync run propagates the removal to public. The sample's history remains in private repo.
4. **Reinstatement**: Partner can re-enable by fixing the issue and contacting the DRI; the sample is restored via PR.

> Note: "Removed from sync" is a content action (deletion or relocation), not a manifest flip. Sync is path-based — see [Repo Sync Automation § Sync Gating: Decided Against](repo-sync-automation.md#sync-gating-decided-against).

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

## Validation Requirements

Partner samples go through the **same validation pipeline** as internal samples. There is no separate path or lower bar.

### What validation checks

The pipeline validates **build readiness level 3 (load)**: it confirms that the sample code parses, dependencies resolve, and the code loads without error. It does **not** execute the sample against live endpoints or verify functional correctness.

See the [Validation Contract](validation-contract.md) for full details on build readiness levels and the `sample.yaml` schema.

### Common partner issues

| Issue | Resolution |
|-------|-----------|
| Missing `requirements.txt` / `package.json` | Partner must add dependency manifest |
| Hardcoded paths or credentials | Partner must use env vars or config files |
| Imports from unpublished packages | Partner must use publicly available packages |
| Sample only works on specific OS | Document requirement; CI runs Linux |

## Removing a Partner Sample

Samples are removed from public sync when:

1. Partner is unresponsive past SLA on a functional failure
2. Partner explicitly requests removal
3. The underlying API or service is deprecated
4. Repeated build failures with no maintainer engagement

Removal is a **content action**: DevX deletes the sample from private `main` (or relocates it to an excluded path like `internal/archive/`). The next sync run propagates the deletion to public. The sample's full history remains in the private repo and can be reinstated via PR.

## Related Documents

- [Validation Contract](validation-contract.md) — The CI validation spec that partner samples must meet
- [Repo Sync Automation](repo-sync-automation.md) — How validated samples reach the public repo
- [CONTRIBUTING.md](../CONTRIBUTING.md) — Contributor guide (applies equally to partners)
- [Pipeline README](../.azure-pipelines/README.md) — Operational details of the validation pipeline
