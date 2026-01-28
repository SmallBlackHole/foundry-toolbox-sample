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
