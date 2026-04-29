# Validation Contract

This document defines the contract between sample authors and the validation pipeline in `foundry-samples-pr`. It answers: **what must a sample demonstrate in order to be eligible for sync to public?**

## Build Readiness Levels

Validation measures **build readiness** — can a customer clone and run the code? There are three cumulative levels:

| Level | Name | What it proves | Example (Python) |
|-------|------|----------------|------------------|
| 1 | **Parse** | Code is syntactically valid | `python -m py_compile sample.py` |
| 2 | **Resolve** | Dependencies install cleanly | `pip install -r requirements.txt` exits 0 |
| 3 | **Load** | Code loads with all dependencies resolved | `python -c "import sample"` exits 0 |

**The sync threshold is Level 3 (Load).** A sample that doesn't demonstrate load-readiness does not sync to public.

### Why Level 3 and not "runs end-to-end"?

Samples in this repo typically require Azure credentials, deployed resources, or live endpoints. Full execution isn't feasible in CI. Level 3 proves that a customer who has the prerequisites will get working code — not an import error.

## The `sample.yaml` Contract

Every sample directory must contain a `sample.yaml` file. This is how the pipeline discovers samples and determines how to validate them.

### Schema

```yaml
# Required metadata
name: my-sample                   # Human-readable identifier
description: What this demonstrates  # Brief description

# Optional validation commands (run in order)
build: <command>       # Build step (Level 2: resolve dependencies)
validate: <command>    # Validation step (Level 3: prove load-readiness)
test: <command>        # Test step (optional, post-validation)
```

### Behavior rules

1. If **any** of `build`, `validate`, or `test` are specified, those commands run and language defaults are skipped.
2. If **none** are specified, the pipeline applies default validation based on the language directory.
3. Commands run in order: `build` → `validate` → `test`. If any step exits non-zero, the sample fails.
4. A directory without `sample.yaml` is **invisible** to the pipeline — it is not validated and does not sync.

### Default validation by language

When `sample.yaml` has no custom commands, these defaults apply:

| Language | Default build | Default validation |
|----------|---------------|--------------------|
| C# | `dotnet build *.csproj` | — (build proves load) |
| Python | Create venv + `pip install -r requirements.txt` | `py_compile` all `.py` files |
| TypeScript/JS | `npm install` | `npm run build` (if build script exists) |
| Java | `mvn compile` or `gradle build` | — (compilation proves load) |
| Go | `go build ./...` | — (compilation proves load) |

### Recommended custom commands

For samples that specify custom validation, use these patterns:

| Language | `build` | `validate` | What it proves |
|----------|---------|------------|----------------|
| Python | `pip install -r requirements.txt` | `python -c "import sample"` | Deps resolve, code loads |
| C# | `dotnet restore` | `dotnet build` | Compilation proves load |
| Java | `mvn dependency:resolve` | `mvn compile` | Compilation proves load |
| Go | `go mod download` | `go build ./...` | Compilation proves load |
| TypeScript | `npm install` | `npx tsc --noEmit` | Type-checks all imports |
| JavaScript | `npm install` | `node -e "require('./sample')"` | Deps resolve, code loads |

## Validation Results Manifest (Decided Against)

