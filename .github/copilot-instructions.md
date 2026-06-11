## Files owned by the AI Platform Docs team

If a file is listed in the CODEOWNERS file with @azure-ai-foundry/ai-platform-docs as the owner, it is owned by the AI Platform Docs team.  For these files:

- Do not change the filename or move the file.
- Do not remove any comments which contain <some_text> or </some_text> (for any text in between the tags)
- Do not remove any cell in a notebook if it contains metadata with "name:" in it.

In a code review, if any of the above rules are broken, please add the following text to your review:
🛑STOP! This PR contains changes that may break documentation.  Please post a message on [ai-platform-docs](https://teams.microsoft.com/l/team/19%3AHhf4F_YfPn3kYGdmWvePNwlbF5-RR8wciQEUwwrcggw1%40thread.tacv2/conversations?groupId=fdaf4412-8993-4ea6-a7d4-aeaded7fc854&tenantId=72f988bf-86f1-41af-91ab-2d7cd011db47) to request help.

Only files owned by the AI Platform Docs team are subject to these rules. 

## Repository governance

This repo has detailed governance documentation in `docs/`:

- `docs/validation-story-decisions.md` — Locked validation direction. For validation-related work, this wins if docs appear to disagree.
- `docs/validation-contract.md` — Validation behavior, `sample.yaml` contract, build readiness levels, and sync-gating semantics.
- `docs/validation-results-contract.md` — How ADO, GitHub Actions, and external pipelines post per-sample GitHub commit statuses that participate in sync gating.
- `docs/repo-sync-automation.md` — How private-to-public sync works, including static exclusions, dynamic validation exclusions, fast-export/import, author rewriting, and PR automation.
- `docs/external-contributions.md` — Partner contribution model, validation paths, 4 business day SLA, and escalation path.

When answering questions about validation, sync behavior, or the contribution process, reference these docs rather than guessing.

## Validation and sync direction

Validation gates public sync. The sync gate is a per-sample block-list driven by GitHub commit statuses on the private `main` commit being synced. Status contexts use `validation/<pipeline-id>/<sample-path>`; `failure`, `error`, or `pending` blocks that sample, while `success` does not. Samples with no reporting pipeline are untracked/grandfathered and sync ungated in v1.

## Sample structure

Samples generally live under `samples/<language>/<area>/<feature>/`. Add `sample.yaml` when using the central ADO validation pipeline; it discovers directories under `samples/` that contain `sample.yaml` and validates them to Level 3 (Load). External/team-owned pipelines may track samples through their own manifests and must report statuses per `docs/validation-results-contract.md`.

## Sync exclusions

The exclusion list lives in `.github/sync-config.json` under `exclude_pathspecs`; consult it for the authoritative set of internal-only paths excluded from sync to public. Do not put temporary validation holds in that file; the sync gate creates dynamic per-run exclusions for blocked samples.

