# Generates an API comparison report between two .NET versions by collecting
# reference assemblies and then running the apidiff tool.
#
# This is a composition of ApiDiff-CollectAssemblies.ps1 (version resolution,
# NuGet package download, assembly extraction) and ApiDiff-GenerateReport.ps1
# (apidiff tool invocation and README creation).
#
# All parameters are forwarded to the sub-scripts as appropriate.

# Prerequisites:
# - PowerShell 7.0 or later
# - The Microsoft.DotNet.ApiDiff.Tool. Use -InstallApiDiff to have the script
#   install it automatically, or install it manually.

# Usage:

# ApiDiff.ps1
# -PreviousMajorMinor           : The 'before' .NET version: '6.0', '7.0', '8.0', etc.
# -PreviousPrereleaseLabel      : The prerelease label for the 'before' version (e.g., "preview.7", "rc.1"). Omit for GA.
# -CurrentMajorMinor            : The 'after' .NET version: '6.0', '7.0', '8.0', etc.
# -CurrentPrereleaseLabel       : The prerelease label for the 'after' version (e.g., "preview.7", "rc.1"). Omit for GA.
# -CoreRepo                     : The full path to your local clone of the dotnet/core repo.
# -TmpFolder                    : The full path to the folder where the assets will be downloaded, extracted and compared.
# -AttributesToExcludeFilePath  : The full path to the file containing the attributes to exclude from the report.
# -AssembliesToExcludeFilePath  : The full path to the file containing the assemblies to exclude from the report.
# -PreviousNuGetFeed            : The NuGet feed URL to use for downloading previous/before packages.
# -CurrentNuGetFeed             : The NuGet feed URL to use for downloading current/after packages.
# -ExcludeNetCore               : Switch to exclude the NETCore comparison.
# -ExcludeAspNetCore            : Switch to exclude the AspNetCore comparison.
# -ExcludeWindowsDesktop        : Switch to exclude the WindowsDesktop comparison.
# -InstallApiDiff               : Switch to install or update the ApiDiff tool from the current transport feed.
# -PreviousVersion              : Optional exact package version for the previous/before comparison.
# -CurrentVersion               : Optional exact package version for the current/after comparison.

# Example — simplest usage (infers next version from existing api-diffs):
# .\ApiDiff.ps1

# Example — explicit current version:
# .\ApiDiff.ps1 -CurrentMajorMinor 11.0 -CurrentPrereleaseLabel preview.1

# Example with exact package versions:
# .\ApiDiff.ps1 -PreviousVersion "10.0.0-preview.7.25380.108" -CurrentVersion "10.0.0-rc.1.25451.107"

Param (
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^(\d+\.\d+)?$")]
    [string]
    $PreviousMajorMinor # 7.0, 8.0, 9.0, ...
    ,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [ValidatePattern("^((preview|rc)\.\d+)?$")]
    [string]
    $PreviousPrereleaseLabel # "preview.7", "rc.1", etc. Omit for GA.
    ,
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^(\d+\.\d+)?$")]
    [string]
    $CurrentMajorMinor # 7.0, 8.0, 9.0, ...
    ,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [ValidatePattern("^((preview|rc)\.\d+)?$")]
    [string]
    $CurrentPrereleaseLabel # "preview.7", "rc.1", etc. Omit for GA.
    ,
    [Parameter(Mandatory = $false)]
    [string]
    $CoreRepo
    ,
    [Parameter(Mandatory = $false)]
    [string]
    $TmpFolder
    ,
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]
    $AttributesToExcludeFilePath = "ApiDiffAttributesToExclude.txt"
    ,
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]
    $AssembliesToExcludeFilePath = "ApiDiffAssembliesToExclude.txt"
    ,
    [Parameter(Mandatory = $false)]
    [string]
    $PreviousNuGetFeed
    ,
    [Parameter(Mandatory = $false)]
    [string]
    $CurrentNuGetFeed
    ,
    [Parameter(Mandatory = $false)]
    [switch]
    $ExcludeNetCore
    ,
    [Parameter(Mandatory = $false)]
    [switch]
    $ExcludeAspNetCore
    ,
    [Parameter(Mandatory = $false)]
    [switch]
    $ExcludeWindowsDesktop
    ,
    [Parameter(Mandatory = $false)]
    [switch]
    $InstallApiDiff
    ,
    [Parameter(Mandatory = $false)]
    [string]
    $PreviousVersion = ""
    ,
    [Parameter(Mandatory = $false)]
    [string]
    $CurrentVersion = ""
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "This script requires PowerShell 7.0 or later.  See  https://aka.ms/PSWindows for instructions." -ErrorAction Stop
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$collectScript = [IO.Path]::Combine($scriptDir, "ApiDiff-CollectAssemblies.ps1")
$reportScript = [IO.Path]::Combine($scriptDir, "ApiDiff-GenerateReport.ps1")

