# Internal Directory

This directory contains internal tooling, templates, and content that is **excluded from syncing to the public foundry-samples repository**.

## Purpose

The `internal/` directory serves as the home for:

- **CI/CD pipelines** - Azure DevOps pipelines for sample generation and validation
- **Sample templates** - Source templates used to generate code samples
- **Tooling** - Scripts and utilities for development workflows
- **Internal documentation** - Documentation for internal processes

## Sync Behavior

### From foundry-samples → foundry-samples-pr
All content from the public `foundry-samples` repository syncs to the root of `foundry-samples-pr`.

### From foundry-samples-pr → foundry-samples
The `internal/` directory is **automatically excluded** from any sync operations to the public repository. This means:

- Content in `internal/` will never appear in `foundry-samples`
- You can safely add internal-only tooling, experimental features, or proprietary content here
- The exclusion is based on the directory path, not file patterns

## Directory Structure

```
internal/
└── tools/
    ├── ci/                    # CI/CD pipeline configuration
    │   ├── azure-pipelines.yml
    │   ├── configs/           # Pipeline configuration files
    │   ├── scripts/           # Validation and build scripts
    │   └── validation-config-defaults/
    ├── sample-configs/        # Sample generation configuration
    ├── sample-templates/      # Source templates for code generation
    └── sample-template-archive/  # Archived/deprecated templates
```

## Repo Sync Automation

The sync from `foundry-samples-pr` → `foundry-samples` is automated via a GitHub Actions workflow (`.github/workflows/sync-to-public.yml`).

### Required Secrets

The following secrets must be configured in the `foundry-samples-pr` repository settings:

| Secret | Description |
|--------|-------------|
| `SYNC_APP_ID` | GitHub App ID for the `foundry-samples-repo-sync` app |
| `SYNC_APP_PRIVATE_KEY` | Private key (PEM) for the `foundry-samples-repo-sync` app |

### GitHub App Setup

1. The GitHub App `foundry-samples-repo-sync` must be created under the `microsoft-foundry` org
2. **Required permissions:** Contents (Read & Write), Pull Requests (Read & Write)
3. **Install** the app on both `foundry-samples-pr` and `foundry-samples` repositories
4. Generate a private key and store it as `SYNC_APP_PRIVATE_KEY` in this repo's secrets

### Sync Configuration

Exclusion paths and target repo settings are defined in `.github/sync-config.json`. To exclude additional paths from syncing, add them to the `exclude_paths` array.

### Manual Trigger

The sync workflow can be triggered manually from the Actions tab → `Sync to Public Repo` → `Run workflow`.

---

## Guidelines

### Adding Internal Content

1. Place all internal-only content within the `internal/` directory
2. Do not add symlinks or references from `internal/` to public content that would break after sync
3. Update paths in any scripts if you add new subdirectories

### What Belongs Here

- ✅ CI/CD pipelines and scripts
- ✅ Code generation templates
- ✅ Internal tooling and utilities
- ✅ Experimental or preview features
- ✅ Internal documentation

### What Does NOT Belong Here

- ❌ Public samples (these go in `samples/`, `samples-classic/`, etc.)
- ❌ Public documentation (README.md, CONTRIBUTING.md, etc.)
- ❌ Content intended for external consumption
