# foundry-samples-pr

This is the **private staging repository** for [Microsoft Foundry](https://learn.microsoft.com/azure/ai-foundry/) documentation samples. Content merged here is automatically synced nightly to the public [`microsoft-foundry/foundry-samples`](https://github.com/microsoft-foundry/foundry-samples) repository.

## Quick links

| Resource | Description |
|----------|-------------|
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to get access, submit samples, and pass validation |
| [docs/](docs/) | Governance docs — validation contract, validation results contract, sync automation, external contributions |
| [.azure-pipelines/README.md](.azure-pipelines/README.md) | Validation pipeline details and `sample.yaml` reference |
| [.github/sync-config.json](.github/sync-config.json) | Paths excluded from sync to public |

## How it works

1. You submit a PR to this repo.
2. Validation pipelines report per-sample status. Level 3 (Load) remains the floor for tracked samples; Level 4 (Run) is opt-in through owning pipelines.
3. Once merged, the nightly sync exports only samples not blocked by validation to the public repo with author rewriting.

Internal-only paths (`internal/`, `docs/`, `.azure-pipelines/`, `.github/`, `CONTRIBUTING.md`, `README.md`) are excluded from sync.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for full details on getting access, submitting samples, and the validation pipeline.
