# Resolves .NET versions, downloads NuGet reference packages, and extracts
# reference assemblies to disk.  Outputs a JSON manifest to stdout describing
# the before/after assembly paths for each SDK, ready for consumption by
# ApiDiff-GenerateReport.ps1 or an MCP-based API-diff tool.
#
# This script is one half of the former RunApiDiff.ps1; the other half is
# ApiDiff-GenerateReport.ps1.  Use ApiDiff.ps1 to run both steps together.

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
    If ($label -match "^(preview|rc)\.(\d+)$") {
        Return @{ ReleaseKind = $Matches[1]; PreviewRCNumber = $Matches[2] }
    }
    Write-Error "Invalid prerelease label '$label'. Expected format: 'preview.N' or 'rc.N'." -ErrorAction Stop
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

    $serviceIndex = Invoke-RestMethod -Uri $feedUrl
    $flatContainer = $serviceIndex.resources | Where-Object { $_.'@type' -match 'PackageBaseAddress' } | Select-Object -First 1
    If (-not $flatContainer) { Return $null }

    $baseUrl = $flatContainer.'@id'
    If ([string]::IsNullOrWhiteSpace($baseUrl)) { Return $null }
    $versionsUrl = "${baseUrl}microsoft.netcore.app.ref/index.json"

    try {
        $versionsResult = Invoke-RestMethod -Uri $versionsUrl
    }
    catch { Return $null }

    If (-not $versionsResult.versions -or $versionsResult.versions.Count -eq 0) { Return $null }

    $candidates = @()
    ForEach ($v in $versionsResult.versions) {
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

    # No newer milestone found on the same major — try the next major
    $nextMajor = [int]($majorMinor.Split(".")[0]) + 1
    $nextMajorMinor = "$nextMajor.0"

    Write-Color cyan "No newer milestone found for $majorMinor on feed. Probing for $nextMajorMinor..."

    try {
        $nextServiceIndex = Invoke-RestMethod -Uri $feedUrl
        $nextFlatContainer = $nextServiceIndex.resources | Where-Object { $_.'@type' -match 'PackageBaseAddress' } | Select-Object -First 1
        If (-not $nextFlatContainer) { Return $null }

        $nextBaseUrl = $nextFlatContainer.'@id'
        If ([string]::IsNullOrWhiteSpace($nextBaseUrl)) { Return $null }
        $nextVersionsUrl = "${nextBaseUrl}microsoft.netcore.app.ref/index.json"
        $nextVersionsResult = Invoke-RestMethod -Uri $nextVersionsUrl

        If ($nextVersionsResult.versions -and $nextVersionsResult.versions.Count -gt 0) {
            ForEach ($v in $nextVersionsResult.versions) {
                $parsed = $null
                try { $parsed = ParseVersionString $v "probe" } catch { Continue }
                If ($parsed.MajorMinor -eq $nextMajorMinor) {
                    Return @{ MajorMinor = $parsed.MajorMinor; PrereleaseLabel = $parsed.PrereleaseLabel }
                }
            }
        }
    }
    catch {
        Write-Color yellow "Could not probe next major feed: $_"
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
    $pkgIdLower = $refPackageName.ToLower()

    Write-Color cyan "Discovering $label version of $refPackageName from feed '$feedUrl'..."

    $serviceIndex = Invoke-RestMethod -Uri $feedUrl
    $flatContainer = $serviceIndex.resources | Where-Object { $_.'@type' -match 'PackageBaseAddress' } | Select-Object -First 1

    If (-not $flatContainer) {
        Write-Error "Could not find PackageBaseAddress endpoint in feed '$feedUrl'. Please specify -${label}MajorMinor and -${label}PrereleaseLabel explicitly." -ErrorAction Stop
    }

    $baseUrl = $flatContainer.'@id'
    If ([string]::IsNullOrWhiteSpace($baseUrl)) {
        Write-Error "PackageBaseAddress endpoint in feed '$feedUrl' has no URL. Please specify -${label}MajorMinor and -${label}PrereleaseLabel explicitly." -ErrorAction Stop
    }
    $versionsUrl = "${baseUrl}${pkgIdLower}/index.json"
    $versionsResult = Invoke-RestMethod -Uri $versionsUrl

    If (-not $versionsResult.versions -or $versionsResult.versions.Count -eq 0) {
        Write-Error "No versions of $refPackageName found on feed '$feedUrl'. Please specify -${label}MajorMinor and -${label}PrereleaseLabel explicitly." -ErrorAction Stop
    }

    $latestVersion = $versionsResult.versions | Select-Object -Last 1
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
        [ValidateSet("preview", "rc", "ga")]
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

    If ($releaseKind -eq "ga") {
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
        [ValidateSet("preview", "rc", "ga")]
        $releaseKind
        ,
        [Parameter(Mandatory = $true)]
        [ValidatePattern("(\d+)?")]
        [string]
        $PreviewNumberVersion # 0, 1, 2, 3, ...
    )

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
        [ValidateSet("preview", "rc", "ga")]
        $releaseKind
        ,
        [Parameter(Mandatory = $true)]
        [ValidatePattern("(\d+)?")]
        [string]
        $previewNumberVersion # 0, 1, 2, 3, ...
    )

    If ($releaseKind -eq "ga") {
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
        [ValidateSet("preview", "rc", "ga")]
        $releaseKind
        ,
        [Parameter(Mandatory = $true)]
        [ValidatePattern("(\d+)?")]
        [string]
        $previewNumberVersion # 0, 1, 2, 3, ...
        ,
        [Parameter(Mandatory = $true)]
        [bool]
        $IsComparingReleases # True when comparing 8.0 GA with 9.0 GA
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
        [string]
        $nuGetFeed
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
        [ValidateSet("preview", "rc", "ga", "")]
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
    )

    $fullSdkName = "Microsoft.$sdkName.App"
    $destinationFolder = [IO.Path]::Combine($tmpFolder, "$fullSdkName.$beforeOrAfter")
    RecreateFolder $destinationFolder

    $refPackageName = "$fullSdkName.Ref"

    # Get service index and flat2 base URL (used for both version search and download)
    $serviceIndex = Invoke-RestMethod -Uri $nuGetFeed
    $flatContainer = $serviceIndex.resources | Where-Object { $_.'@type' -match 'PackageBaseAddress' } | Select-Object -First 1
    $flatBaseUrl = If ($flatContainer) { $flatContainer.'@id' } Else { "" }

    # If exact version is provided, use it directly
    If (-Not ([System.String]::IsNullOrWhiteSpace($version))) {
        Write-Color cyan "Using exact package version: $version"
    }
    Else {
        If ([System.String]::IsNullOrWhiteSpace($releaseKind) -or [System.String]::IsNullOrWhiteSpace($previewNumberVersion)) {
            Write-Error "Either -version or both -releaseKind and -previewNumberVersion must be provided to DownloadPackage." -ErrorAction Stop
        }

        # Search for the package version
        $searchTerm = ""
        If ($releaseKind -eq "ga") {
            $searchTerm = "$dotNetVersion.$previewNumberVersion"
        }
        Else {
            $searchTerm = "$dotNetVersion.*-$releaseKind.$previewNumberVersion*"
        }

        # Try flat2 (PackageBaseAddress) first
        $version = ""

        If ($flatBaseUrl) {
            $pkgIdLower = $refPackageName.ToLower()
            $versionsUrl = "$flatBaseUrl$pkgIdLower/index.json"
            Write-Color cyan "Searching for package '$refPackageName' matching '$searchTerm' via flat2 in feed '$nuGetFeed'..."

            try {
                $versionsResult = Invoke-RestMethod -Uri $versionsUrl
                $matchingVersions = @($versionsResult.versions | Where-Object { $_ -Like $searchTerm } | Sort-Object -Descending)

                If ($matchingVersions.Count -gt 0) {
                    $version = $matchingVersions[0]
                    Write-Color green "Found version '$version' via flat2."
                }
            }
            catch {
                Write-Color yellow "Flat2 lookup failed for '$refPackageName': $_"
            }
        }

        # Fall back to SearchQueryService if flat2 didn't find a match
        If ([System.String]::IsNullOrWhiteSpace($version)) {
            Write-Color cyan "Searching for package '$refPackageName' matching '$searchTerm' via search in feed '$nuGetFeed'..."

            $searchQueryService = $serviceIndex.resources | Where-Object { $_.'@type' -match 'SearchQueryService' } | Select-Object -First 1

            if (-not $searchQueryService) {
                Write-Error "Could not find SearchQueryService endpoint in feed '$nuGetFeed'" -ErrorAction Stop
            }

            $searchUrl = $searchQueryService.'@id'

            $searchParams = @{
                Uri = "$searchUrl`?q=$refPackageName&prerelease=true&take=1"
            }

            $searchResults = Invoke-RestMethod @searchParams

            If (-not $searchResults.data -or $searchResults.data.Count -eq 0) {
                Write-Error "No NuGet packages found with ref package name '$refPackageName' in feed '$nuGetFeed'" -ErrorAction Stop
            }

            $package = $searchResults.data | Where-Object { $_.id -eq $refPackageName } | Select-Object -First 1

            If (-not $package) {
                Write-Error "Package '$refPackageName' not found in search results" -ErrorAction Stop
            }

            # Filter versions matching search term
            $matchingVersions = @($package.versions | Where-Object -Property version -Like $searchTerm | Sort-Object version -Descending)

            If ($matchingVersions.Count -eq 0) {
                Write-Error "No NuGet packages found with search term '$searchTerm'." -ErrorAction Stop
            }

            $version = $matchingVersions[0].version
        }
    }

    $nupkgFile = [IO.Path]::Combine($tmpFolder, "$refPackageName.$version.nupkg")

    If (-Not(Test-Path -Path $nupkgFile)) {
        # Construct download URL using flat2 base URL from the service index
        $pkgIdLower = $refPackageName.ToLower()
        If ($flatBaseUrl) {
            $nupkgUrl = "$flatBaseUrl$pkgIdLower/$version/$pkgIdLower.$version.nupkg"
        }
        Else {
            Write-Error "Could not determine download URL for package '$refPackageName' version '$version'. No PackageBaseAddress endpoint found in feed '$nuGetFeed'." -ErrorAction Stop
        }

        Write-Color yellow "Downloading '$nupkgUrl' to '$nupkgFile'..."
        Invoke-WebRequest -Uri $nupkgUrl -OutFile $nupkgFile
        VerifyPathOrExit $nupkgFile
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

        # Probe the feed for the next version after the latest api-diff
        $next = GetNextVersionFromFeed -majorMinor $latestApiDiff.MajorMinor -prereleaseLabel $latestApiDiff.PrereleaseLabel -feedUrl $DotNetPublicFeedUrl

        If ($next) {
            $CurrentMajorMinor = $next.MajorMinor
            $CurrentPrereleaseLabel = $next.PrereleaseLabel
            $nextDesc = If ($CurrentPrereleaseLabel) { "$CurrentMajorMinor-$CurrentPrereleaseLabel" } Else { "$CurrentMajorMinor GA" }
            Write-Color green "Discovered next version from feed: $nextDesc"
        } Else {
            Write-Error "Could not discover the next version from feed '$DotNetPublicFeedUrl' after $latestDesc. Specify -CurrentMajorMinor and -CurrentPrereleaseLabel explicitly." -ErrorAction Stop
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
    Write-Color cyan "Using default current feed: $CurrentNuGetFeed"
}

If ([System.String]::IsNullOrWhiteSpace($PreviousNuGetFeed)) {
    $PreviousNuGetFeed = $DotNetPublicFeedUrl
    Write-Color cyan "Using default previous feed: $PreviousNuGetFeed"
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

# True when comparing GA releases across major versions
$IsComparingReleases = ($PreviousMajorMinor -Ne $CurrentMajorMinor) -And ($PreviousReleaseKind -Eq "ga") -And ($CurrentReleaseKind -eq "ga")

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

$currentMajorVersion = [int]($CurrentMajorMinor.Split(".")[0])

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

# Always download NETCore packages (needed either for its own diff or as refs for other SDKs)
$netCoreBeforePath = ""
$netCoreAfterPath = ""

DownloadPackage -nuGetFeed $PreviousNuGetFeed -tmpFolder $TmpFolder -sdkName "NETCore" -beforeOrAfter "Before" `
    -dotNetVersion $PreviousMajorMinor -releaseKind $PreviousReleaseKind -previewNumberVersion $PreviousPreviewRCNumber `
    -version $PreviousVersion -resultingPath ([ref]$netCoreBeforePath)
VerifyPathOrExit $netCoreBeforePath

DownloadPackage -nuGetFeed $CurrentNuGetFeed -tmpFolder $TmpFolder -sdkName "NETCore" -beforeOrAfter "After" `
    -dotNetVersion $CurrentMajorMinor -releaseKind $CurrentReleaseKind -previewNumberVersion $CurrentPreviewRCNumber `
    -version $CurrentVersion -resultingPath ([ref]$netCoreAfterPath)
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
}

If (-Not $ExcludeAspNetCore) {
    $aspBeforePath = ""
    DownloadPackage -nuGetFeed $PreviousNuGetFeed -tmpFolder $TmpFolder -sdkName "AspNetCore" -beforeOrAfter "Before" `
        -dotNetVersion $PreviousMajorMinor -releaseKind $PreviousReleaseKind -previewNumberVersion $PreviousPreviewRCNumber `
        -version "" -resultingPath ([ref]$aspBeforePath)
    VerifyPathOrExit $aspBeforePath

    $aspAfterPath = ""
    DownloadPackage -nuGetFeed $CurrentNuGetFeed -tmpFolder $TmpFolder -sdkName "AspNetCore" -beforeOrAfter "After" `
        -dotNetVersion $CurrentMajorMinor -releaseKind $CurrentReleaseKind -previewNumberVersion $CurrentPreviewRCNumber `
        -version "" -resultingPath ([ref]$aspAfterPath)
    VerifyPathOrExit $aspAfterPath

    $sdkEntries += @{
        name = "AspNetCore"
        beforePath = $aspBeforePath
        afterPath = $aspAfterPath
        refBeforePath = $netCoreBeforePath
        refAfterPath = $netCoreAfterPath
    }
}

If (-Not $ExcludeWindowsDesktop) {
    $wdBeforePath = ""
    DownloadPackage -nuGetFeed $PreviousNuGetFeed -tmpFolder $TmpFolder -sdkName "WindowsDesktop" -beforeOrAfter "Before" `
        -dotNetVersion $PreviousMajorMinor -releaseKind $PreviousReleaseKind -previewNumberVersion $PreviousPreviewRCNumber `
        -version "" -resultingPath ([ref]$wdBeforePath)
    VerifyPathOrExit $wdBeforePath

    $wdAfterPath = ""
    DownloadPackage -nuGetFeed $CurrentNuGetFeed -tmpFolder $TmpFolder -sdkName "WindowsDesktop" -beforeOrAfter "After" `
        -dotNetVersion $CurrentMajorMinor -releaseKind $CurrentReleaseKind -previewNumberVersion $CurrentPreviewRCNumber `
        -version "" -resultingPath ([ref]$wdAfterPath)
    VerifyPathOrExit $wdAfterPath

    $sdkEntries += @{
        name = "WindowsDesktop"
        beforePath = $wdBeforePath
        afterPath = $wdAfterPath
        refBeforePath = $netCoreBeforePath
        refAfterPath = $netCoreAfterPath
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
}

ConvertTo-Json $manifest -Depth 4

#####################
### End Execution ###
#####################
