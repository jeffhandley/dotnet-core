---
name: API Diff
description: Generate or refresh a single .NET API diff pull request for a specific comparison.

permissions:
  contents: read
  issues: read
  pull-requests: read

runs-on: ubuntu-latest
timeout-minutes: 120

tools:
  github:
    min-integrity: approved

network:
  allowed:
    - defaults
    - github
    - dotnet

checkout:
  fetch: ["*"]
  fetch-depth: 0

if: github.event_name == 'workflow_dispatch' || !github.event.repository.fork

concurrency:
  group: api-diff-${{ inputs.previous_major_minor || 'inferred' }}-${{ inputs.previous_label || 'inferred' }}-${{ inputs.current_major_minor || 'inferred' }}-${{ inputs.current_label || 'inferred' }}
  cancel-in-progress: true

safe-outputs:
  noop:
    max: 1
    report-as-issue: false
  create-pull-request:
    title-prefix: "[API Diff] "
    labels: [automation]
    draft: true
    max: 1
    base-branch: main
    if-no-changes: ignore
    fallback-as-issue: false
    preserve-branch-name: true
    allowed-files:
      - release-notes/**/api-diff/**.md
      - release-notes/ApiDiffAssembliesToExclude.txt
      - release-notes/ApiDiffAttributesToExclude.txt
  push-to-pull-request-branch:
    target: "*"
    title-prefix: "[API Diff] "
    labels: [automation]
    max: 1
    if-no-changes: ignore
    allowed-files:
      - release-notes/**/api-diff/**.md
      - release-notes/ApiDiffAssembliesToExclude.txt
      - release-notes/ApiDiffAttributesToExclude.txt
  update-pull-request:
    target: "*"
    max: 1
    footer: false

on:
  workflow_dispatch:
    inputs:
      previous_major_minor:
        description: "The previous `major.minor` version (e.g. `11.0`). Do not include milestone label."
        required: false
        type: string
      previous_label:
        description: "The previous milestone label (e.g. `preview.1`, `rc.2`, `ga`)."
        required: false
        type: string
      current_major_minor:
        description: "The current `major.minor` version (e.g. `11.0`). Do not include milestone label."
        required: false
        type: string
      current_label:
        description: "The current milestone label (e.g. `preview.1`, `rc.2`, `ga`)."
        required: false
        type: string

  # ###############################################################
  # Override the COPILOT_GITHUB_TOKEN secret usage for the workflow
  # with a randomly-selected token from a pool of secrets.
  #
  # As soon as organization-level billing is offered for Agentic
  # Workflows, this stop-gap approach will be removed.
  #
  # See: /.github/actions/select-copilot-pat/README.md
  # ###############################################################
  steps:
    - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
      name: Checkout the select-copilot-pat action folder
      with:
        persist-credentials: false
        sparse-checkout: .github/actions/select-copilot-pat
        sparse-checkout-cone-mode: true
        fetch-depth: 1

    - id: select-copilot-pat
      name: Select Copilot token from pool
      uses: ./.github/actions/select-copilot-pat
      env:
        SECRET_0: ${{ secrets.COPILOT_PAT_0 }}
        SECRET_1: ${{ secrets.COPILOT_PAT_1 }}
        SECRET_2: ${{ secrets.COPILOT_PAT_2 }}
        SECRET_3: ${{ secrets.COPILOT_PAT_3 }}
        SECRET_4: ${{ secrets.COPILOT_PAT_4 }}
        SECRET_5: ${{ secrets.COPILOT_PAT_5 }}
        SECRET_6: ${{ secrets.COPILOT_PAT_6 }}
        SECRET_7: ${{ secrets.COPILOT_PAT_7 }}
        SECRET_8: ${{ secrets.COPILOT_PAT_8 }}
        SECRET_9: ${{ secrets.COPILOT_PAT_9 }}

jobs:
  pre-activation:
    outputs:
      copilot_pat_number: ${{ steps.select-copilot-pat.outputs.copilot_pat_number }}

engine:
  id: copilot
  env:
    # We cannot use line breaks in this expression as it leads to a syntax error in the compiled workflow
    # If none of the `COPILOT_PAT_#` secrets were selected, then the default COPILOT_GITHUB_TOKEN is used
    COPILOT_GITHUB_TOKEN: ${{ case(needs.pre_activation.outputs.copilot_pat_number == '0', secrets.COPILOT_PAT_0, needs.pre_activation.outputs.copilot_pat_number == '1', secrets.COPILOT_PAT_1, needs.pre_activation.outputs.copilot_pat_number == '2', secrets.COPILOT_PAT_2, needs.pre_activation.outputs.copilot_pat_number == '3', secrets.COPILOT_PAT_3, needs.pre_activation.outputs.copilot_pat_number == '4', secrets.COPILOT_PAT_4, needs.pre_activation.outputs.copilot_pat_number == '5', secrets.COPILOT_PAT_5, needs.pre_activation.outputs.copilot_pat_number == '6', secrets.COPILOT_PAT_6, needs.pre_activation.outputs.copilot_pat_number == '7', secrets.COPILOT_PAT_7, needs.pre_activation.outputs.copilot_pat_number == '8', secrets.COPILOT_PAT_8, needs.pre_activation.outputs.copilot_pat_number == '9', secrets.COPILOT_PAT_9, secrets.COPILOT_GITHUB_TOKEN) }}
---

# Produce one API diff PR

Use the local `release-notes/ApiDiff-Run.ps1` script directly to generate exactly one API diff comparison and then create or refresh the matching pull request. You may consult `@.github/skills/api-diff` only as a parameter-mapping reference, but do not route the main generation step through the skill wrapper.

## Operating rules

1. Keep the agent job read-only. Use the configured safe outputs for all PR creation, PR updates, and branch refreshes.
2. Only include generated API diff results and directly related release-notes changes in the PR.
3. If there are no file changes after generation, do not create a PR.
4. Use `main` as the pull request base branch.
5. Follow the style of `dotnet/core#10281`, `#10240`, `#10148`, `#10147`, `#10138`, and `#10063`, but standardize the PR title and keep the wording current.
6. DO NOT edit or alter any of the files produced by the API diff script while preparing or creating the pull request.
7. Keep every automation-created API diff pull request as a **draft**. Do not request reviewers and do not mark any PR ready for review; leave both actions to a human.
8. This worker handles **exactly one** comparison per run.
9. Always write a concise markdown run report describing the resolved comparison, what action was taken, and why.
10. Persist that report with a shell command that appends to `summary_file="${GITHUB_STEP_SUMMARY:-/tmp/gh-aw/agent-step-summary.md}"` so the summary still appears even if the GitHub-hosted variable is unavailable inside the agent sandbox.
11. If generation is blocked by missing outbound access to required package feeds or download hosts, say that plainly in the summary, invoke `noop` with the same explanation, and stop without attempting a pull request.
12. Never let a successful run finish without at least one safe output. If the run is not going to create a PR, update a PR, or push to a PR branch, it must explicitly invoke `noop` with a brief reason rather than exiting silently.

## Input behavior

- Treat the four `workflow_dispatch` inputs as an all-or-none set:
  - If all four inputs are empty, run `release-notes/ApiDiff-Run.ps1` with no version parameters so it infers the next milestone comparison automatically.
  - If any input is provided, require all four values together and use them to target the comparison explicitly.
- Input mapping:
  - `previous_major_minor` and `current_major_minor` are just the release line, such as `11.0` or `10.0`
  - `previous_label` and `current_label` identify the milestone on that line:
    - use `preview.N` for previews, such as `preview.2`
    - use `rc.N` for release candidates, such as `rc.1`
    - use `ga` for the general-availability release
- When translating those inputs to the underlying script behavior, treat `ga` as the GA case rather than as a numbered prerelease label.
- If a manual dispatch provides only some of the four inputs instead of all four together, invoke `noop` explaining that all four values are required for an explicit run, and stop.
- For the release-to-release automation comparison such as `previous ga -> current ga`, interpret the **current** side as "the latest API currently available on `dotnet-public` for that current release line", even while that release is still in preview or RC. This lets the release-to-current PR keep advancing from Preview 1 to Preview 2 to Preview 3 and so on while preserving the stable release-line title format.
- Do not ask for build numbers or full package versions.

## Generation steps

1. Resolve exactly one target comparison for this run.
   - Use the explicit inputs when they are supplied.
   - Otherwise let `release-notes/ApiDiff-Run.ps1` infer the next milestone comparison automatically by running it with no version parameters first.
2. Choose the feed strategy before generation:
   - For the release-to-release comparison such as `previous ga -> current ga`, stay on the default public behavior only and resolve the current side to the **latest version currently available on `dotnet-public`** for the current release line. Do **not** use any release-specific feed fallback for this case.
   - For the next preview-to-preview comparison on a major release line, try `dotnet-public` first.
   - Only if `dotnet-public` does not have the target preview version available yet, retry once using the release-specific feed `https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet{MAJOR}/nuget/v3/index.json`, where `{MAJOR}` is the major version number for the current release line.
   - Use that fallback only for the preview run that advances to the next preview milestone. Do not use it for the release-to-release run.
   - Make that fallback concrete:
     1. First run the comparison with the normal default behavior and no custom feed arguments.
     2. If the result shows that the target preview is not yet available on `dotnet-public`, rerun the same comparison exactly once with `-CurrentNuGetFeed "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet{MAJOR}/nuget/v3/index.json"`.
     3. Keep `-PreviousNuGetFeed` on its default public value unless the script explicitly indicates the previous side also cannot be resolved from `dotnet-public`.
   - If the initial no-argument inferred run fails specifically because the target preview is not yet on `dotnet-public`, infer the same comparison from the script output or the existing `release-notes/**/api-diff/` progression and rerun it explicitly with the same previous/current values plus the `CurrentNuGetFeed` override.
   - Use the concrete command shapes below and substitute the resolved values for this run:

     ```powershell
     pwsh -File ./release-notes/ApiDiff-Run.ps1
     ```

     ```powershell
     pwsh -File ./release-notes/ApiDiff-Run.ps1 `
       -PreviousMajorMinor {PREVIOUS_MAJOR_MINOR} `
       -CurrentMajorMinor {CURRENT_MAJOR_MINOR} `
       [-PreviousPrereleaseLabel {PREVIOUS_LABEL_IF_NOT_GA}] `
       [-CurrentPrereleaseLabel {CURRENT_LABEL_IF_NOT_GA}] `
       [-CurrentNuGetFeed "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet{MAJOR}/nuget/v3/index.json"] `
       [-InstallApiDiff]
     ```

   - Prefer direct script invocation over the skill wrapper even for explicit runs, because the script gives more deterministic behavior and clearer logs in GitHub Actions.
3. Invoke `release-notes/ApiDiff-Run.ps1` directly to generate that comparison using the selected feed behavior.
4. On GitHub-hosted runners, make sure the ApiDiff tool is installed or updated if the first run indicates that it is missing. Prefer re-running with `-InstallApiDiff` rather than failing the workflow.
5. Inspect the generated files to determine the before and after releases and confirm which `release-notes/**/api-diff/**` content changed for the target comparison.
6. Search for an existing **open** pull request in this repository that already has the `[API Diff]` title prefix, the `automation` label, and matches the same target comparison.
7. If the matching PR exists and is a **draft**, update its title or body as needed and use `push_to_pull_request_branch` to refresh the same branch instead of creating a second PR.
8. If the matching draft PR is already fully current and there is nothing to push or update, invoke `noop` with that explanation and stop instead of exiting silently.
9. If the matching PR exists and is **not** a draft, treat it as human-owned, invoke the `noop` tool with a brief explanation, and stop without changing it.
10. If no matching PR exists and this was an inferred no-input run, check whether the corresponding API diff is already present on `main`. If it is already present, invoke `noop` and stop.
11. If no matching PR exists and this was an explicit run, it is acceptable to regenerate that comparison even when the corresponding files already exist on `main`; only create a PR if the regenerated content actually differs.
12. If there are no file changes after generation, invoke `noop` and stop.
13. Otherwise create a new **draft** PR for that comparison.
14. As a final safety check, if you are about to end the run without calling `create_pull_request`, `update_pull_request`, or `push_to_pull_request_branch`, invoke `noop` first so the run always emits an intentional safe output.

## Step summary report

Before finishing, append a concise markdown report to `summary_file="${GITHUB_STEP_SUMMARY:-/tmp/gh-aw/agent-step-summary.md}"` that includes:

- the resolved previous/current comparison for this run
- whether the run used explicit inputs or inferred the next milestone
- whether generation stayed on `dotnet-public` or had to fall back to `dotnet{MAJOR}` for the next preview comparison
- whether it created a PR, refreshed an existing draft PR, skipped a non-draft PR, or no-op'd
- the explicit `noop` reason when no PR action was taken
- whether there were no file changes, the diff already existed on `main`, or generation was blocked by network/package access

## Pull request requirements

Maintain at most one open automation PR per target API diff comparison.

- The safe output already enforces the `[API Diff]` prefix. Provide the remainder of the title in one of these forms:
  - `.NET 11.0 Preview 2 -> Preview 3`
  - `.NET 10.0 -> .NET 11.0`
- Keep the release-to-release title in the stable release-line form `.NET 10.0 -> .NET 11.0` even when the underlying current-side package being compared is still the latest public preview or RC for `11.0`.
- The PR body should briefly summarize what comparison was generated and list the affected owners or contributors in a format similar to the historical API diff PRs.
- Restrict the patch to files matching these globs only:
  - `release-notes/**/api-diff/**.md`
  - `release-notes/ApiDiffAssembliesToExclude.txt`
  - `release-notes/ApiDiffAttributesToExclude.txt`
- Always create and update these PRs as drafts with no reviewers.
- Use stable, comparison-specific branch names so multiple in-flight API diff PRs do not interfere with each other.
  - Example milestone branch: `api-diff/net11-preview2_net11-preview3`
  - Example release-to-release branch: `api-diff/net10_net11`

## Usage

- **Dispatcher-triggered run:** leave all four inputs empty when the goal is to infer the next milestone comparison automatically.
- **Direct manual run:** provide all four inputs for the comparison you want to regenerate or update, for example `11.0` + `preview.2` -> `11.0` + `preview.3`, or `10.0` + `ga` -> `11.0` + `ga`.
