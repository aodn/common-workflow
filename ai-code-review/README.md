# AI code review (shared workflow)

Advisory AI code review for pull requests
([aodn/backlog#9370](https://github.com/aodn/backlog/issues/9370), first
trialled in `aodn-portal-v2` under
[#9311](https://github.com/aodn/backlog/issues/9311)). An AI agent reviews the
diff, reading surrounding code in a read-only checkout, for bugs, regressions,
security issues and missing tests. Each push gets a new PR comment, and
earlier reviews are collapsed as "Outdated". It complements human review and
never blocks merging.

`.github/workflows/ai-code-review.yaml` is a `workflow_call` workflow. Each
repository keeps a thin caller with its own triggers, engine choice,
credential, review prompt and instructions.

## Adopting it in a repository

1. Add `.github/ai-code-review/prompt.md`, the review direction for your code: what
   to look for and how to judge it. Start from
   [`examples/review-prompt.md`](examples/review-prompt.md). Don't include
   the sandbox, untrusted-content or output-format sections; the shared
   workflow adds those.
2. Optionally add `.github/ai-code-review/instructions.md` with repository context
   and conventions. `instruction-files` can also point at existing docs such
   as `AGENTS.md`.
3. Add the engine's API key as a repository secret (for Kiro: `KIRO_API_KEY`,
   see [Kiro engine](#kiro-engine)).
4. Add the caller workflow:

```yaml
name: AI code review

on:
  pull_request:
    branches: ["main"]
    types: [opened, synchronize, reopened, ready_for_review]
  # Manual run, e.g. to re-run after the credential is added.
  workflow_dispatch:
    inputs:
      pr-number:
        description: Pull request number to review
        type: number
        required: true

permissions: {}

# One review per PR; a new push cancels the review of the previous commit.
concurrency:
  group: ai-code-review-${{ github.event.pull_request.number || inputs.pr-number }}
  cancel-in-progress: true

jobs:
  review:
    name: Code Review
    # Required: skip fork PRs (their config is untrusted). Drafts and PRs
    # labelled skip-ai-review are skipped to save credits.
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event.pull_request.head.repo.full_name == github.repository &&
       !github.event.pull_request.draft &&
       !contains(github.event.pull_request.labels.*.name, 'skip-ai-review'))
    permissions:
      contents: read
      pull-requests: write
    uses: aodn/common-workflow/.github/workflows/ai-code-review.yaml@main
    with:
      pr-number: ${{ github.event.pull_request.number || inputs.pr-number }}
      engine: kiro
      model: ${{ vars.KIRO_MODEL }}
      prompt-file: .github/ai-code-review/prompt.md
      instruction-files: |
        .github/ai-code-review/instructions.md
    secrets:
      ai-code-review-api-key: ${{ secrets.KIRO_API_KEY }}
```

Pass the secret explicitly; don't use `secrets: inherit`. Never trigger the
review from `pull_request_target`; the workflow refuses it.

The files are read from the PR head, so the PR that adds them is already
reviewed with them. The check is named `Code Review / review`.

**Pinning:** `@main` picks up common-workflow changes immediately, which suits
an advisory check. Each run still uses one fixed commit (`job.workflow_sha`)
for all its scripts. To control upgrades, pin a commit SHA instead of `@main`.

## Inputs

| Input               | Default                             | Meaning                                                                                              |
| ------------------- | ----------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `pr-number`         | required                            | PR to review                                                                                         |
| `engine`            | required                            | Folder under `engines/` (`^[a-z0-9-]+$`), e.g. `kiro`                                               |
| `model`             | `""`                                | Model id; empty uses the account default                                                            |
| `prompt-file`       | `.github/ai-code-review/prompt.md`       | Review direction, read from the PR head. Required: a missing file fails the review                  |
| `instruction-files` | `.github/ai-code-review/instructions.md` | Newline-separated files, read from the PR head and joined in order. Missing ones are skipped with a warning; none gives "None." |
| `agent-file`        | `""`                                | Optional overlay on the engine's base agent, read from the PR head. Missing → warning, base only   |
| `exclude-paths`     | lockfiles, `dist`, maps, images     | Newline-separated globs left out of the diff. Setting it replaces the default list                  |
| `max-diff-bytes`    | `150000`                            | Larger diffs are truncated and the review says it is partial                                        |

Secret `ai-code-review-api-key` (optional). Outputs: `status` (`ok`, `empty`, `skipped`,
`failed`) and `credits`.

File inputs must be repository-relative paths (`[A-Za-z0-9._/-]`, no `..`);
anything else fails the review.

## Behaviour

- **Fork PRs are never reviewed.** The caller's `if:` skips them; the shared
  workflow also checks the PR's head repository (including for manual runs)
  and ends with a "from a fork; skipped" notice, with no checkout, engine run
  or comment.
- **No credential** (Dependabot, or secret not set): a "skipped" comment.
  Maintainers can run it manually from _Actions → Run workflow_ with the PR number.
- Only excluded files changed: "nothing to review".
- Errors or timeouts (15 min): a comment links to the run. The check stays green.

## Prompt

The prompt is assembled in this order:

1. [`prompt/header.md`](prompt/header.md) (shared): the reviewer's role and the sandbox.
2. The caller's `prompt-file`: what to review and how to judge.
3. `## Repository-specific guidance`: the caller's `instruction-files`.
4. [`prompt/footer.md`](prompt/footer.md) (shared): untrusted-content rules and the
   output format that `publish.sh` and the engine rely on.
5. The PR title, description, changed files and diff, inside a randomly named
   untrusted-content tag.

`{{REPOSITORY}}`, `{{REPO_DIR}}` and `{{HEAD_SHA}}` are replaced in parts 1–4.

## Security

The risk is a PR, for example via prompt injection, getting the reviewer to
leak a credential into the public comment, or to run code with one.

- **Trust model:** the prompt, instructions and agent overlay come from the PR
  head, so a PR's config changes apply to its own review. That's acceptable
  only because PRs from branches in the repository are written by developers
  with write access. Fork PRs are skipped at two levels (caller `if:` and
  `resolve-pr.sh`), and `pull_request_target` is refused.
- Scripts come from this workflow's own commit (`job.workflow_sha`), never
  from the PR.
- Config files are read with `git show <head>:<path>`, so a committed
  symlink is never followed into runner files.
- The shared header and footer (untrusted-content rules, output format) and
  the engine's sandbox can't be overridden by a project.
- Checkouts don't persist credentials. The API key is only in the review
  step, and the GitHub token is only in steps that run no agent.
- Output containing the key, or anything that looks like a credential, is
  withheld.

## Engines

An engine is `engines/<name>/run.sh` plus its own files. Adding one doesn't
change the orchestration.

- **Reads:** `AI_CODE_REVIEW_REPO_DIR` (read-only PR checkout),
  `$AI_CODE_REVIEW_WORK_DIR/prompt.md`, `AI_CODE_REVIEW_API_KEY`, `AI_CODE_REVIEW_MODEL`
  (optional), and `AI_CODE_REVIEW_AGENT_OVERLAY` (optional, the staged
  `agent-file` in the engine's own format).
- **Writes:** a non-empty `$AI_CODE_REVIEW_WORK_DIR/review.md` (the text inside
  `<review>` tags); may print `credits=<n>`; exits non-zero on failure.
- **Must:** ship its base agent/sandbox config in `engines/<name>/`, enforce
  the sandbox over any overlay, and run the agent read-only, isolated from
  the checkout's own agent config.

### Kiro engine

`engines/kiro/run.sh` installs a pinned kiro-cli into a private `KIRO_HOME`
and runs it from an empty directory, so a PR's own `.kiro/` agents, hooks and
MCP servers never load. The agent can only use `read`, `glob` and `grep`, with
`deniedPaths` covering `/proc`, `/etc`, home dotfiles, runner directories and
`.git`. Kiro's `allowedPaths` and `--trust-tools` do not restrict reads, so
they are not relied on.

- Secret: a Kiro API key
  ([docs](https://kiro.dev/docs/getting-started/authentication/#api-key-authentication-cli)),
  which needs a Kiro Pro or higher subscription. A ~20 KB diff costs 1–3
  credits; each comment shows its cost.
- **Agent overlay** (`agent-file`, see
  [`examples/java-code-reviewer.json`](examples/java-code-reviewer.json)) is merged onto
  [`engines/kiro/code-reviewer.json`](engines/kiro/code-reviewer.json):

  | Overlay key                                | Effect                                      |
  | ------------------------------------------ | ------------------------------------------- |
  | `prompt`                                   | Appended after the base prompt              |
  | `description`, `model`                     | Replace the base value                      |
  | `tools`, `allowedTools`                    | Narrow the base `read`/`glob`/`grep` only   |
  | `toolsSettings.{read,glob,grep}.deniedPaths` | Added to the base and runtime denied paths |
  | anything else (`hooks`, `mcpServers`, ...) | Ignored, with a warning                     |

  Invalid JSON, or JSON that isn't an object, fails the review.

#### Upgrading kiro-cli

`engines/kiro/run.sh` pins a kiro-cli release because the review depends on
Kiro's flags and event format. To upgrade, check the latest version, update
`kiro_version`, and run the tests:

```bash
curl -fsSL https://prod.download.cli.kiro.dev/stable/latest/manifest.json |
  jq -r '.version'
```

If Kiro's final event disappears, `run.sh` falls back to the standard Agent
Client Protocol message chunks and prints a warning.

## Testing

The "AI code review" steps in `.github/workflows/test.yaml` run ShellCheck and
`ai-code-review/test.sh` on every PR and push to `main`. The tests use throwaway git
repositories, a stub `gh`, fake engines and a fake kiro-cli, so no credits are
used. They need Bash, git, jq, tar, awk and iconv:

```bash
ai-code-review/test.sh
```

Cross-repository runs (the `job.workflow_*` checkout, secrets, comments) can
only be checked on a real PR in a calling repository.
