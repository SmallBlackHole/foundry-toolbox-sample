# Auto-Redirect PR Workflow

This document is a detailed, step-by-step runbook for redirecting pull requests submitted to the **public** `microsoft-foundry/foundry-samples` repo over to the **private** `microsoft-foundry/foundry-samples-pr` staging repo. The goal is to preserve the original author's identity for `git blame` while moving all work to the correct repo.

## When to Use This

Use this workflow whenever a contributor opens a PR against `foundry-samples` (public) that should instead target `foundry-samples-pr` (private staging). This is common for external contributors who don't have access to the private repo or internal contributors who have yet to familiarize with the setup.

## Prerequisites

- **Git CLI** with push access to `microsoft-foundry/foundry-samples-pr`
- **GitHub CLI** (`gh`) authenticated with permissions on both repos
- The **source PR URL** (e.g., `https://github.com/microsoft-foundry/foundry-samples/pull/574`)

## Overview

```
Source PR on foundry-samples (public)
  │
  ├─ 1. Download patch from GitHub
  ├─ 2. Create branch on foundry-samples-pr
  ├─ 3. Apply patch (preserves original author)
  ├─ 4. Handle path differences / conflicts if any
  ├─ 5. Push and create new PR on foundry-samples-pr
  ├─ 6. Comment on original PR with link to new PR
  └─ 7. Close original PR
```

## Step-by-Step

### Step 1: Inspect the Source PR

Before starting, review the source PR to understand what it changes:

```bash
# Open the PR in your browser to review
gh pr view <number> --repo microsoft-foundry/foundry-samples --web
```

Take note of:
- The **fork branch** (e.g., `aahill:mar-update`) — you'll need this if additional commits arrive later
- The **number of commits** — so you can verify all were applied
- Whether changed files exist at the **same paths** in foundry-samples-pr (they sometimes differ)

### Step 2: Download the PR as a Patch

GitHub exposes any PR as a `.patch` file. This format preserves the original author name, email, date, and commit messages.

```bash
curl -sL https://github.com/microsoft-foundry/foundry-samples/pull/<number>.patch \
  -o /tmp/pr<number>.patch
```

Verify the patch looks correct:

```bash
head -5 /tmp/pr<number>.patch
# Should show: From <sha> ... \n From: <original author> \n Date: ...
```

### Step 3: Create a Branch on foundry-samples-pr

```bash
cd /path/to/foundry-samples-pr
git checkout main && git pull origin main
git checkout -b <author-username>/<branch-name> main
```

Use the original author's GitHub username and a descriptive branch name (e.g., `aahill/mar-update`, `huimiu/azure-ai-agents-in-workflow`).

### Step 4: Apply the Patch

**Try the simple apply first:**

```bash
git am /tmp/pr<number>.patch
```

**If it fails due to path differences**, the public and private repos may have files at different paths. Fix the patch with `sed`:

```bash
# Example: Python quickstart files are in subdirectories in foundry-samples-pr
sed \
  -e 's|old/path/to/file.py|new/path/to/file.py|g' \
  /tmp/pr<number>.patch > /tmp/pr<number>-fixed.patch

git am --3way /tmp/pr<number>-fixed.patch
```

**If conflicts remain after `--3way`**, resolve them manually:

1. Check the PR's intended final state on the fork (e.g., `https://github.com/<author>/foundry-samples/blob/<branch>/path/to/file`)
2. Write the correct content to the conflicted file
3. `git add <file>` and `git am --continue`

When resolving conflicts, also set the committer to the original author so both author and committer match:

```bash
GIT_COMMITTER_NAME="<Author Name>" GIT_COMMITTER_EMAIL="<author@email>" git am --continue
```

**If the patch approach is unworkable**, fall back to cherry-picking:

```bash
git remote add temp-fork https://github.com/<author>/foundry-samples.git
git fetch temp-fork <branch>
git cherry-pick <commit-sha1> [<commit-sha2> ...]
git remote remove temp-fork
```

Cherry-pick also preserves the original author.

### Step 5: Verify Author Attribution

Confirm the original author appears on **all** commits:

```bash
git log --format="%h %an <%ae> | %cn <%ce> | %s" -n <number-of-commits>
```

Both "author" and "committer" columns should show the original contributor. `git blame` uses the author field.

### Step 6: Push and Create the New PR

```bash
git push origin <branch-name>

gh pr create \
  --repo microsoft-foundry/foundry-samples-pr \
  --base main \
  --head <branch-name> \
  --title "<original PR title>" \
  --body "<original PR description>

Recreated from https://github.com/microsoft-foundry/foundry-samples/pull/<number>. This PR was created using \`git am\` to preserve the original author's identity for git blame purposes."
```

### Step 7: Link and Close the Original PR

Comment on the original PR with a link to the new one, then close it:

```bash
gh pr comment <number> --repo microsoft-foundry/foundry-samples \
  --body "This PR has been recreated on the staging repo with original author attribution preserved: <new-PR-URL>

Closing this PR in favor of the foundry-samples-pr version."

gh pr close <number> --repo microsoft-foundry/foundry-samples
```

If the original PR is already closed, just add the comment (skip the close).

## Handling Follow-Up Commits

Contributors may push additional commits to their fork branch after you've created the PR. To bring them over:

### If you still have the fork remote

```bash
git fetch <remote-name> <branch>
git log <remote-name>/<branch> --format="%h %an %s" -5   # identify new commits
git cherry-pick <new-commit-sha1> [<new-commit-sha2> ...]
git push origin <branch-name>
```

### If you don't have the remote yet

```bash
git remote add temp-fork https://github.com/<author>/foundry-samples.git
git fetch temp-fork <branch>
git cherry-pick <new-commit-sha>
git push origin <branch-name>
git remote remove temp-fork   # optional cleanup
```

Cherry-pick preserves the original author automatically. The new commits will appear on the existing PR since you're pushing to the same branch.

## Known Path Differences Between Repos

Some files exist at different paths in `foundry-samples` vs `foundry-samples-pr`. When applying patches, watch for these:

| foundry-samples (public) | foundry-samples-pr (private) |
|---|---|
| `samples/python/quickstart/quickstart-*.py` | `samples/python/quickstart/<subdir>/quickstart-*.py` |

If you discover new path differences, add them to this table.

## Quick Reference (Copilot Agent Edition)

When asking a Copilot agent to perform this workflow, use a prompt like:

> Migrate PR https://github.com/microsoft-foundry/foundry-samples/pull/<number> to foundry-samples-pr. Follow the auto-redirect-pr workflow: download the patch, apply with `git am` preserving original author, create a PR on foundry-samples-pr, then comment and close the original.

The agent should:
1. Fetch the PR details and patch
2. Apply with author preservation (`git am` or cherry-pick)
3. Handle any path/conflict issues
4. Create the new PR with the attribution note
5. Comment on and close the original
