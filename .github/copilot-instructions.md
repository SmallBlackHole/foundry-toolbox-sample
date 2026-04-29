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

- `docs/validation-contract.md` — Validation rules, `sample.yaml` schema, build readiness levels (1–3). The sync threshold is Level 3 (Load).
- `docs/repo-sync-automation.md` — How the nightly sync from this private repo to public `foundry-samples` works (fast-export, author rewriting, exclusions).
- `docs/external-contributions.md` — Partner contribution model, 4 business day SLA, escalation path.

When answering questions about validation, sync behavior, or the contribution process, reference these docs rather than guessing.

## Sample structure

Every sample must have a `sample.yaml` in its root directory. The pipeline discovers samples by finding these files. Samples live under `samples/<language>/<area>/<feature>/`. See `.azure-pipelines/README.md` for full details on the schema and per-language defaults.

## Sync exclusions

The following paths are internal-only and excluded from sync to public: `internal/`, `docs/`, `.azure-pipelines/`, `.github/`, `CONTRIBUTING.md`, `README.md`. The exclusion list is in `.github/sync-config.json`.

