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

checkout:
  fetch: ["*"]
  fetch-depth: 0

concurrency:
  group: api-diff-${{ inputs.previous_major_minor || 'inferred' }}-${{ inputs.previous_label || 'inferred' }}-${{ inputs.current_major_minor || 'inferred' }}-${{ inputs.current_label || 'inferred' }}
  cancel-in-progress: true

steps:
  - name: Generate API diff
    env:
      INPUT_PREV_MM: ${{ inputs.previous_major_minor }}
      INPUT_PREV_LABEL: ${{ inputs.previous_label }}
      INPUT_CURR_MM: ${{ inputs.current_major_minor }}
      INPUT_CURR_LABEL: ${{ inputs.current_label }}
    shell: bash
    run: |
      mkdir -p /tmp/gh-aw/agent

      PARAMS=(-InstallApiDiff -OutputFormat json -OutputFile /tmp/gh-aw/agent/metadata.json)

      # Build feed probe order: dotnet-public first, then dotnet{MAJOR} for fallback
      FEEDS="dotnet-public"
      MAJOR="${INPUT_CURR_MM%%.*}"
      [ -n "$MAJOR" ] && FEEDS="dotnet-public,dotnet${MAJOR}"
      # Only pass -NuGetFeeds when we know the major version; otherwise let the script infer it
      [ -n "$MAJOR" ] && PARAMS+=(-NuGetFeeds "$FEEDS")

      [ -n "$INPUT_PREV_MM" ] && PARAMS+=(-PreviousMajorMinor "$INPUT_PREV_MM")
      [ -n "$INPUT_PREV_LABEL" ] && PARAMS+=(-PreviousPrereleaseLabel "$INPUT_PREV_LABEL")
      [ -n "$INPUT_CURR_MM" ] && PARAMS+=(-CurrentMajorMinor "$INPUT_CURR_MM")
      [ -n "$INPUT_CURR_LABEL" ] && PARAMS+=(-CurrentPrereleaseLabel "$INPUT_CURR_LABEL")

      pwsh -File ./release-notes/RunApiDiff.ps1 "${PARAMS[@]}" || true

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

# Create or refresh an API diff PR from pre-generated results

The API diff files have already been generated by `RunApiDiff.ps1` in a step that ran before this agent started. The generated files are in the workspace and metadata is at `/tmp/gh-aw/agent/metadata.json`. Your job is to inspect the results and create or update the appropriate pull request using safe outputs.

**Do not run `RunApiDiff.ps1` or any generation script.** The generation is complete.

## Step 1 — Read metadata and assess results

1. Read `/tmp/gh-aw/agent/metadata.json`. It contains:
   - `status`: `"success"` or `"failed"`
   - `reason`: explanation when status is `"failed"`
   - `previous` / `current`: human-friendly version descriptions (e.g. `.NET 11.0 Preview 2`)
   - `is_release_to_release`: whether this is a GA-to-GA cross-major comparison
   - `ref_packs`: array of per-ref-pack resolution details, each with `ref_pack`, `previous_version`, `previous_feed`, `current_version`, `current_feed`
   - `branch_name`: suggested branch name (e.g. `api-diff/net11-preview2_net11-preview3`)
   - `pr_title`: suggested PR title suffix (e.g. `.NET 11.0 Preview 2 -> .NET 11.0 Preview 3`)

2. If metadata doesn't exist or `status` is `"failed"`, invoke `noop` with the `reason` from metadata (or "metadata.json not found"), write the step summary, and stop.

## Step 2 — Check for file changes

1. Run `git status --porcelain` to check if any files were generated or modified.
2. If there are no changes, invoke `noop` with "No file changes after API diff generation" and stop.
3. Verify the changes are restricted to the allowed paths:
   - `release-notes/**/api-diff/**.md`
   - `release-notes/ApiDiffAssembliesToExclude.txt`
   - `release-notes/ApiDiffAttributesToExclude.txt`

## Step 3 — Check for existing PRs

1. Search for existing **open** pull requests in this repository with the `[API Diff]` title prefix and `automation` label.
2. Match by **branch name** first (most reliable), then by title/comparison if branch name is not available.
3. Categorize the matching PR:
   - **Draft PR found**: proceed to update it (step 4a)
   - **Non-draft PR found**: invoke `noop` with "Matching non-draft PR exists (human-owned)" and stop
   - **No matching PR found**: proceed to create one (step 4b)

## Step 4a — Update existing draft PR

1. Use `push_to_pull_request_branch` to refresh the branch with the new generated files.
2. Use `update_pull_request` if the title or body needs updating.
3. Use the branch name from metadata, or from the existing PR.

## Step 4b — Create new PR

1. For inferred runs where `branch_name` or `pr_title` are empty in metadata, derive them from the generated file paths:
   - Look at `release-notes/**/api-diff/` paths to determine the comparison
   - Branch: `api-diff/{prev_segment}_{curr_segment}` (e.g. `api-diff/net11-preview2_net11-preview3` or `api-diff/net10_net11`)
   - Title: `.NET 11.0 Preview 2 -> Preview 3` or `.NET 10.0 -> .NET 11.0`
2. For explicit runs, use the `branch_name` and `pr_title` from metadata.
3. For release-to-release comparisons (`is_release_to_release` is true), always use the stable release-line title format (e.g. `.NET 10.0 -> .NET 11.0`) even if the actual current-side version is a preview.
4. Create a new **draft** PR using `create_pull_request` with:
   - Title: the computed title (safe output adds the `[API Diff]` prefix)
   - Branch: the computed branch name
   - Body: include a **ref pack source table** from `ref_packs` in the metadata, formatted as:
     ```
     | Ref Pack | Previous Version | Feed | Current Version | Feed |
     |----------|-----------------|------|-----------------|------|
     | Microsoft.NETCore.App.Ref | 11.0.0-preview.3.xxx | dotnet-public | 11.0.0-preview.4.xxx | dotnet11 |
     ```
     This table must be present and visible (not buried in prose). Also include a brief summary of the comparison and SDKs compared.
5. Do NOT request reviewers or mark the PR ready for review.

## Step 5 — Step summary

Append a concise markdown report to `summary_file="${GITHUB_STEP_SUMMARY:-/tmp/gh-aw/agent-step-summary.md}"`:

- The resolved previous/current comparison
- Whether the run used explicit inputs or inferred the comparison
- The ref pack feed source table (from `ref_packs` in metadata)
- Whether it created a PR, refreshed an existing draft PR, skipped a non-draft PR, or no-op'd
- The `noop` reason when no PR action was taken

## Operating rules

1. **Do not run any generation scripts.** The API diff generation happened before you started.
2. **Do not edit generated files.** Use them exactly as produced.
3. Keep the agent job read-only. Use safe outputs for all PR operations.
4. Every run must emit at least one safe output — either a PR action or an explicit `noop`.
5. Keep PRs as **drafts** with no reviewers.
6. Use `main` as the PR base branch.
