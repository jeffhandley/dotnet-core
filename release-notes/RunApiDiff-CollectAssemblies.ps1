# Resolves .NET versions, downloads NuGet reference packages, and extracts
# reference assemblies to disk.  Outputs a JSON manifest to stdout describing
# the before/after assembly paths for each SDK, ready for consumption by
# RunApiDiff-GenerateReport.ps1 or an MCP-based API-diff tool.
#
# This script is one half of the former RunApiDiff.ps1; the other half is
# RunApiDiff-GenerateReport.ps1.  Use RunApiDiff.ps1 to run both steps together.

Param (
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^(\d+\.\d+)?$")]
    [string]
    $PreviousMajorMinor # 7.0, 8.0, 9.0, ...
    ,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [ValidatePattern("^((preview|rc)\.\d+|\*)?$")]
    [string]
    $PreviousPrereleaseLabel # "preview.7", "rc.1", etc. Omit for GA. Use "*" for latest.
    ,
    [Parameter(Mandatory = $false)]
    [ValidatePattern("^(\d+\.\d+)?$")]
    [string]
    $CurrentMajorMinor # 7.0, 8.0, 9.0, ...
    ,
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [ValidatePattern("^((preview|rc)\.\d+|\*)?$")]
    [string]
    $CurrentPrereleaseLabel # "preview.7", "rc.1", etc. Omit for GA. Use "*" for latest.
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
    [string]
    $PreviousVersion = ""
    ,
    [Parameter(Mandatory = $false)]
    [string]
    $CurrentVersion = ""
)

#######################
### Start Functions ###
#######################

$DotNetPublicFeedUrl = "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/index.json"

Function ResolveFeedUrl {
    Param ([string] $feedNameOrUrl)
    If ($feedNameOrUrl -match "^https?://") { Return $feedNameOrUrl }
    Return "https://pkgs.dev.azure.com/dnceng/public/_packaging/$feedNameOrUrl/nuget/v3/index.json"
}

Function GetFeedName {
    Param ([string] $feedUrl)
    If ($feedUrl -match '_packaging/([^/]+)/') { Return $Matches[1] }
    Return $feedUrl
}

Function SearchRefPackVersions {
    Param (
        [string] $packageId,
        [string] $feedUrl
    )
    $feedName = GetFeedName $feedUrl
    Write-Color cyan "Searching for ref pack '$packageId' on $feedName..."
    try {
        $output = & dotnet package search $packageId --prerelease --format json --exact-match --source $feedUrl --take 500 2>&1
        $json = $output | Out-String
        $parsed = $json | ConvertFrom-Json
        if ($parsed.searchResult -and $parsed.searchResult.Count -gt 0 -and $parsed.searchResult[0].packages) {
            $versions = @($parsed.searchResult[0].packages | ForEach-Object { $_.version })
            Write-Color green "Found $($versions.Count) version(s) of '$packageId' on $feedName"
            return $versions
        }
        Write-Color yellow "No versions of '$packageId' found on $feedName"
        return @()
    }
    catch {
        Write-Color yellow "Search failed for '$packageId' on ${feedName}: $($_.Exception.Message)"
        return @()
    }
}

Function ParseVersionString {
    Param (
        [string] $version,
        [string] $label
    )
    $result = @{ MajorMinor = ""; PrereleaseLabel = "" }
    If ($version -match "^([1-9][0-9]*\.[0-9]+)\.[0-9]+-((?:preview|rc)\.[0-9]+)") {
        $result.MajorMinor = $Matches[1]
        $result.PrereleaseLabel = $Matches[2]
    }
    ElseIf ($version -match "^([1-9][0-9]*\.[0-9]+)\.[0-9]+$") {
        $result.MajorMinor = $Matches[1]
        $result.PrereleaseLabel = ""
    }
    Else {
        Write-Error "Could not parse ${label}Version '$version'. Expected format: 'X.Y.Z' or 'X.Y.Z-preview.N.build' / 'X.Y.Z-rc.N.build'." -ErrorAction Stop
    }
    Return $result
}

Function ParsePrereleaseLabel {
    Param (
        [string] $label
    )
    If ([System.String]::IsNullOrWhiteSpace($label)) {
        Return @{ ReleaseKind = "ga"; PreviewRCNumber = "0" }
    }
    If ($label -eq "*") {
        Return @{ ReleaseKind = "*"; PreviewRCNumber = "0" }
    }
    If ($label -match "^(preview|rc)\.(\d+)$") {
        Return @{ ReleaseKind = $Matches[1]; PreviewRCNumber = $Matches[2] }
    }
    Write-Error "Invalid prerelease label '$label'. Expected format: 'preview.N', 'rc.N', or '*'." -ErrorAction Stop
}

Function GetMilestoneSortWeight {
    Param (
        [string] $releaseKind,
        [int] $number
    )
    Switch ($releaseKind) {
        "preview" { Return $number }
        "rc"      { Return 100 + $number }
        "ga"      { Return 200 }
    }
    Return -1
}

Function ParseApiDiffFolderName {
    Param (
        [string] $majorMinor,
        [string] $folderName
    )
    If ($folderName -eq "ga") {
        Return @{ MajorMinor = $majorMinor; PrereleaseLabel = "" }
    }
    If ($folderName -match "^(preview|rc)(\d+)$") {
        Return @{ MajorMinor = $majorMinor; PrereleaseLabel = "$($Matches[1]).$($Matches[2])" }
    }
    Return $null
}