If (-not (Test-Path $collectScript)) {
    Write-Error "Cannot find '$collectScript'." -ErrorAction Stop
}
If (-not (Test-Path $reportScript)) {
    Write-Error "Cannot find '$reportScript'." -ErrorAction Stop
}

## Build parameters for the collection step
$collectParams = @{}

If (-not [System.String]::IsNullOrWhiteSpace($PreviousMajorMinor))      { $collectParams['PreviousMajorMinor'] = $PreviousMajorMinor }
If (-not [System.String]::IsNullOrWhiteSpace($PreviousPrereleaseLabel)) { $collectParams['PreviousPrereleaseLabel'] = $PreviousPrereleaseLabel }
If (-not [System.String]::IsNullOrWhiteSpace($CurrentMajorMinor))       { $collectParams['CurrentMajorMinor'] = $CurrentMajorMinor }
If (-not [System.String]::IsNullOrWhiteSpace($CurrentPrereleaseLabel))  { $collectParams['CurrentPrereleaseLabel'] = $CurrentPrereleaseLabel }
If (-not [System.String]::IsNullOrWhiteSpace($CoreRepo))                { $collectParams['CoreRepo'] = $CoreRepo }
If (-not [System.String]::IsNullOrWhiteSpace($TmpFolder))               { $collectParams['TmpFolder'] = $TmpFolder }
If (-not [System.String]::IsNullOrWhiteSpace($PreviousNuGetFeed))       { $collectParams['PreviousNuGetFeed'] = $PreviousNuGetFeed }
If (-not [System.String]::IsNullOrWhiteSpace($CurrentNuGetFeed))        { $collectParams['CurrentNuGetFeed'] = $CurrentNuGetFeed }
If (-not [System.String]::IsNullOrWhiteSpace($PreviousVersion))         { $collectParams['PreviousVersion'] = $PreviousVersion }
If (-not [System.String]::IsNullOrWhiteSpace($CurrentVersion))          { $collectParams['CurrentVersion'] = $CurrentVersion }

# Always pass the exclude file paths through
$collectParams['AttributesToExcludeFilePath'] = $AttributesToExcludeFilePath
$collectParams['AssembliesToExcludeFilePath'] = $AssembliesToExcludeFilePath

If ($ExcludeNetCore)        { $collectParams['ExcludeNetCore'] = $true }
If ($ExcludeAspNetCore)     { $collectParams['ExcludeAspNetCore'] = $true }
If ($ExcludeWindowsDesktop) { $collectParams['ExcludeWindowsDesktop'] = $true }

## Step 1: Collect assemblies
Write-Host ""
Write-Host "=== Step 1: Collecting reference assemblies ===" -ForegroundColor Cyan
Write-Host ""

$jsonOutput = & $collectScript @collectParams

If ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    Write-Error "Assembly collection failed with exit code $LASTEXITCODE." -ErrorAction Stop
}

$jsonText = ($jsonOutput | Out-String).Trim()

If ([System.String]::IsNullOrWhiteSpace($jsonText)) {
    Write-Error "Assembly collection produced no output." -ErrorAction Stop
}

## Step 2: Generate reports
Write-Host ""
Write-Host "=== Step 2: Generating API diff reports ===" -ForegroundColor Cyan
Write-Host ""

$reportParams = @{
    InputJson = $jsonText
}

If ($InstallApiDiff) { $reportParams['InstallApiDiff'] = $true }

& $reportScript @reportParams

If ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    Write-Error "Report generation failed with exit code $LASTEXITCODE." -ErrorAction Stop
}
