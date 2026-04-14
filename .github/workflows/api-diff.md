---
name: API Diff
description: Generate or refresh a single .NET API diff pull request for a specific comparison.

# Security
permissions:
  contents: read
  issues: read
  pull-requests: read

tools:
  github:
    min-integrity: approved
  timeout: 900

runtimes:
  dotnet:
    version: "10.0"

mcp-servers:
  apidiff:
    container: "mcr.microsoft.com/dotnet/runtime:10.0"
    args: ["-v", "/opt/apidiff-mcp:/opt/apidiff-mcp:ro", "--entrypoint", "dotnet"]
    entrypointArgs: ["exec", "/opt/apidiff-mcp/Microsoft.DotNet.ApiDiff.McpServer.dll"]
    allowed: ["generate_api_diff"]

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
    max: 2
    footer: false

# Orchestration
if: github.event_name == 'workflow_dispatch' || !github.event.repository.fork

concurrency:
  group: api-diff-${{ inputs.previous_major_minor || 'inferred' }}-${{ inputs.previous_label || 'inferred' }}-${{ inputs.current_major_minor || 'inferred' }}-${{ inputs.current_label || 'inferred' }}
  cancel-in-progress: true

timeout-minutes: 120

# Runner
runs-on: ubuntu-latest

# Network
network:
  allowed:
    - defaults
    - github
    - dotnet

checkout:
  fetch: ["*"]
  fetch-depth: 0

