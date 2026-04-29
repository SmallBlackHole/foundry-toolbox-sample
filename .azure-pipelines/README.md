# Sample Validation Pipeline

This directory contains the Azure DevOps pipeline configuration for validating code samples in this repository.

## Overview

The `validation.yml` pipeline automatically validates code samples across multiple languages:
- **C#**
- **Python**
- **TypeScript/JavaScript**
- **Java**
- **Go**

## When Does Validation Run?

| Trigger | Scope | Description |
|---------|-------|-------------|
| **Pull Request** | Changed samples only | Validates samples modified in the PR |
| **Push to main** | Changed samples only | Validates samples changed in the commit |
| **Scheduled (Mon/Wed/Fri)** | All samples | Full validation to catch SDK drift |
| **Manual (validateAll=true)** | All samples | On-demand full validation |

## Pipeline Stages

1. **DetectChanges** - Identifies which samples were modified
2. **Validate** - Runs language-specific validation jobs in parallel
3. **Report** - Summarizes results

---

## Adding a New Sample

### Directory Structure

Samples follow a `samples/<language>/<area>/<feature>` structure:

```
samples/
└── <language>/           # csharp, python, java, typescript, go
    └── <area>/           # Feature area (e.g., chat, embeddings, audio)
        └── <feature>/    # Specific feature or variation
            ├── sample.yaml       # Sample configuration
            ├── <source files>    # Language-specific files
            └── ...
```

**Example:**
```
samples/
└── python/
    └── chat/
        └── streaming/
            ├── sample.yaml
            ├── requirements.txt
            └── sample.py
```

### The `sample.yaml` File

Every sample **must** have a `sample.yaml` file in its root directory. This file identifies the directory as a sample and optionally defines custom validation commands.

#### Minimal `sample.yaml`

If your sample uses standard build tools, you can use a minimal configuration:

```yaml
name: my-sample
description: A brief description of what this sample demonstrates
```

The pipeline will use **default validation** based on the language:
- **C#**: `dotnet build *.csproj`
- **Python**: Create venv, `pip install -r requirements.txt`, syntax check with `py_compile`
- **TypeScript/JS**: `npm install`, `npm run build`
- **Java**: `mvn compile` or `gradle build`
- **Go**: `go build ./...`

#### Custom Validation Commands

For samples that need custom build, validation, or test commands, specify them in `sample.yaml`:

```yaml
name: my-sample
description: A sample with custom validation

# Optional: Custom commands (run in order if specified)
build: dotnet build -c Release
validate: dotnet format --verify-no-changes
test: dotnet test --no-build
```

| Field | Description | Required |
|-------|-------------|----------|
| `name` | Sample identifier | Recommended |
| `description` | What the sample demonstrates | Recommended |
| `build` | Build command | Optional |
| `validate` | Validation/lint command | Optional |
| `test` | Test command | Optional |

> **📖 Full spec:** For complete details on build readiness levels, sync gating, and the validation contract, see [`docs/validation-contract.md`](../docs/validation-contract.md).

**Behavior:**
- If **any** of `build`, `validate`, or `test` are specified, those commands are run and default validation is skipped
- If **none** are specified, the pipeline uses default language-specific validation
- Commands run in order: `build` → `validate` → `test`
- If any command fails, the sample is marked as failed

### Example

#### Python Sample with Custom Commands

```yaml
name: chat-completion
description: Basic chat completion with Azure OpenAI

build: pip install -r requirements.txt
validate: python -m py_compile main.py
test: python -m pytest tests/ -v
```