Function FindLatestApiDiff {
    Param (
        [string] $coreRepo
    )
    $releaseNotesDir = [IO.Path]::Combine($coreRepo, "release-notes")

    $entries = @()
    ForEach ($versionDir in (Get-ChildItem -Directory $releaseNotesDir | Where-Object { $_.Name -match "^\d+\.\d+$" })) {
        $previewDir = [IO.Path]::Combine($versionDir.FullName, "preview")
        If (-not (Test-Path $previewDir)) { Continue }

        ForEach ($milestoneDir in (Get-ChildItem -Directory $previewDir)) {
            $apiDiffDir = [IO.Path]::Combine($milestoneDir.FullName, "api-diff")
            If (-not (Test-Path $apiDiffDir)) { Continue }

            $parsed = ParseApiDiffFolderName $versionDir.Name $milestoneDir.Name
            If (-not $parsed) { Continue }

            $milestoneParsed = ParsePrereleaseLabel $parsed.PrereleaseLabel
            $majorVersion = [int]($versionDir.Name.Split(".")[0])
            $sortKey = $majorVersion * 1000 + (GetMilestoneSortWeight $milestoneParsed.ReleaseKind ([int]$milestoneParsed.PreviewRCNumber))

            $entries += @{ MajorMinor = $parsed.MajorMinor; PrereleaseLabel = $parsed.PrereleaseLabel; SortKey = $sortKey }
        }
    }

    If ($entries.Count -eq 0) { Return $null }

    Return ($entries | Sort-Object { $_.SortKey } | Select-Object -Last 1)
}

Function GetNextVersionFromFeed {
    Param (
        [string] $majorMinor,
        [string] $prereleaseLabel,
        [string] $feedUrl
    )

    $currentParsed = ParsePrereleaseLabel $prereleaseLabel
    $currentWeight = GetMilestoneSortWeight $currentParsed.ReleaseKind ([int]$currentParsed.PreviewRCNumber)

    $versions = SearchRefPackVersions "Microsoft.NETCore.App.Ref" $feedUrl
    If ($versions.Count -eq 0) { Return $null }

    $candidates = @()
    ForEach ($v in $versions) {
        $parsed = $null
        try { $parsed = ParseVersionString $v "probe" } catch { Continue }
        If ($parsed.MajorMinor -ne $majorMinor) { Continue }

        $milestoneParsed = ParsePrereleaseLabel $parsed.PrereleaseLabel
        $weight = GetMilestoneSortWeight $milestoneParsed.ReleaseKind ([int]$milestoneParsed.PreviewRCNumber)
        If ($weight -gt $currentWeight) {
            $candidates += @{ MajorMinor = $parsed.MajorMinor; PrereleaseLabel = $parsed.PrereleaseLabel; Weight = $weight }
        }
    }

    If ($candidates.Count -gt 0) {
        Return ($candidates | Sort-Object { $_.Weight } | Select-Object -First 1)
    }

    # No newer milestone found on the same major — try the next major on its own feed
    $nextMajor = [int]($majorMinor.Split(".")[0]) + 1
    $nextMajorMinor = "$nextMajor.0"
    $nextMajorFeedUrl = ResolveFeedUrl "dotnet$nextMajor"

    Write-Color cyan "No newer milestone found for $majorMinor on feed. Probing dotnet$nextMajor for $nextMajorMinor..."

    $nextVersions = SearchRefPackVersions "Microsoft.NETCore.App.Ref" $nextMajorFeedUrl
    ForEach ($v in $nextVersions) {
        $parsed = $null
        try { $parsed = ParseVersionString $v "probe" } catch { Continue }
        If ($parsed.MajorMinor -eq $nextMajorMinor) {
            Return @{ MajorMinor = $parsed.MajorMinor; PrereleaseLabel = $parsed.PrereleaseLabel }
        }
    }

    Return $null
}

Function DiscoverVersionFromFeed {
    Param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $feedUrl
        ,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $label # "Previous" or "Current", for error messages
        ,
        [Parameter(Mandatory = $false)]
        [ValidateSet("NETCore", "AspNetCore", "WindowsDesktop")]
        [string]
        $sdkName = "NETCore"
    )

    $refPackageName = "Microsoft.$sdkName.App.Ref"

    Write-Color cyan "Discovering $label version of $refPackageName from feed '$(GetFeedName $feedUrl)'..."

    $versions = SearchRefPackVersions $refPackageName $feedUrl

    If ($versions.Count -eq 0) {
        Write-Error "No versions of $refPackageName found on feed '$(GetFeedName $feedUrl)'. Please specify -${label}MajorMinor and -${label}PrereleaseLabel explicitly." -ErrorAction Stop
    }

    # Versions are returned newest-first from dotnet package search
    $latestVersion = $versions[0]
    Write-Color cyan "Latest $refPackageName version on feed: $latestVersion"

    Return ParseVersionString $latestVersion $label
}

Function Write-Color {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    Param (
        [ValidateNotNullOrEmpty()]
        [string] $newColor
    )

    If ($args) {
        Write-Host ($args -join ' ') -ForegroundColor $newColor
    }
    Else {
        $input | ForEach-Object { Write-Host $_ -ForegroundColor $newColor }
    }
}

Function VerifyPathOrExit {
    Param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $path
    )

    If (-Not (Test-Path -Path $path)) {
        Write-Error "The path '$path' does not exist." -ErrorAction Stop
    }
}

