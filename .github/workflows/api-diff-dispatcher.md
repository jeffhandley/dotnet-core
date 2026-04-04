---
name: API Diff Dispatcher
description: Orchestrate the scheduled API diff worker runs that refresh draft PRs and start new comparisons.

permissions:
  contents: read
  issues: read
  pull-requests: read

runs-on: ubuntu-latest
timeout-minutes: 30

tools:
  github:
    min-integrity: approved

concurrency:
  group: api-diff-dispatcher
  cancel-in-progress: true

safe-outputs:
  noop:
    max: 1
    report-as-issue: false
  dispatch-workflow:
    workflows: [api-diff]
    max: 4

on:
  schedule:
    - cron: weekly on wednesday around 8am
      timezone: America/Los_Angeles

  workflow_dispatch:

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

# Dispatch API Diff worker runs

Use the generated `api_diff` workflow-dispatch tool to fan out `api-diff` worker runs for the comparisons that should be refreshed or started.

## Operating rules

1. This dispatcher never edits files and never creates or updates pull requests directly.
2. Use the generated `api_diff` tool for worker dispatches and `noop` only when there is truly nothing to dispatch.
3. Avoid duplicate dispatches for the same previous/current pair within a single dispatcher run.
4. Treat any open non-draft API diff PR as human-owned and do not dispatch refreshes for that same comparison.
5. Always write a concise markdown report describing what you found, which worker runs you dispatched, which PRs you intentionally skipped, and why.
6. Persist that report with a shell command that appends to `summary_file="${GITHUB_STEP_SUMMARY:-/tmp/gh-aw/agent-step-summary.md}"` so the summary still appears even if the GitHub-hosted variable is unavailable inside the agent sandbox.
7. If you invoke `noop`, include the same explanation in that same summary report as well.

## Schedule and manual behavior

- This workflow runs every Wednesday in `America/Los_Angeles`.
- A manual `workflow_dispatch` run performs the same reconciliation steps as the scheduled run.

## Dispatch steps

1. Search for existing **open** pull requests in this repository that already have the `[API Diff]` title prefix and the `automation` label.
2. Separate those PRs into:
   - **draft** PRs, which automation should continue refreshing
   - **non-draft** PRs, which automation should now ignore
3. For each open **draft** PR, recover its previous/current pair from the PR title, body, branch name, or changed files.
   - Parse titles and branch names **case-insensitively**.
   - Be forgiving about milestone formatting:
     - treat `Preview 2`, `preview 2`, `preview2`, and `PREVIEW.2` as `preview.2`
     - treat `RC 1`, `rc 1`, `rc1`, and `RC.1` as `rc.1`
   - Be forgiving about release line formatting:
     - treat `.NET 11`, `.NET 11.0`, `net11`, and `net11.0` as the same `11.0`
     - if the right-hand side omits the major/minor, as in `.NET 11.0 Preview 2 -> Preview 3`, assume it stays on the same release line unless there is clear evidence otherwise
   - For titles like `.NET 11.0 Preview 2 -> Preview 3`, dispatch `api_diff` with `previous_major_minor=11.0`, `previous_label=preview.2`, `current_major_minor=11.0`, and `current_label=preview.3`.
   - For titles like `.NET 10.0 -> .NET 11.0`, dispatch `api_diff` with `previous_major_minor=10.0`, `previous_label=ga`, `current_major_minor=11.0`, and `current_label=ga`.
4. If a draft PR's pair cannot be recovered confidently, skip that one rather than guessing.
5. Ensure there is an open GA-to-GA PR in flight for the active major release train, counting either draft or non-draft PRs.
   - If no such PR exists, dispatch `api_diff` once for the next GA-to-GA comparison, such as `10.0` + `ga` -> `11.0` + `ga`.
   - If the resulting worker run determines there is nothing new to change, it may legitimately noop without creating a PR or issue.
6. Always dispatch `api_diff` once **with no inputs** so the worker can infer whether the next milestone-to-milestone comparison should now be started or refreshed.
7. If a comparison already has an open non-draft PR, do not dispatch another worker run for that same pair.
8. If there is truly nothing to dispatch after applying the rules above, invoke `noop` with a brief explanation.

## Step summary report

Before finishing, append a markdown report to `summary_file="${GITHUB_STEP_SUMMARY:-/tmp/gh-aw/agent-step-summary.md}"` that includes:

- the open draft PRs that were recognized and whether each one was dispatched or skipped
- the open non-draft PRs that were intentionally ignored
- whether a GA-to-GA PR was already present or had a worker run dispatched
- whether the no-input "find the next milestone" worker run was dispatched
- any comparisons that could not be parsed confidently
- the exact brief explanation passed to `noop`, when `noop` is used

Keep the report concise, readable, and action-oriented so a human can quickly understand what the dispatcher decided.

## Usage

- **Scheduled or manual dispatcher run:** the workflow automatically refreshes known draft API diff PRs, leaves non-drafts alone, ensures a GA-to-GA comparison is represented, and kicks off one no-input worker run to discover the next milestone.
