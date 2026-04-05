# API Diff

The API diff tooling generates markdown reports comparing the public APIs between two .NET releases. These reports are published under `release-notes/{version}/preview/{milestone}/api-diff/` for each preview, RC, and GA release.

There are three ways to generate API diffs:

| Method | When to use |
|--------|-------------|
| [**Command-line script**](#command-line-usage) | Manual local generation using `ApiDiff.ps1` |
| [**Copilot skill**](#agentic-usage-with-copilot) | Interactive Copilot sessions using the `api-diff` skill with the apidiff MCP server |
| [**Agentic workflow**](#automated-workflow) | Scheduled and on-demand automation that keeps API diff PRs current |

Example output: [API diff between .NET 10 GA and .NET 11 Preview 1 (dotnet/core#10240)](https://github.com/dotnet/core/pull/10240/changes)

## Command-line usage

The `ApiDiff.ps1` script runs the full pipeline locally: it resolves versions, downloads NuGet reference packages, runs the `apidiff` console tool, and writes the markdown reports.

### Prerequisites

- PowerShell 7.0 or later
- The [Microsoft.DotNet.ApiDiff.Tool](https://dev.azure.com/dnceng/public/_artifacts/feed/dotnet-public) dotnet tool. Use `-InstallApiDiff` to have the script install it automatically, or install it manually from the transport feed:

```shell
dotnet tool install --global Microsoft.DotNet.ApiDiff.Tool \
  --source https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet{MAJOR}-transport/nuget/v3/index.json \
  --prerelease
```

### Quick start

When run with no arguments, the script infers the next version to diff by scanning existing `api-diff` folders in the repository.

```powershell
.\release-notes\ApiDiff.ps1
```

### Examples

```powershell
# Infer versions automatically
.\release-notes\ApiDiff.ps1

# Specify only the current version; previous is inferred
.\release-notes\ApiDiff.ps1 -CurrentMajorMinor 11.0 -CurrentPrereleaseLabel preview.2

# Specify both versions explicitly
.\release-notes\ApiDiff.ps1 `
   -PreviousMajorMinor 10.0 -PreviousPrereleaseLabel preview.7 `
   -CurrentMajorMinor 10.0 -CurrentPrereleaseLabel rc.1

# Use exact NuGet package versions
.\release-notes\ApiDiff.ps1 `
   -PreviousVersion "10.0.0-preview.7.25380.108" `
   -CurrentVersion "10.0.0-rc.1.25451.107"

# Use a custom feed for the current version's packages
.\release-notes\ApiDiff.ps1 `
   -CurrentNuGetFeed "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11/nuget/v3/index.json"
```

### Parameters

#### Version parameters

When no version information is provided, the script scans existing `api-diff` folders to find the latest version and infers the next one in the progression (preview.1 → preview.2 → … → rc.1 → rc.2 → GA → next major preview.1). When `PreviousVersion` or `CurrentVersion` is provided, `MajorMinor` and `PrereleaseLabel` are extracted automatically.

| Parameter | Description | Default |
|---|---|---|
| `PreviousVersion` | Exact package version for the "before" comparison (e.g., `10.0.0-preview.7.25380.108`). | *(inferred or searched)* |
| `CurrentVersion` | Exact package version for the "after" comparison (e.g., `10.0.0-rc.1.25451.107`). | *(inferred or searched)* |
| `PreviousMajorMinor` | The "before" .NET major.minor version (e.g., `10.0`). | Inferred or discovered |
| `PreviousPrereleaseLabel` | Prerelease label for "before" (e.g., `preview.7`, `rc.1`). Omit for GA. | Inferred or discovered |
| `CurrentMajorMinor` | The "after" .NET major.minor version (e.g., `10.0`). | Inferred or discovered |
| `CurrentPrereleaseLabel` | Prerelease label for "after" (e.g., `preview.7`, `rc.1`). Omit for GA. | Inferred or discovered |

#### Feed parameters

| Parameter | Description | Default |
|---|---|---|
| `CurrentNuGetFeed` | NuGet feed URL for downloading "after" packages | `dotnet-public` feed |
| `PreviousNuGetFeed` | NuGet feed URL for downloading "before" packages | `dotnet-public` feed |

#### Path parameters

| Parameter | Description | Default |
|---|---|---|
| `CoreRepo` | Path to your local clone of the dotnet/core repo | Git repo root relative to the script |
| `TmpFolder` | Working directory for downloaded and extracted packages | Auto-created temp directory |

#### Switches

| Parameter | Description |
|---|---|
| `ExcludeNetCore` | Skip the Microsoft.NETCore.App comparison |
| `ExcludeAspNetCore` | Skip the Microsoft.AspNetCore.App comparison |
| `ExcludeWindowsDesktop` | Skip the Microsoft.WindowsDesktop.App comparison |
| `InstallApiDiff` | Install or update the ApiDiff tool from the transport feed |

### Script architecture

`ApiDiff.ps1` is a composition of two sub-scripts that can also be run independently:

| Script | Purpose |
|--------|---------|
| `ApiDiff-CollectAssemblies.ps1` | Resolves versions, downloads NuGet packages, extracts reference assemblies, and emits a JSON manifest to stdout |
| `ApiDiff-GenerateReport.ps1` | Reads the JSON manifest and invokes the `apidiff` console tool to produce markdown reports |

Running the steps individually:

```powershell
# Step 1: Collect assemblies — outputs JSON manifest
.\release-notes\ApiDiff-CollectAssemblies.ps1 -CurrentMajorMinor 11.0 -CurrentPrereleaseLabel preview.3 > manifest.json

# Step 2: Generate reports from the manifest
.\release-notes\ApiDiff-GenerateReport.ps1 -InputFile manifest.json -InstallApiDiff
```

## Agentic usage with Copilot

When working with Copilot in an environment that has the **apidiff MCP server** available, the `api-diff` skill uses a two-step approach:

1. **Collect assemblies** — `ApiDiff-CollectAssemblies.ps1` downloads reference packages and produces a JSON manifest
2. **Generate reports via MCP** — the `generate_api_diff` MCP tool processes each SDK using assembly paths from the manifest

This avoids the need to install the `apidiff` dotnet tool locally. The MCP server includes built-in `release-notes` exclusion sets that match the `ApiDiffAssembliesToExclude.txt` and `ApiDiffAttributesToExclude.txt` files.

### MCP server

The apidiff MCP server is available as the `Microsoft.DotNet.ApiDiff.Mcp` NuGet package on the same transport feed as the dotnet tool:

```text
https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet{MAJOR}-transport/nuget/v3/index.json
```

## Automated workflow

The [API Diff agentic workflow](./../.github/workflows/api-diff.md) automates API diff generation on a schedule and via manual dispatch. It keeps draft pull requests current for each preview-to-preview comparison and for each major release-to-release comparison, creating and refreshing PRs as new previews become available on the public NuGet feed.