Function RemoveFolderIfExists {
    Param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $path
    )

    If (Test-Path -Path $path) {
        Write-Color yellow "Removing existing folder: $path"
        Remove-Item -Recurse -Path $path
    }
}

Function RecreateFolder {
    Param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $path
    )

    RemoveFolderIfExists $path

    Write-Color cyan "Creating new folder: $path"
    New-Item -ItemType Directory -Path $path | Out-Null
}

Function VerifyCountDlls {
    Param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $path
    )

    VerifyPathOrExit $path

    $count = (Get-ChildItem -Path $path -Filter "*.dll" | Measure-Object).Count
    If ($count -eq 0) {
        Write-Error "There are no DLL files inside the folder." -ErrorAction Stop
    }
}

Function GetDotNetFullName {
    Param (
        [Parameter(Mandatory = $true)]
        [bool]
        $IsComparingReleases
        ,
        [Parameter(Mandatory = $true)]
        [ValidatePattern("\d+\.\d")]
        [string]
        $dotNetVersion # 7.0, 8.0, 9.0, ...
        ,
        [Parameter(Mandatory = $true)]
        [string]
        [ValidateSet("preview", "rc", "ga", "*")]
        $releaseKind
        ,
        [Parameter(Mandatory = $true)]
        [ValidatePattern("(\d+)?")]
        [string]
        $previewNumberVersion # 0, 1, 2, 3, ...
    )

    If ($IsComparingReleases) {
        Return "$dotNetVersion.$previewNumberVersion"
    }

    If ($releaseKind -In @("ga", "*")) {
        If ($previewNumberVersion -eq "0") {
            Return "$dotNetVersion-$releaseKind"
        }
        Return "$dotNetVersion.$previewNumberVersion"
    }

    Return "$dotNetVersion-$releaseKind$previewNumberVersion"
}

Function GetDotNetFriendlyName {
    Param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern("\d+\.\d")]
        [string]
        $DotNetVersion # 7.0, 8.0, 9.0, ...
        ,
        [Parameter(Mandatory = $true)]
        [string]
        [ValidateSet("preview", "rc", "ga", "*")]
        $releaseKind
        ,
        [Parameter(Mandatory = $true)]
        [ValidatePattern("(\d+)?")]
        [string]
        $PreviewNumberVersion # 0, 1, 2, 3, ...
    )

    If ($releaseKind -eq "*") {
        Return ".NET $DotNetVersion"
    }

    $friendlyPreview = ""
    If ($releaseKind -eq "preview") {
        $friendlyPreview = "Preview"
    }
    ElseIf ($releaseKind -eq "rc") {
        $friendlyPreview = "RC"
    }
    ElseIf ($releaseKind -eq "ga") {
        $friendlyPreview = "GA"
        If ($PreviewNumberVersion -eq 0) {
            Return ".NET $DotNetVersion $friendlyPreview"
        }
        Return ".NET $DotNetVersion.$PreviewNumberVersion"
    }

    Return ".NET $DotNetVersion $friendlyPreview $PreviewNumberVersion"
}

Function GetReleaseKindFolderName {
    Param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern("\d+\.\d")]
        [string]
        $dotNetVersion # 7.0, 8.0, 9.0, ...
        ,
        [Parameter(Mandatory = $true)]
        [string]
        [ValidateSet("preview", "rc", "ga", "*")]
        $releaseKind
        ,
        [Parameter(Mandatory = $true)]
        [ValidatePattern("(\d+)?")]
        [string]
        $previewNumberVersion # 0, 1, 2, 3, ...
    )

    If ($releaseKind -In @("ga", "*")) {
        If ($previewNumberVersion -eq "0") {
            Return $releaseKind
        }
        Return "$dotNetVersion.$previewNumberVersion"
    }

    Return "$releaseKind$previewNumberVersion"
}

Function GetPreviewFolderPath {
    Param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $rootFolder
        ,
        [Parameter(Mandatory = $true)]
        [ValidatePattern("\d+\.\d")]
        [string]
        $dotNetVersion # 7.0, 8.0, 9.0, ...
        ,
        [Parameter(Mandatory = $true)]
        [string]
        [ValidateSet("preview", "rc", "ga", "*")]
        $releaseKind
        ,
        [Parameter(Mandatory = $true)]
        [ValidatePattern("(\d+)?")]
        [string]
        $previewNumberVersion # 0, 1, 2, 3, ...
        ,
        [Parameter(Mandatory = $true)]
        [bool]
        $IsComparingReleases # True when comparing releases across major versions
    )

    $prefixFolder = [IO.Path]::Combine($rootFolder, "release-notes", $dotNetVersion)
    $apiDiffFolderName = "api-diff"

    If ($IsComparingReleases) {
        Return [IO.Path]::Combine($prefixFolder, "$dotNetVersion.$previewNumberVersion", $apiDiffFolderName)
    }

    $releaseKindFolderName = GetReleaseKindFolderName -dotNetVersion $dotNetVersion -releaseKind $releaseKind -previewNumberVersion $previewNumberVersion
    Return [IO.Path]::Combine($prefixFolder, "preview", $releaseKindFolderName, $apiDiffFolderName)
}

