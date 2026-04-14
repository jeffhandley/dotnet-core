---
name: api-diff
description: Generate an API comparison report between two .NET versions using the RunApiDiff scripts. Invoke when the user asks to run, create, or generate an API diff.
disable-model-invocation: true
---

# API Diff Generation

Generate an API diff in two steps:

1. Run `release-notes/RunApiDiff-CollectAssemblies.ps1` to download reference assemblies and produce a JSON manifest
2. Run `release-notes/RunApiDiff-GenerateReport.ps1` with the manifest to generate markdown reports

See [release-notes/RunApiDiff.md](../../../release-notes/RunApiDiff.md) for the full parameter reference for the collection script.

When no versions are mentioned, run with no parameters — the script auto-infers versions.

## Mapping natural language to parameters

| User says | Parameters |
|---|---|
| "generate the next API diff" | *(none)* |
| ".NET 10 GA vs .NET 11 Preview 1" | `-PreviousMajorMinor 10.0 -CurrentMajorMinor 11.0 -CurrentPrereleaseLabel preview.1` |
| "net9.0-preview6 to net10.0-preview5" | `-PreviousMajorMinor 9.0 -PreviousPrereleaseLabel preview.6 -CurrentMajorMinor 10.0 -CurrentPrereleaseLabel preview.5` |
| ".NET 10 RC 2 vs .NET 10 GA" | `-PreviousMajorMinor 10.0 -PreviousPrereleaseLabel rc.2 -CurrentMajorMinor 10.0` |
| ".NET 10 vs .NET 11" (latest) | `-PreviousMajorMinor 10.0 -CurrentMajorMinor 11.0 -CurrentPrereleaseLabel *` |
| "10.0.0-preview.7.25380.108 to 10.0.0-rc.1.25451.107" | `-PreviousVersion "10.0.0-preview.7.25380.108" -CurrentVersion "10.0.0-rc.1.25451.107"` |

- **GA** or no qualifier → omit the PrereleaseLabel parameter
- **`*`** (latest / major-to-major) → pass `-PrereleaseLabel *` to find the latest version on dotnet-public
- **Preview N** / **previewN** → `-PrereleaseLabel preview.N`
- **RC N** / **rcN** → `-PrereleaseLabel rc.N`
- **netX.Y-previewN** (TFM format) → `-MajorMinor X.Y -PrereleaseLabel preview.N`
- Full NuGet version strings → use `-PreviousVersion` / `-CurrentVersion` directly
- The "previous" version is always the older version; "current" is the newer one

## Step 1: Collect assemblies

```powershell
pwsh -File ./release-notes/RunApiDiff-CollectAssemblies.ps1 [mapped parameters]
```

Set an initial wait of at least 300 seconds — the script takes several minutes. Capture the JSON output; it contains the assembly paths and metadata needed for step 2.

## Step 2: Generate reports

Save the JSON manifest from Step 1 to a temporary file, then run:

```bash
pwsh -File ./release-notes/RunApiDiff-GenerateReport.ps1 -InstallApiDiff -InputFile /tmp/api-diff-manifest.json
```

Set an initial wait of at least 300 seconds. The script installs the `apidiff` CLI tool, generates diff reports for each SDK, creates the summary README.md, and normalizes trailing newlines.

After completion, summarize the results: how many diff files were generated and where.
