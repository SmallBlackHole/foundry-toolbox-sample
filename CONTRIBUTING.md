# Contributing to Foundry Samples

This is the **private staging repository** for Azure AI Foundry documentation samples. Changes merged here are automatically synced to the public [`microsoft-foundry/foundry-samples`](https://github.com/microsoft-foundry/foundry-samples) repository on a nightly basis.

All contributions — new samples, updates, bug fixes — should be submitted as pull requests to this repo.

## How this repo works

| Repository | Visibility | Purpose |
|---|---|---|
| [`foundry-samples-pr`](https://github.com/microsoft-foundry/foundry-samples-pr) (this repo) | **Private** | Staging — submit your changes here |
| [`foundry-samples`](https://github.com/microsoft-foundry/foundry-samples) | **Public** | Published — synced nightly from this repo |

When your PR is merged into `main`:

1. CI validation runs against your sample (see [Validation](#validation) below).
2. Validation results are recorded in a manifest that tracks which samples passed, failed, or were skipped.
3. A nightly GitHub Actions workflow syncs the contents of this repo to the public `foundry-samples` repo — **but only samples that passed validation are synced**. Samples that failed or lack a `sample.yaml` file are held back.
4. Your sample becomes publicly available.

Some paths are excluded from sync (e.g., `internal/`, `.azure-pipelines/`, `.github/`). See [`.github/sync-config.json`](.github/sync-config.json) for the full exclusion list.

## Getting access

This is a private repository. To view and contribute, you need to join the GitHub organization and set up write access for your team.

### 1. Join the Microsoft Foundry GitHub Organization

1. Navigate to the **microsoft-foundry** org page on the Open Source Management Portal:
   <https://repos.opensource.microsoft.com/orgs/microsoft-foundry>
2. Click the **Join** button to add yourself to the organization.

### 2. Verify access to foundry-samples-pr

Once you've joined the org, confirm you can view this repository:

<https://github.com/microsoft-foundry/foundry-samples-pr>

If you can see the repo, proceed to the next step. If not, ensure your org membership was completed successfully.

### 3. Elevate to Repository Administrator (temporary)

You'll need temporary admin access to create a GitHub Team for your group. This is a one-time setup per team.

1. Navigate to the **foundry-samples-pr** repo page on the Open Source Management Portal:
   <https://repos.opensource.microsoft.com/orgs/microsoft-foundry/repos/foundry-samples-pr>
2. In the right sidebar, find the **Just-in-time elevation** section.
3. Click **Elevate to Administrator** and follow the prompts.
4. You'll receive a confirmation that Administrator access has been granted.

### 4. Create a GitHub Team for your group

With admin access, you'll create a team that grants write access to all members of your group.

1. From the Open Source Management Portal repo page (step 3), click **Open on GitHub.com** to go to the repo on GitHub.
2. Click the **Settings** tab.
3. In the left sidebar, click **Collaborators and teams**.
4. Click **Add teams** and then **Create a new team**.
5. Name the team after your group (e.g., `fabrikam-extensions`).
6. Set **`foundry-samples-writers`** as the parent team. This ensures your team inherits write permissions.
7. Once the team is created, click on it and use **Add a member** to add yourself and your teammates.

> [!NOTE]
> Team members must have already completed [step 1](#1-join-the-microsoft-foundry-github-organization) (joined the `microsoft-foundry` org) before they can be added to a team. If you can't find a teammate when adding members, have them join the org first. You can check teammates' enrollment directly in https://repos.opensource.microsoft.com/orgs/microsoft-foundry/people?q= using their github or msft alias.

## Submitting a pull request

### Before you start

1. Search the [open pull requests](https://github.com/microsoft-foundry/foundry-samples-pr/pulls) to make sure your change isn't already in progress.
2. Confirm this is the right repo for your contribution:
   - **In scope:** Sample code, notebooks, and supporting files that demonstrate Azure AI Foundry scenarios.
   - **Out of scope:** Long-form documentation (use the [azure-docs repository](https://github.com/MicrosoftDocs/azure-docs) instead).

### Set up your environment

1. **Clone the repo** (this repo uses feature branches, not forks):

   ```shell
   git clone https://github.com/microsoft-foundry/foundry-samples-pr.git
   cd foundry-samples-pr
   ```

2. **Install dev dependencies** (for Python contributors):

   ```shell
   python -m pip install -r dev-requirements.txt
   ```

3. **Set up pre-commit** to catch formatting and lint issues locally:

   ```shell
   pre-commit install
   ```

   This runs [black](https://github.com/psf/black), [ruff](https://github.com/astral-sh/ruff), and [nb-clean](https://github.com/srstevenson/nb-clean) automatically on each commit. You can also run it manually:

   ```shell
   pre-commit run --all-files
   ```

### Make your changes

1. Create a feature branch:

   ```shell
   git checkout -b your-name/short-description
   ```

2. Add or update your sample. Samples follow the directory structure `samples/<language>/<area>/<feature>/` and each sample directory must include a `sample.yaml` file. See the [Validation Pipeline README](.azure-pipelines/README.md) for the full spec on directory layout and `sample.yaml` format.

3. Include a descriptive `README.md` in your sample directory.

### Submit your PR

1. Push your branch and open a pull request against `main`:

   ```shell
   git push origin your-name/short-description
   ```

2. Fill out the PR description and complete any checklist items.
3. Respond to reviewer feedback and resolve any failing CI checks.

> [!IMPORTANT]
> If your contribution is time-sensitive, plan accordingly — PRs require review and CI checks before merge, and the public sync runs nightly.

## Validation

An Azure DevOps pipeline automatically validates samples on every PR and on pushes to `main`. Validation results **gate the nightly sync to public** — only samples that pass validation reach `foundry-samples`.

### How it works

1. The pipeline discovers sample directories by looking for `sample.yaml` files.
2. For each sample, it runs the language-specific build and validate commands.
3. Results are collected into a **validation manifest** and pushed to the `validation-results` branch.
4. The nightly sync workflow reads this manifest and decides what to sync.

### Build readiness levels

Validation measures **build readiness** — whether your code can be built and loaded by a customer who copies it. There are three cumulative levels:

| Level | Name | What it checks | Example |
|-------|------|----------------|---------|
| 1 | **Syntax** | Does the code parse? | `python -m py_compile sample.py` |
| 2 | **Resolution** | Do dependencies install? | `pip install -r requirements.txt` |
| 3 | **Load** | Does the code load without error? | `python -c "import sample"` |

**The sync threshold is level 3 (load).** Your sample must demonstrate that its code loads with all dependencies resolved. If it doesn't load, it doesn't sync.

### What you need to provide

Every sample directory must contain a **`sample.yaml`** file. A minimal config is:

```yaml
name: my-sample
description: A brief description of what this sample demonstrates
```

The pipeline applies default validation per language (e.g., `dotnet build` for C#, `pip install && py_compile` for Python). You can override with custom `build`, `validate`, and `test` commands in `sample.yaml`.

For the full `sample.yaml` schema, directory structure, and per-language defaults, see the [Validation Pipeline README](.azure-pipelines/README.md).

#### Reference validate commands

For samples that specify a custom `validate` command, these are the recommended patterns by language:

| Language | `build` | `validate` | What it proves |
|----------|---------|------------|----------------|
| Python | `pip install -r requirements.txt` | `python -c "import sample"` | Deps resolve, code loads |
| C# | `dotnet restore` | `dotnet build` | Compilation proves load |
| Java | `mvn dependency:resolve` | `mvn compile` | Compilation proves load |
| Go | `go mod download` | `go build ./...` | Compilation proves load |
| TypeScript | `npm install` | `npx tsc --noEmit` | Type-checks all imports |
| JavaScript | `npm install` | `node -e "require('./sample')"` | Deps resolve, code loads |

### What happens when…

| Scenario | Effect on sync | Effect on PRs |
|----------|---------------|---------------|
| ✅ Validation passes | Sample syncs to public | PR checks pass |
| ❌ Validation fails | Sample does **not** sync | PR checks fail — must fix before merging |
| ⚠️ No `sample.yaml` | Sample does **not** sync (treated as skipped) | No validation runs for this directory |
| 🕐 Sample modified after last validation | Sample does **not** sync until re-validated | N/A (applies to main branch only) |

> [!IMPORTANT]
> If your sample directory does not contain a `sample.yaml` file, it will not be validated and **will not sync to public**. Adding `sample.yaml` is the single most important step for any sample.

### Graceful degradation

If the validation manifest is unavailable (e.g., the `validation-results` branch hasn't been created yet), the sync workflow falls back to syncing everything — no samples are blocked. This ensures the gating system is additive and won't break existing sync behavior during rollout.

## Fixing pre-commit failures

If pre-commit checks fail on your PR:

| Check | Fix |
|---|---|
| **black** | `pre-commit run black --all-files` and commit the changes |
| **ruff** | `pre-commit run ruff --all-files` and commit. For issues ruff can't auto-fix, see the [ruff rule list](https://docs.astral.sh/ruff/rules/). |
| **nb-clean** | `pre-commit run nb-clean --all-files` and commit the changes |

> [!TIP]
> To avoid exposing secrets in committed code, use empty string placeholders:
> ```python
> os.environ["AZURE_SUBSCRIPTION_ID"] = ""
> ```

## Discoverability

Samples can be indexed in the [Microsoft code samples browser](https://learn.microsoft.com/samples). To enable this, add YAML frontmatter to your sample's `README.md`:

```yaml
---
page_type: sample
languages:
- python
products:
- ai-services
description: Brief description of the sample.
---
```

See the [product taxonomy](https://review.learn.microsoft.com/en-us/help/platform/metadata-taxonomies?branch=main#product) and [language taxonomy](https://review.learn.microsoft.com/en-us/help/platform/metadata-taxonomies?branch=main#dev-lang) for valid values.

## Contributor License Agreement

This project requires a Contributor License Agreement (CLA). When you submit a pull request, a CLA bot will check whether you need to sign one and guide you through the process. You only need to do this once across all Microsoft repos. For details, visit https://cla.opensource.microsoft.com.

## Code of Conduct

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information, see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com).