Function DownloadPackage {
    Param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $nuGetFeeds
        ,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $tmpFolder
        ,
        [Parameter(Mandatory = $true)]
        [ValidateSet("NETCore", "AspNetCore", "WindowsDesktop")]
        [string]
        $sdkName
        ,
        [Parameter(Mandatory = $true)]
        [ValidateSet("Before", "After")]
        [string]
        $beforeOrAfter
        ,
        [Parameter(Mandatory = $true)]
        [ValidatePattern("\d+\.\d")]
        [string]
        $dotNetVersion
        ,
        [Parameter(Mandatory = $false)]
        [ValidateSet("preview", "rc", "ga", "*", "")]
        [string]
        $releaseKind = ""
        ,
        [Parameter(Mandatory = $false)]
        [string]
        $previewNumberVersion = ""
        ,
        [Parameter(Mandatory = $false)]
        [string]
        $version = ""
        ,
        [ref]
        $resultingPath
        ,
        [ref]
        $resolvedFeedUrl
    )

    $fullSdkName = "Microsoft.$sdkName.App"
    $destinationFolder = [IO.Path]::Combine($tmpFolder, "$fullSdkName.$beforeOrAfter")
    RecreateFolder $destinationFolder

    $refPackageName = "$fullSdkName.Ref"

    # If exact version is provided, use it directly — still need to find a feed that has it
    If (-Not ([System.String]::IsNullOrWhiteSpace($version))) {
        Write-Color cyan "Using exact package version: $version"
        $usedFeedUrl = $null
        ForEach ($feed in $nuGetFeeds) {
            $feedUrl = ResolveFeedUrl $feed
            $versions = SearchRefPackVersions $refPackageName $feedUrl
            If ($versions -contains $version) {
                $usedFeedUrl = $feedUrl
                Write-Color green "Found exact version '$version' on $(GetFeedName $feedUrl)"
                Break
            }
        }
        If (-not $usedFeedUrl) {
            # Fall back to first feed for download attempt
            $usedFeedUrl = ResolveFeedUrl $nuGetFeeds[0]
            Write-Color yellow "Exact version '$version' not confirmed on any feed; trying $(GetFeedName $usedFeedUrl)"
        }
    }
    Else {
        If ([System.String]::IsNullOrWhiteSpace($releaseKind) -or [System.String]::IsNullOrWhiteSpace($previewNumberVersion)) {
            Write-Error "Either -version or both -releaseKind and -previewNumberVersion must be provided to DownloadPackage." -ErrorAction Stop
        }

        # Build the search/match pattern
        $searchTerm = ""
        $preferStable = $false
        If ($releaseKind -eq "*") {
            $searchTerm = "$dotNetVersion.*"
            $preferStable = $true
        }
        ElseIf ($releaseKind -eq "ga") {
            $searchTerm = "$dotNetVersion.$previewNumberVersion"
        }
        Else {
            $searchTerm = "$dotNetVersion.*-$releaseKind.$previewNumberVersion*"
        }

        # Try each feed in order until we find a matching version
        $version = ""
        $usedFeedUrl = $null
        ForEach ($feed in $nuGetFeeds) {
            $feedUrl = ResolveFeedUrl $feed
            $feedName = GetFeedName $feedUrl
            Write-Color cyan "Searching for '$refPackageName' matching '$searchTerm' on $feedName..."

            $allVersions = SearchRefPackVersions $refPackageName $feedUrl
            If ($allVersions.Count -eq 0) { Continue }

            $matchingVersions = @($allVersions | Where-Object { $_ -Like $searchTerm } | Sort-Object -Descending)

            If ($preferStable) {
                $stableVersions = @($matchingVersions | Where-Object { $_ -NotLike "*-*" })
                If ($stableVersions.Count -gt 0) {
                    $version = $stableVersions[0]
                    Write-Color green "Found stable version '$version' on $feedName."
                }
                ElseIf ($matchingVersions.Count -gt 0) {
                    $version = $matchingVersions[0]
                    Write-Color green "Found prerelease version '$version' on $feedName (no stable version available)."
                }
            }
            ElseIf ($matchingVersions.Count -gt 0) {
                $version = $matchingVersions[0]
                Write-Color green "Found version '$version' on $feedName."
            }

            If (-not [System.String]::IsNullOrWhiteSpace($version)) {
                $usedFeedUrl = $feedUrl
                Break
            }
        }

        If ([System.String]::IsNullOrWhiteSpace($version)) {
            Write-Error "No version of '$refPackageName' matching '$searchTerm' found on any feed." -ErrorAction Stop
        }
    }

    If ($resolvedFeedUrl) {
        $resolvedFeedUrl.value = $usedFeedUrl
    }

    $nupkgFile = [IO.Path]::Combine($tmpFolder, "$refPackageName.$version.nupkg")

    If (-Not(Test-Path -Path $nupkgFile)) {
        # Try flat2 download from each feed until one succeeds
        $downloaded = $false
        $pkgIdLower = $refPackageName.ToLower()

        # Try the resolved feed first, then others as fallback
        $downloadFeeds = @($usedFeedUrl) + @($nuGetFeeds | ForEach-Object { ResolveFeedUrl $_ } | Where-Object { $_ -ne $usedFeedUrl })

        ForEach ($feedUrl in $downloadFeeds) {
            $feedName = GetFeedName $feedUrl
            try {
                $serviceIndex = Invoke-RestMethod -Uri $feedUrl
                $flatContainer = $serviceIndex.resources | Where-Object { $_.'@type' -match 'PackageBaseAddress' } | Select-Object -First 1
                If (-not $flatContainer) { Continue }

                $flatBaseUrl = $flatContainer.'@id'
                If ([string]::IsNullOrWhiteSpace($flatBaseUrl)) { Continue }

                $nupkgUrl = "$flatBaseUrl$pkgIdLower/$version/$pkgIdLower.$version.nupkg"
                Write-Color yellow "Downloading '$refPackageName' v$version from $feedName..."
                Invoke-WebRequest -Uri $nupkgUrl -OutFile $nupkgFile
                VerifyPathOrExit $nupkgFile
                $downloaded = $true
                Break
            }
            catch {
                Write-Color yellow "Download from $feedName failed: $($_.Exception.Message)"
            }
        }

        If (-not $downloaded) {
            Write-Error "Failed to download '$refPackageName' v$version from any feed." -ErrorAction Stop
        }
    }
    Else {
        Write-Color green "File '$nupkgFile' already exists locally. Skipping re-download."
    }

    Expand-Archive -Path $nupkgFile -DestinationPath $destinationFolder -ErrorAction Stop

    $dllPath = [IO.Path]::Combine($destinationFolder, "ref", "net$dotNetVersion")
    VerifyPathOrExit $dllPath
    VerifyCountDlls $dllPath
    $resultingPath.value = $dllPath
}