# [NO-MERGE] Build and install the apidiff MCP server from source
# until the package is published to the transport feed.
steps:
  - name: Build apidiff MCP server from source
    run: |
      git clone --depth 1 --branch jeffhandley/apidiff-mcpserver \
        https://github.com/jeffhandley/sdk.git /tmp/apidiff-mcp-src
      cd /tmp/apidiff-mcp-src
      ./build.sh -c Release \
        --projects "$PWD/src/Compatibility/ApiDiff/Microsoft.DotNet.ApiDiff.McpServer/Microsoft.DotNet.ApiDiff.McpServer.csproj"
      APIDIFF_BIN="$(find artifacts/bin/Microsoft.DotNet.ApiDiff.McpServer/Release -name 'Microsoft.DotNet.ApiDiff.McpServer.dll' | head -1)"
      APIDIFF_DIR="$(dirname "$APIDIFF_BIN")"
      sudo mkdir -p /opt/apidiff-mcp
      sudo cp -r "$APIDIFF_DIR"/* /opt/apidiff-mcp/
      echo "apidiff MCP server installed to /opt/apidiff-mcp"
      ls -la /opt/apidiff-mcp/Microsoft.DotNet.ApiDiff.McpServer.dll

# Triggers
on:
  workflow_dispatch:
    inputs:
      previous_major_minor:
        description: "The previous `major.minor` version (e.g. `11.0`). Do not include milestone label."
        required: false
        type: string
      previous_label:
        description: "The previous milestone label (e.g. `preview.1`, `rc.2`, `ga`, `*`). Use `*` for latest on dotnet-public."
        required: false
        type: string
      current_major_minor:
        description: "The current `major.minor` version (e.g. `11.0`). Do not include milestone label."
        required: false
        type: string
      current_label:
        description: "The current milestone label (e.g. `preview.1`, `rc.2`, `ga`, `*`). Use `*` for latest on dotnet-public."
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

    - name: Summarize comparison versions
      env:
        PREV_MAJOR_MINOR: ${{ inputs.previous_major_minor }}
        PREV_LABEL: ${{ inputs.previous_label }}
        CURR_MAJOR_MINOR: ${{ inputs.current_major_minor }}
        CURR_LABEL: ${{ inputs.current_label }}
      shell: bash
      run: |
        echo "## API Diff Comparison" >> "$GITHUB_STEP_SUMMARY"
        if [ -n "$PREV_MAJOR_MINOR" ] && [ -n "$PREV_LABEL" ] && [ -n "$CURR_MAJOR_MINOR" ] && [ -n "$CURR_LABEL" ]; then
          echo "| | Version | Label |" >> "$GITHUB_STEP_SUMMARY"
          echo "|---|---|---|" >> "$GITHUB_STEP_SUMMARY"
          echo "| **Before** | $PREV_MAJOR_MINOR | $PREV_LABEL |" >> "$GITHUB_STEP_SUMMARY"
          echo "| **After** | $CURR_MAJOR_MINOR | $CURR_LABEL |" >> "$GITHUB_STEP_SUMMARY"
        else
          echo "No explicit inputs provided — the agent will infer the next milestone comparison automatically." >> "$GITHUB_STEP_SUMMARY"
        fi

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
    # Surface workflow_dispatch inputs as environment variables so the agent can read them
    API_DIFF_PREVIOUS_MAJOR_MINOR: ${{ inputs.previous_major_minor }}
    API_DIFF_PREVIOUS_LABEL: ${{ inputs.previous_label }}
    API_DIFF_CURRENT_MAJOR_MINOR: ${{ inputs.current_major_minor }}
    API_DIFF_CURRENT_LABEL: ${{ inputs.current_label }}
---

# Produce one API diff PR

Use `release-notes/RunApiDiff-CollectAssemblies.ps1` to collect reference assemblies and then call the `generate_api_diff` MCP tool to generate exactly one API diff comparison. Create or refresh the matching pull request using the configured safe outputs. You may consult `@.github/skills/api-diff` as a reference for parameter mapping.

## Operating rules

1. Keep the agent job read-only. Use the configured safe outputs for all PR creation, PR updates, and branch refreshes.
2. The pull request must contain **only** the files generated by the `generate_api_diff` MCP tool. No other file changes — regardless of location — may be included.
3. If there are no file changes after generation, do not create a PR.
4. **NEVER modify, create, edit, or delete any file that was not produced by the `generate_api_diff` MCP tool.** Any changes outside the tool's output are strictly prohibited.
5. Use `main` as the pull request base branch.
6. Follow the style of `dotnet/core#10281`, `#10240`, `#10148`, `#10147`, `#10138`, and `#10063`, but standardize the PR title and keep the wording current.
7. DO NOT edit or alter any of the files produced by the `generate_api_diff` MCP tool while preparing or creating the pull request.
8. Keep every automation-created API diff pull request as a **draft**. Do not request reviewers and do not mark any PR ready for review; leave both actions to a human.
9. This worker handles **exactly one** comparison per run.
10. Always write a concise markdown run report describing the resolved comparison, what action was taken, and why.
11. Persist that report with a shell command that appends to `summary_file="${GITHUB_STEP_SUMMARY:-/tmp/gh-aw/agent-step-summary.md}"` so the summary still appears even if the GitHub-hosted variable is unavailable inside the agent sandbox.
12. If generation is blocked by missing outbound access to required package feeds or download hosts, say that plainly in the summary, invoke `noop` with the same explanation, and stop without attempting a pull request.
13. Never let a successful run finish without at least one safe output. If the run is not going to create a PR, update a PR, or push to a PR branch, it must explicitly invoke `noop` with a brief reason rather than exiting silently.

## Input behavior

- Read the four comparison parameters from environment variables — these are populated from the `workflow_dispatch` inputs. Run `printenv | grep API_DIFF_` in a shell to read them:
  - `API_DIFF_PREVIOUS_MAJOR_MINOR` — the previous `major.minor` version
  - `API_DIFF_PREVIOUS_LABEL` — the previous milestone label
  - `API_DIFF_CURRENT_MAJOR_MINOR` — the current `major.minor` version
  - `API_DIFF_CURRENT_LABEL` — the current milestone label
- Treat the four values as an all-or-none set:
  - If all four are empty, the script infers the next milestone comparison automatically.
  - If any value is provided, require all four values together.
- Input mapping:
  - `API_DIFF_PREVIOUS_MAJOR_MINOR` and `API_DIFF_CURRENT_MAJOR_MINOR` are just the release line, such as `11.0` or `10.0`
  - `API_DIFF_PREVIOUS_LABEL` and `API_DIFF_CURRENT_LABEL` identify the milestone on that line:
    - use `preview.N` for previews, such as `preview.2`
    - use `rc.N` for release candidates, such as `rc.1`
    - use `ga` for the general-availability release
    - use `*` for the latest version available on dotnet-public (prefers stable, falls back to latest prerelease)
- When translating inputs to script parameters, treat `ga` as the GA case — omit the PrereleaseLabel parameter.
- When translating inputs to script parameters, pass `*` directly as the PrereleaseLabel parameter value.
- Do not ask for build numbers or full package versions.

## Generation steps

**Important:** Do not manually query or interpret NuGet feed contents. The `RunApiDiff-CollectAssemblies.ps1` script handles all version resolution, feed querying, and package downloading. Trust its output. Daily NuGet feeds contain many build versions (alpha, preview, rc) — do not attempt to analyze feed listings yourself.

### Step 1 — Read and validate inputs

- Run `printenv | grep API_DIFF_` to read the four input environment variables.
- If some but not all four values are provided, invoke `noop` explaining that all four values are required for an explicit run, and stop.

### Step 2 — Collect assemblies

Run `release-notes/RunApiDiff-CollectAssemblies.ps1` to resolve versions, download reference packages, and produce a JSON manifest on stdout.

- **When all four inputs are empty (inferred run):** run with no version parameters.
- **When all four inputs are provided (explicit run):** map the `API_DIFF_*` environment variable values to script parameters.
- **GA inputs:** treat `ga` as the GA case — omit the prerelease label parameter.
- **Wildcard inputs:** pass `*` directly as `-PreviousPrereleaseLabel *` or `-CurrentPrereleaseLabel *`. The script resolves the latest available version.
- **Major-to-major comparison** (canonical: `previous ga -> current *`; also valid: `previous * -> current *`): run with default feeds only. Do not use the daily feed fallback for this case.

Command shapes:

```powershell
# Inferred — no version parameters
pwsh -File ./release-notes/RunApiDiff-CollectAssemblies.ps1

# Explicit — with mapped inputs
pwsh -File ./release-notes/RunApiDiff-CollectAssemblies.ps1 `
  -PreviousMajorMinor {PREVIOUS_MAJOR_MINOR} `
  -CurrentMajorMinor {CURRENT_MAJOR_MINOR} `
  [-PreviousPrereleaseLabel {PREVIOUS_LABEL_IF_NOT_GA}] `
  [-CurrentPrereleaseLabel {CURRENT_LABEL_IF_NOT_GA}]

# Major-to-major with ga previous and * current (latest on dotnet-public)
pwsh -File ./release-notes/RunApiDiff-CollectAssemblies.ps1 `
  -PreviousMajorMinor {PREVIOUS_MAJOR_MINOR} `
  -CurrentMajorMinor {CURRENT_MAJOR_MINOR} `
  -CurrentPrereleaseLabel *
```

Set an initial wait of at least 300 seconds — the script takes several minutes to download and extract packages.

**Feed fallback for preview-to-preview runs:** if the script fails because the target preview is not yet available on `dotnet-public`, retry exactly once with the daily feed override. The feed URL pattern is `https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet{MAJOR}/nuget/v3/index.json` where `{MAJOR}` is the major version number of the current release line. Add `-CurrentNuGetFeed` to the same command:

```powershell
pwsh -File ./release-notes/RunApiDiff-CollectAssemblies.ps1 `
  -PreviousMajorMinor {PREVIOUS_MAJOR_MINOR} `
  -CurrentMajorMinor {CURRENT_MAJOR_MINOR} `
  [-PreviousPrereleaseLabel {PREVIOUS_LABEL_IF_NOT_GA}] `
  [-CurrentPrereleaseLabel {CURRENT_LABEL_IF_NOT_GA}] `
  -CurrentNuGetFeed "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet{MAJOR}/nuget/v3/index.json"
```

### Step 3 — Generate API diff reports

Parse the JSON manifest from the script output. The manifest contains:

- `beforeLabel` / `afterLabel` — friendly version names
- `tableOfContentsTitle` — filename prefix for per-assembly reports
- `outputPath` — absolute path to the api-diff output directory
- `sdks` — array of SDK entries, each with `name`, `beforePath`, `afterPath`, and optional `refBeforePath` / `refAfterPath`

For each SDK entry in the manifest's `sdks` array, call the `generate_api_diff` MCP tool with:

- `beforePath` and `afterPath` from the SDK entry
- `beforeLabel` and `afterLabel` from the manifest root
- `refBeforePath` and `refAfterPath` from the SDK entry (omit when null)
- `outputPath` set to `{manifest.outputPath}/Microsoft.{sdk.name}.App`
- `tableOfContentsTitle` from the manifest root
- `assemblyExclusionSets`: `["release-notes"]`
- `attributeExclusionSets`: `["release-notes"]`

### Step 4 — Create README

Create the summary `README.md` in the manifest's `outputPath` directory:

```markdown
# {afterLabel} API Changes

The following API changes were made in {afterLabel}:

- [Microsoft.{sdk.name}.App](./Microsoft.{sdk.name}.App/{tableOfContentsTitle}.md)
```

Include one bullet per SDK entry in the manifest.

### Step 5 — Create or refresh the pull request

1. Inspect the generated files to confirm which `release-notes/**/api-diff/**` content changed.
2. Reset the comparison branch to current `main` before staging the generated files:
   ```bash
   git checkout main
   git checkout -B api-diff/<previous-version>_<current-version>
   ```
   Using `-B` (uppercase) ensures the branch is always created fresh from the current `main`, even if a local or remote branch with that name already exists. This prevents stale files from a previous run from appearing in the patch.
3. Stage **only** the files generated by the `generate_api_diff` MCP tool and commit them. Do not use `git add .` or `git add -A` — only add the specific api-diff output directory. No other files may be staged or committed:
   ```bash
   git add release-notes/<major.minor>/preview/preview<N>/api-diff/
   git commit -m "Generate API diff: .NET <previous> -> <current>"
   ```
4. Search for an existing **open** pull request with the `[API Diff]` title prefix and `automation` label matching this comparison.
5. If the matching PR is a **draft**, use `push_to_pull_request_branch` to refresh it.
6. If the matching draft PR is already current with nothing to push, still reconcile PR metadata — update the PR body with the current resolved version using `update_pull_request`, then invoke `noop`.
7. If the matching PR is **not** a draft, treat it as human-owned, invoke `noop`, and stop.
8. If no matching PR exists and this was an inferred run, check whether the API diff is already on `main`. If so, invoke `noop` and stop.
9. If no matching PR exists and this was an explicit run, create a PR only if the content differs from `main`.
10. If there are no file changes after generation, invoke `noop` and stop.
11. Otherwise create a new **draft** PR.
12. Final safety check: if the run will end without any safe output (`create_pull_request`, `update_pull_request`, `push_to_pull_request_branch`), invoke `noop` first.

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
- Keep the major-to-major title in the stable release-line form `.NET 10.0 -> .NET 11.0` even when the underlying current-side package being compared is still a preview or RC for `11.0`.
- For major-to-major PRs, the PR description must clearly separate the requested comparison from the resolved version:
  - **Requested comparison:** `.NET 10.0 GA -> .NET 11.0 (latest on dotnet-public)`
  - **Resolved current version:** the specific version from the manifest's `afterLabel` (e.g., `.NET 11.0 Preview 3` or `.NET 11.0 RC 2`)
  - **Feed used:** whether the current-side version was resolved from `dotnet-public` or a daily build feed
  - Do not embed the resolved version in a way that could be confused with the canonical comparison pair.
- The PR body should briefly summarize what comparison was generated and list the affected owners or contributors in a format similar to the historical API diff PRs.
- Restrict the patch to files matching these globs only:
  - `release-notes/**/api-diff/**.md`
  - `release-notes/ApiDiffAssembliesToExclude.txt`
  - `release-notes/ApiDiffAttributesToExclude.txt`
- Always create and update these PRs as drafts with no reviewers.
- Use stable, comparison-specific branch names so multiple in-flight API diff PRs do not interfere with each other.
  - Example milestone branch: `api-diff/net11-preview2_net11-preview3`
  - Example major-to-major branch: `api-diff/net10_net11`

## Usage

- **Dispatcher-triggered run:** leave all four inputs empty when the goal is to infer the next milestone comparison automatically.
- **Direct manual run:** provide all four inputs for the comparison you want to regenerate or update, for example `11.0` + `preview.2` -> `11.0` + `preview.3`, or `10.0` + `ga` -> `11.0` + `*`.
- **Major-to-major with GA previous and latest current:** use `ga` as the previous label and `*` as the current label to compare the previous GA release against the latest available current-side package, for example `10.0` + `ga` -> `11.0` + `*`. The script prefers stable versions for the current side but falls back to the latest prerelease when GA has not yet shipped.
