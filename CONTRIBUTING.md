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

This is a private repository. To contribute you need to (1) join the GitHub org, (2) get write access, and optionally (3) set up your team for review routing. **No central gatekeeper is required** — teams manage their own membership.

### 1. Join the Microsoft Foundry GitHub Organization

1. Navigate to the **microsoft-foundry** org page on the Open Source Management Portal:
   <https://repos.opensource.microsoft.com/orgs/microsoft-foundry>
2. Click the **Join** button to add yourself to the organization.
3. Confirm you can view this repository: <https://github.com/microsoft-foundry/foundry-samples-pr>

### 2. Get write access

Write access comes from membership in [`foundry-samples-writers`](https://github.com/orgs/microsoft-foundry/teams/foundry-samples-writers) or any of its child teams. Choose whichever path fits:

| Path | When to use |
|---|---|
| **Join an existing child team** | Your group already has a team (e.g., `hosted-agents`, `agents-service`). This is the most common case. |
| **Get added to `foundry-samples-writers` directly** | You're an individual contributor, or your group doesn't need its own team. |
| **Create a new child team** | Your group is contributing a new sample area and wants to own reviews for it. |

#### Join an existing child team

1. Find your team on GitHub under [foundry-samples-writers → child teams](https://github.com/orgs/microsoft-foundry/teams/foundry-samples-writers/teams), or search the [Open Source Portal teams page](https://repos.opensource.microsoft.com/orgs/microsoft-foundry/teams).
2. Ask a **Maintainer** of that team to add you. To find Maintainers, open the team page on GitHub and filter members by **Role → Maintainer**.
3. [Verify write access](#verify-write-access) below.

#### Get added to `foundry-samples-writers` directly

Ask any Maintainer of [`foundry-samples-writers`](https://github.com/orgs/microsoft-foundry/teams/foundry-samples-writers) to add you. This grants write access immediately without creating or joining a child team.

#### Create a new child team

This requires temporary admin access (one-time setup per team):

1. Navigate to the **foundry-samples-pr** repo page on the Open Source Management Portal:
   <https://repos.opensource.microsoft.com/orgs/microsoft-foundry/repos/foundry-samples-pr>
2. In the right sidebar, click **Elevate to Administrator** under Just-in-time elevation.
3. Click **Open on GitHub.com** → **Settings** → **Collaborators and teams**.
4. Click **Add teams** → **Create a new team**.
5. Name the team after your group (e.g., `fabrikam-extensions`).
6. Set **`foundry-samples-writers`** as the parent team. This gives your team inherited write permissions.
7. Add your teammates and **promote at least two people to Maintainer** (see [Managing your team](#managing-your-team)).
8. Add a [CODEOWNERS entry](#set-up-codeowners-for-your-sample-area) for your sample paths so PRs route to your team automatically.

> [!NOTE]
> Team members must have already joined the `microsoft-foundry` org ([step 1](#1-join-the-microsoft-foundry-github-organization)) before they can be added to a team. You can check enrollment at <https://repos.opensource.microsoft.com/orgs/microsoft-foundry/people?q=> using a GitHub or Microsoft alias.

> [!TIP]
> **Can't find a Maintainer, or no one responds?** Any org member can use JIT admin elevation (described above in "Create a new child team") to temporarily gain admin access and add themselves.

#### Verify write access

After joining a team, confirm you can push a branch:

```shell
git clone https://github.com/microsoft-foundry/foundry-samples-pr.git
cd foundry-samples-pr
git checkout -b test/your-name-access-check
git push origin test/your-name-access-check
git push origin --delete test/your-name-access-check
```

## Owning your samples

Multiple teams contribute samples to this repo. To ensure PRs get reviewed by the people who actually know the code, each team should own their sample paths via [CODEOWNERS](https://docs.github.com/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners) and manage their own team membership.

### Set up CODEOWNERS for your sample area

When your team owns a sample area (e.g., `samples/*/hosted-agents/`), add an entry to [`.github/CODEOWNERS`](.github/CODEOWNERS) so your team is automatically requested for review on PRs that touch those paths.

The pattern to follow is:

```
/samples/<language>/<area>/  @microsoft-foundry/<team-slug>
```

For example, if your team `hosted-agents` owns the hosted-agents samples across all languages:

```
/samples/python/hosted-agents/  @microsoft-foundry/hosted-agents
/samples/csharp/hosted-agents/  @microsoft-foundry/hosted-agents
```

To add your entry, open a PR that edits `.github/CODEOWNERS` — add your lines **above** the AI Platform Docs section (marked with a comment).

> [!IMPORTANT]
> CODEOWNERS controls **review routing only** — it does not grant write access. Access is controlled through team membership as described in [Getting access](#getting-access).

### Managing your team

Each team is responsible for its own membership. There is no central approval process — **team Maintainers are the owners**.

**Adding members:** Go to your [team page on GitHub](https://github.com/orgs/microsoft-foundry/teams/foundry-samples-writers/teams), click **Add a member**, and search for the person's GitHub username. New members must have already [joined the org](#1-join-the-microsoft-foundry-github-organization).

**Promoting Maintainers:** On the team page, click the **Role** dropdown next to a member's name and select **Maintainer**. Maintainers can add/remove members and promote other Maintainers.

> [!IMPORTANT]
> **Every team should have at least two Maintainers.** If a team has only one Maintainer and they leave, the team becomes orphaned and no one can manage membership. If you find yourself in this situation, use [JIT admin elevation](#create-a-new-child-team) to regain access.

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