#####################
### End Functions ###
#####################

#######################
### Start Execution ###
#######################

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "This script requires PowerShell 7.0 or later.  See  https://aka.ms/PSWindows for instructions." -ErrorAction Stop
}

## Resolve CoreRepo and scriptDir early (needed for api-diff scanning and exclude file paths)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

If ([System.String]::IsNullOrWhiteSpace($CoreRepo)) {
    try {
        $CoreRepo = git -C $scriptDir rev-parse --show-toplevel 2>$null
    }
    catch {
        $null = $null
    }

    If ([System.String]::IsNullOrWhiteSpace($CoreRepo)) {
        Write-Error "Could not determine the git repository root from '$scriptDir'. Please specify -CoreRepo explicitly." -ErrorAction Stop
    }

    Write-Color cyan "Using git repo root: $CoreRepo"
}

$CoreRepo = [System.IO.Path]::GetFullPath((Resolve-Path $CoreRepo).Path)

## Extract MajorMinor and PrereleaseLabel from explicit Version parameters if provided
If (-not [System.String]::IsNullOrWhiteSpace($PreviousVersion)) {
    $parsed = ParseVersionString $PreviousVersion "Previous"
    If ([System.String]::IsNullOrWhiteSpace($PreviousMajorMinor)) { $PreviousMajorMinor = $parsed.MajorMinor }
    If ([System.String]::IsNullOrWhiteSpace($PreviousPrereleaseLabel)) { $PreviousPrereleaseLabel = $parsed.PrereleaseLabel }
    Write-Color green "Parsed from PreviousVersion: MajorMinor=$PreviousMajorMinor, PrereleaseLabel=$(If ($PreviousPrereleaseLabel) { $PreviousPrereleaseLabel } Else { 'GA' })"
}

If (-not [System.String]::IsNullOrWhiteSpace($CurrentVersion)) {
    $parsed = ParseVersionString $CurrentVersion "Current"
    If ([System.String]::IsNullOrWhiteSpace($CurrentMajorMinor)) { $CurrentMajorMinor = $parsed.MajorMinor }
    If ([System.String]::IsNullOrWhiteSpace($CurrentPrereleaseLabel)) { $CurrentPrereleaseLabel = $parsed.PrereleaseLabel }
    Write-Color green "Parsed from CurrentVersion: MajorMinor=$CurrentMajorMinor, PrereleaseLabel=$(If ($CurrentPrereleaseLabel) { $CurrentPrereleaseLabel } Else { 'GA' })"
}

## Infer current and previous versions from existing api-diffs if not provided
If ([System.String]::IsNullOrWhiteSpace($CurrentMajorMinor) -and [System.String]::IsNullOrWhiteSpace($CurrentPrereleaseLabel) -and [System.String]::IsNullOrWhiteSpace($CurrentNuGetFeed)) {
    $latestApiDiff = FindLatestApiDiff $CoreRepo
    If ($latestApiDiff) {
        $latestDesc = If ($latestApiDiff.PrereleaseLabel) { "$($latestApiDiff.MajorMinor)-$($latestApiDiff.PrereleaseLabel)" } Else { "$($latestApiDiff.MajorMinor) GA" }
        Write-Color cyan "Latest existing api-diff: $latestDesc"

        # Discover next milestone from the dotnet{MAJOR} feed (unreleased versions live here)
        $discoveryMajor = [int]($latestApiDiff.MajorMinor.Split(".")[0])
        $discoveryFeedUrl = ResolveFeedUrl "dotnet$discoveryMajor"

        $next = GetNextVersionFromFeed -majorMinor $latestApiDiff.MajorMinor -prereleaseLabel $latestApiDiff.PrereleaseLabel -feedUrl $discoveryFeedUrl

        If ($next) {
            $CurrentMajorMinor = $next.MajorMinor
            $CurrentPrereleaseLabel = $next.PrereleaseLabel
            $nextDesc = If ($CurrentPrereleaseLabel) { "$CurrentMajorMinor-$CurrentPrereleaseLabel" } Else { "$CurrentMajorMinor GA" }
            Write-Color green "Discovered next version from feed: $nextDesc"
        } Else {
            Write-Error "Could not discover the next version from dotnet$discoveryMajor feed after $latestDesc. Specify -CurrentMajorMinor and -CurrentPrereleaseLabel explicitly." -ErrorAction Stop
        }

        # Also infer previous from the latest api-diff if not explicitly provided
        If ([System.String]::IsNullOrWhiteSpace($PreviousMajorMinor) -and [System.String]::IsNullOrWhiteSpace($PreviousPrereleaseLabel) -and [System.String]::IsNullOrWhiteSpace($PreviousVersion)) {
            $PreviousMajorMinor = $latestApiDiff.MajorMinor
            $PreviousPrereleaseLabel = $latestApiDiff.PrereleaseLabel
            Write-Color green "Inferred previous version: $latestDesc"
        }
    }
}