> **Status: Not pursued.** See [Implementation Status](#implementation-status) and [Sync Gating](#sync-gating) below.

Earlier drafts of this contract specified a structured JSON manifest published to a `validation-results` branch, intended to be the data source for sync gating. That design has been **set aside** in favour of treating validation results as **PR-time signals to humans**, not pipeline-consumed data.

What this means in practice:

- Validation still runs on every PR and on a schedule.
- Validation results are reported via PR comments and pipeline run summaries.
- There is no manifest branch, no JSON contract, and no machine-readable cross-run state.
- The pipeline's job is to *tell humans whether a sample builds*; the humans' job is to act on that signal before merging.

The schema below is preserved as a record of what was contemplated, not as an implementation target.

### Manifest schema (historical / not implemented)

```json
{
  "generatedAt": "2024-03-15T06:00:00Z",
  "pipelineRun": "https://dev.azure.com/...",
  "results": [
    {
      "samplePath": "samples/python/chat/streaming",
      "language": "python",
      "readinessLevel": 3,
      "status": "pass",
      "lastValidatedCommit": "abc123f",
      "duration": "12s"
    }
  ]
}
```

### Fields (historical)

| Field | Description |
|-------|-------------|
| `samplePath` | Relative path from repo root |
| `language` | Detected language |
| `readinessLevel` | Highest level achieved (1, 2, or 3) |
| `status` | `pass`, `fail`, or `skip` |
| `lastValidatedCommit` | Commit SHA when this sample last passed |
| `duration` | How long validation took |

## Sync Gating

> **Status: Not pursued.** Sync is path-based, not validation-based.

The public-repo sync ships whatever is on private `main` (minus the path exclusions in `.github/sync-config.json`), regardless of validation status.

| Manifest status | Sync behavior |
|----------------|---------------|
| `pass` (level 3) | ✅ Synced (because it's on `main`) |
| `fail` | ✅ Synced (because it's on `main`) — author/reviewer responsibility to not merge it in the first place |
| `skip` (no `sample.yaml`) | ✅ Synced (the directory exists; the pipeline just doesn't validate it) |
| Manifest unavailable | n/a — sync does not consult a manifest |

Why this split exists:

- **Authors and PR reviewers** decide what merges to private `main`. The validation pipeline informs that decision via PR comments.
- **The sync pipeline** is a deterministic mirror — it doesn't make per-file judgements about quality.
- **Drift verification** (see [`verify-sync.yml`](../.github/workflows/verify-sync.yml)) confirms public matches private, but does not check validation status.

This keeps each system's responsibility narrow and operable. See [Repo Sync Automation § Sync Gating: Decided Against](repo-sync-automation.md#sync-gating-decided-against) for the matching note on the sync side.

## When Validation Runs

| Trigger | Scope | Purpose |
|---------|-------|---------|
| Pull request to `main` | Changed samples only | Fast feedback for authors |
| Push to `main` | Changed samples only | Update manifest for sync |
| Scheduled (Mon/Wed/Fri) | All samples | Catch SDK drift and broken dependencies |
| Manual (`validateAll=true`) | All samples | On-demand full sweep |

## Onboarding Phases

This contract is being adopted incrementally:

### Phase 1: Fix existing samples (current)

- Replace `echo 'SKIP:...'` workarounds with real validation commands
- Add `sample.yaml` to samples that lack one
- Target: ~15 existing samples brought to Level 3

### Phase 2: Audit and curation

- Full audit of all sample directories
- Remove or archive stale samples
- Onboard additional teams with documentation and support
- Establish monitoring (issue creation on scheduled failures)

### Phase 3: Hard enforcement (reserved)

- Reject PRs that merge without passing validation (PR-time enforcement, not sync-time)
- Tighten required-checks on private `main` so a red validation run blocks the merge button
- Requires Phase 1+2 to be complete; timing TBD

> Note: Phase 3 specifically does **not** include sync-time gating. See [Sync Gating](#sync-gating) above.

## Implementation Status

> **Last updated:** See git log for this file.

| Feature | Status | Notes |
|---------|--------|-------|
| Per-language default validation | ✅ Implemented | validation.yml handles 5 languages |
| `sample.yaml` discovery | ✅ Implemented | Pipeline uses `yq` to parse fields |
| Custom build/validate/test commands | ✅ Implemented | Overrides defaults when present |
| PR comment reporting | ✅ Implemented | GitHubComment@0 task posts results |
| Structured manifest (JSON) | ❌ Not pursued | Decided against; validation results are PR signals, not pipeline data. See [Manifest section](#validation-results-manifest-decided-against). |
| Sync gating (manifest-based) | ❌ Not pursued | Sync is path-based; gating is an author/PR-review responsibility. See [Sync Gating](#sync-gating). |
| `lastValidatedCommit` staleness check | ❌ Not pursued | Subsumed by the no-manifest decision above. |
| Issue creation on scheduled failure | 🔲 Not yet | Failures are only visible in pipeline logs |
| `samples-classic/` coverage | 🔲 Not yet | Classic samples are not validated |

## Related Documents

- [Repo Sync Automation](repo-sync-automation.md) — How the nightly sync from private to public works
- [External Contributions](external-contributions.md) — Partner contribution model and SLAs
- [Pipeline README](../.azure-pipelines/README.md) — Operational details of the validation pipeline
- [CONTRIBUTING.md](../CONTRIBUTING.md) — Contributor guide with validation quick-reference
