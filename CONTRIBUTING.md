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
2. A nightly GitHub Actions workflow syncs the contents of this repo to the public `foundry-samples` repo.
3. Your sample becomes publicly available.

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
> Team members must have already completed [step 1](#1-join-the-microsoft-foundry-github-organization) (joined the `microsoft-foundry` org) before they can be added to a team. If you can't find a teammate when adding members, ask them to join the org first.

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

An Azure DevOps pipeline automatically validates samples on every PR. It detects which samples changed, runs language-specific build and lint checks, and reports results.

Each sample directory must contain a `sample.yaml` file. A minimal config is:

```yaml
name: my-sample
description: A brief description of what this sample demonstrates
```

The pipeline applies default validation per language (e.g., `dotnet build` for C#, `pip install && py_compile` for Python). You can override with custom `build`, `validate`, and `test` commands in `sample.yaml`.

For full details — including directory structure, all `sample.yaml` fields, and per-language defaults — see the [Validation Pipeline README](.azure-pipelines/README.md).

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