## Default CurrentNuGetFeed and PreviousNuGetFeed to the dotnet-public feed if not provided
If ([System.String]::IsNullOrWhiteSpace($CurrentNuGetFeed)) {
    $CurrentNuGetFeed = $DotNetPublicFeedUrl
    Write-Color cyan "Using default current feed: $(GetFeedName $CurrentNuGetFeed)"
}

If ([System.String]::IsNullOrWhiteSpace($PreviousNuGetFeed)) {
    $PreviousNuGetFeed = $DotNetPublicFeedUrl
    Write-Color cyan "Using default previous feed: $(GetFeedName $PreviousNuGetFeed)"
}

## Preflight check: verify `dotnet package search` is available
try {
    $dotnetVersion = & dotnet --version 2>&1
    Write-Color cyan "Using dotnet CLI: $dotnetVersion"
    $searchHelp = & dotnet package search --help 2>&1 | Out-String
    If ($searchHelp -notmatch "search") {
        Write-Error "The 'dotnet package search' command is not available in this version of the .NET SDK." -ErrorAction Stop
    }
}
catch {
    Write-Error "The 'dotnet' CLI is not available or 'dotnet package search' is not supported. Ensure .NET 8+ SDK is installed." -ErrorAction Stop
}

## Discover version info from feeds if not provided
If ([System.String]::IsNullOrWhiteSpace($PreviousMajorMinor) -and [System.String]::IsNullOrWhiteSpace($PreviousPrereleaseLabel)) {
    $discovered = DiscoverVersionFromFeed $PreviousNuGetFeed "Previous"
    $PreviousMajorMinor = $discovered.MajorMinor
    $PreviousPrereleaseLabel = $discovered.PrereleaseLabel
    Write-Color green "Discovered previous: $PreviousMajorMinor $(If ($PreviousPrereleaseLabel) { $PreviousPrereleaseLabel } Else { 'GA' })"
} ElseIf ([System.String]::IsNullOrWhiteSpace($PreviousMajorMinor)) {
    $discovered = DiscoverVersionFromFeed $PreviousNuGetFeed "Previous"
    $PreviousMajorMinor = $discovered.MajorMinor
    Write-Color green "Discovered previous major.minor: $PreviousMajorMinor"
}

If ([System.String]::IsNullOrWhiteSpace($CurrentMajorMinor) -and [System.String]::IsNullOrWhiteSpace($CurrentPrereleaseLabel)) {
    $discovered = DiscoverVersionFromFeed $CurrentNuGetFeed "Current"
    $CurrentMajorMinor = $discovered.MajorMinor
    $CurrentPrereleaseLabel = $discovered.PrereleaseLabel
    Write-Color green "Discovered current: $CurrentMajorMinor $(If ($CurrentPrereleaseLabel) { $CurrentPrereleaseLabel } Else { 'GA' })"
} ElseIf ([System.String]::IsNullOrWhiteSpace($CurrentMajorMinor)) {
    $discovered = DiscoverVersionFromFeed $CurrentNuGetFeed "Current"
    $CurrentMajorMinor = $discovered.MajorMinor
    Write-Color green "Discovered current major.minor: $CurrentMajorMinor"
}

## Parse prerelease labels into internal variables used by the rest of the script
$previousParsed = ParsePrereleaseLabel $PreviousPrereleaseLabel
$PreviousReleaseKind = $previousParsed.ReleaseKind
$PreviousPreviewRCNumber = $previousParsed.PreviewRCNumber

$currentParsed = ParsePrereleaseLabel $CurrentPrereleaseLabel
$CurrentReleaseKind = $currentParsed.ReleaseKind
$CurrentPreviewRCNumber = $currentParsed.PreviewRCNumber

# Validate required values are present
If ([System.String]::IsNullOrWhiteSpace($PreviousMajorMinor)) {
    Write-Error "PreviousMajorMinor is required. Specify it explicitly or provide -PreviousNuGetFeed to auto-discover." -ErrorAction Stop
}
If ([System.String]::IsNullOrWhiteSpace($CurrentMajorMinor)) {
    Write-Error "CurrentMajorMinor is required. Specify it explicitly or provide -CurrentNuGetFeed to auto-discover." -ErrorAction Stop
}

# Validate that previous and current versions are different
If ($PreviousMajorMinor -eq $CurrentMajorMinor -and $PreviousPrereleaseLabel -eq $CurrentPrereleaseLabel) {
    $previousDesc = If ($PreviousPrereleaseLabel) { "$PreviousMajorMinor-$PreviousPrereleaseLabel" } Else { "$PreviousMajorMinor GA" }
    Write-Error "Previous and current versions are the same ($previousDesc). Ensure -PreviousNuGetFeed and -CurrentNuGetFeed point to different versions, or specify version parameters explicitly." -ErrorAction Stop
}

# True when comparing releases across major versions (ga or * on both sides)
$IsComparingReleases = ($PreviousMajorMinor -Ne $CurrentMajorMinor) -And ($PreviousReleaseKind -In @("ga", "*")) -And ($CurrentReleaseKind -In @("ga", "*"))

## Build per-side download feed probe arrays
## Once a milestone is known (specified or discovered), try dotnet-public first
## (released packages are authoritative there), then fall back to dotnet{MAJOR}.
## For cross-major comparisons, the dotnet{MAJOR} feed differs between sides.
$previousMajorVersion = [int]($PreviousMajorMinor.Split(".")[0])
$currentMajorVersion = [int]($CurrentMajorMinor.Split(".")[0])

$previousDotNetMajorFeed = ResolveFeedUrl "dotnet$previousMajorVersion"
$currentDotNetMajorFeed = ResolveFeedUrl "dotnet$currentMajorVersion"

$previousDownloadFeeds = @($DotNetPublicFeedUrl, $previousDotNetMajorFeed) | Select-Object -Unique
$currentDownloadFeeds = @($DotNetPublicFeedUrl, $currentDotNetMajorFeed) | Select-Object -Unique

# If explicit feeds were provided, use them directly (single feed, no fallback)
If ($PreviousNuGetFeed -ne $DotNetPublicFeedUrl) {
    $previousDownloadFeeds = @($PreviousNuGetFeed)
}
If ($CurrentNuGetFeed -ne $DotNetPublicFeedUrl) {
    $currentDownloadFeeds = @($CurrentNuGetFeed)
}

Write-Color cyan "Previous feed probe order: $($previousDownloadFeeds | ForEach-Object { GetFeedName $_ } | Join-String -Separator ', ')"
Write-Color cyan "Current feed probe order: $($currentDownloadFeeds | ForEach-Object { GetFeedName $_ } | Join-String -Separator ', ')"

## Resolve exclude file paths relative to the script's directory if they are relative paths
If (-not [System.IO.Path]::IsPathRooted($AttributesToExcludeFilePath)) {
    $AttributesToExcludeFilePath = [IO.Path]::Combine($scriptDir, $AttributesToExcludeFilePath)
}
If (-not [System.IO.Path]::IsPathRooted($AssembliesToExcludeFilePath)) {
    $AssembliesToExcludeFilePath = [IO.Path]::Combine($scriptDir, $AssembliesToExcludeFilePath)
}

## Create a temp folder if not provided
If ([System.String]::IsNullOrWhiteSpace($TmpFolder)) {
    $TmpFolder = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $TmpFolder | Out-Null
    Write-Color cyan "Using temp folder: $TmpFolder"
} Else {
    $TmpFolder = [System.IO.Path]::GetFullPath((Resolve-Path $TmpFolder).Path)
}

## Check folders passed as parameters exist
VerifyPathOrExit $CoreRepo
VerifyPathOrExit $TmpFolder

## Create api-diff output folder
$previewFolderPath = GetPreviewFolderPath -rootFolder $CoreRepo -dotNetVersion $CurrentMajorMinor -releaseKind $CurrentReleaseKind -previewNumberVersion $CurrentPreviewRCNumber -IsComparingReleases $IsComparingReleases
If (-Not (Test-Path -Path $previewFolderPath)) {
    Write-Color white "Creating new diff folder: $previewFolderPath"
    New-Item -ItemType Directory -Path $previewFolderPath | Out-Null
}

## Compute version names
$currentDotNetFullName = GetDotNetFullName -IsComparingReleases $IsComparingReleases -dotNetVersion $CurrentMajorMinor -releaseKind $CurrentReleaseKind -previewNumberVersion $CurrentPreviewRCNumber
$previousDotNetFriendlyName = GetDotNetFriendlyName -DotNetVersion $PreviousMajorMinor -releaseKind $PreviousReleaseKind -PreviewNumberVersion $PreviousPreviewRCNumber
$currentDotNetFriendlyName = GetDotNetFriendlyName -DotNetVersion $CurrentMajorMinor -releaseKind $CurrentReleaseKind -PreviewNumberVersion $CurrentPreviewRCNumber

## Determine which SDKs to process
$sdksToProcess = @()
If (-Not $ExcludeNetCore) { $sdksToProcess += "NETCore" }
If (-Not $ExcludeAspNetCore) { $sdksToProcess += "AspNetCore" }
If (-Not $ExcludeWindowsDesktop) { $sdksToProcess += "WindowsDesktop" }

If ($sdksToProcess.Count -eq 0) {
    Write-Error "All SDKs are excluded. At least one SDK must be included." -ErrorAction Stop
}

## Download reference packages and collect assembly paths

# Track resolved feeds for each ref pack (for manifest enrichment)
$refPackDetails = @()

# Always download NETCore packages (needed either for its own diff or as refs for other SDKs)
$netCoreBeforePath = ""
$netCoreAfterPath = ""
$netCoreBeforeFeed = ""
$netCoreAfterFeed = ""

DownloadPackage -nuGetFeeds $previousDownloadFeeds -tmpFolder $TmpFolder -sdkName "NETCore" -beforeOrAfter "Before" `
    -dotNetVersion $PreviousMajorMinor -releaseKind $PreviousReleaseKind -previewNumberVersion $PreviousPreviewRCNumber `
    -version $PreviousVersion -resultingPath ([ref]$netCoreBeforePath) -resolvedFeedUrl ([ref]$netCoreBeforeFeed)
VerifyPathOrExit $netCoreBeforePath

DownloadPackage -nuGetFeeds $currentDownloadFeeds -tmpFolder $TmpFolder -sdkName "NETCore" -beforeOrAfter "After" `
    -dotNetVersion $CurrentMajorMinor -releaseKind $CurrentReleaseKind -previewNumberVersion $CurrentPreviewRCNumber `
    -version $CurrentVersion -resultingPath ([ref]$netCoreAfterPath) -resolvedFeedUrl ([ref]$netCoreAfterFeed)
VerifyPathOrExit $netCoreAfterPath

# Build SDK manifest entries
$sdkEntries = @()

If (-Not $ExcludeNetCore) {
    $sdkEntries += @{
        name = "NETCore"
        beforePath = $netCoreBeforePath
        afterPath = $netCoreAfterPath
        refBeforePath = $null
        refAfterPath = $null
    }
    $refPackDetails += @{
        name = "Microsoft.NETCore.App.Ref"
        beforeFeed = GetFeedName $netCoreBeforeFeed
        afterFeed = GetFeedName $netCoreAfterFeed
    }
}

If (-Not $ExcludeAspNetCore) {
    $aspBeforePath = ""
    $aspBeforeFeed = ""
    DownloadPackage -nuGetFeeds $previousDownloadFeeds -tmpFolder $TmpFolder -sdkName "AspNetCore" -beforeOrAfter "Before" `
        -dotNetVersion $PreviousMajorMinor -releaseKind $PreviousReleaseKind -previewNumberVersion $PreviousPreviewRCNumber `
        -version "" -resultingPath ([ref]$aspBeforePath) -resolvedFeedUrl ([ref]$aspBeforeFeed)
    VerifyPathOrExit $aspBeforePath

    $aspAfterPath = ""
    $aspAfterFeed = ""
    DownloadPackage -nuGetFeeds $currentDownloadFeeds -tmpFolder $TmpFolder -sdkName "AspNetCore" -beforeOrAfter "After" `
        -dotNetVersion $CurrentMajorMinor -releaseKind $CurrentReleaseKind -previewNumberVersion $CurrentPreviewRCNumber `
        -version "" -resultingPath ([ref]$aspAfterPath) -resolvedFeedUrl ([ref]$aspAfterFeed)
    VerifyPathOrExit $aspAfterPath

    $sdkEntries += @{
        name = "AspNetCore"
        beforePath = $aspBeforePath
        afterPath = $aspAfterPath
        refBeforePath = $netCoreBeforePath
        refAfterPath = $netCoreAfterPath
    }
    $refPackDetails += @{
        name = "Microsoft.AspNetCore.App.Ref"
        beforeFeed = GetFeedName $aspBeforeFeed
        afterFeed = GetFeedName $aspAfterFeed
    }
}

If (-Not $ExcludeWindowsDesktop) {
    $wdBeforePath = ""
    $wdBeforeFeed = ""
    DownloadPackage -nuGetFeeds $previousDownloadFeeds -tmpFolder $TmpFolder -sdkName "WindowsDesktop" -beforeOrAfter "Before" `
        -dotNetVersion $PreviousMajorMinor -releaseKind $PreviousReleaseKind -previewNumberVersion $PreviousPreviewRCNumber `
        -version "" -resultingPath ([ref]$wdBeforePath) -resolvedFeedUrl ([ref]$wdBeforeFeed)
    VerifyPathOrExit $wdBeforePath

    $wdAfterPath = ""
    $wdAfterFeed = ""
    DownloadPackage -nuGetFeeds $currentDownloadFeeds -tmpFolder $TmpFolder -sdkName "WindowsDesktop" -beforeOrAfter "After" `
        -dotNetVersion $CurrentMajorMinor -releaseKind $CurrentReleaseKind -previewNumberVersion $CurrentPreviewRCNumber `
        -version "" -resultingPath ([ref]$wdAfterPath) -resolvedFeedUrl ([ref]$wdAfterFeed)
    VerifyPathOrExit $wdAfterPath

    $sdkEntries += @{
        name = "WindowsDesktop"
        beforePath = $wdBeforePath
        afterPath = $wdAfterPath
        refBeforePath = $netCoreBeforePath
        refAfterPath = $netCoreAfterPath
    }
    $refPackDetails += @{
        name = "Microsoft.WindowsDesktop.App.Ref"
        beforeFeed = GetFeedName $wdBeforeFeed
        afterFeed = GetFeedName $wdAfterFeed
    }
}

## Build and emit JSON manifest to stdout

$manifest = [ordered]@{
    beforeLabel = $previousDotNetFriendlyName
    afterLabel = $currentDotNetFriendlyName
    tableOfContentsTitle = $currentDotNetFullName
    outputPath = $previewFolderPath
    assembliesToExcludeFilePath = $AssembliesToExcludeFilePath
    attributesToExcludeFilePath = $AttributesToExcludeFilePath
    currentMajorVersion = $currentMajorVersion
    sdks = $sdkEntries
    refPacks = $refPackDetails
}

ConvertTo-Json $manifest -Depth 5

#####################
### End Execution ###
#####################
