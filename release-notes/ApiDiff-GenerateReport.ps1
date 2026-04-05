# Reads a JSON manifest (from ApiDiff-CollectAssemblies.ps1) and invokes the
# apidiff console tool for each SDK to generate markdown API-diff reports.
# Also creates the summary README.md in the output folder.
#
# This script is one half of the former RunApiDiff.ps1; the other half is
# ApiDiff-CollectAssemblies.ps1.  Use ApiDiff.ps1 to run both steps together.

Param (
    [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
    [string]
    $InputJson
    ,
    [Parameter(Mandatory = $false)]
    [string]
    $InputFile
    ,
    [Parameter(Mandatory = $false)]
    [switch]
    $InstallApiDiff
)

#######################
### Start Functions ###
#######################

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

Function RunApiDiff {
    Param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $apiDiffExe
        ,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $outputFolder
        ,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $beforeFolder
        ,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $afterFolder
        ,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $tableOfContentsFileNamePrefix
        ,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $assembliesToExclude
        ,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $attributesToExclude
        ,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $beforeFriendlyName
        ,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $afterFriendlyName
        ,
        [Parameter(Mandatory = $false)]
        [string]
        $beforeReferenceFolder = ""
        ,
        [Parameter(Mandatory = $false)]
        [string]
        $afterReferenceFolder = ""
    )

    VerifyPathOrExit $apiDiffExe
    VerifyPathOrExit $beforeFolder
    VerifyPathOrExit $afterFolder

    $referenceParams = @()
    if (-not [string]::IsNullOrEmpty($beforeReferenceFolder) -and -not [string]::IsNullOrEmpty($afterReferenceFolder)) {
        VerifyPathOrExit $beforeReferenceFolder
        VerifyPathOrExit $afterReferenceFolder
        $referenceParams = @('-rb', $beforeReferenceFolder, '-ra', $afterReferenceFolder)
    }

    $arguments = @('-b', $beforeFolder, '-a', $afterFolder, '-o', $outputFolder, '-tc', $tableOfContentsFileNamePrefix, '-eas', $assembliesToExclude, '-eattrs', $attributesToExclude, '-bfn', $beforeFriendlyName, '-afn', $afterFriendlyName) + $referenceParams
    Write-Color yellow "& $apiDiffExe $arguments"
    & $apiDiffExe @arguments
}

Function CreateReadme {
    Param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $previewFolderPath
        ,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $dotNetFriendlyName
        ,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $dotNetFullName
        ,
        [Parameter(Mandatory = $true)]
        [string[]]
        $sdkNames
    )

    $readmePath = [IO.Path]::Combine($previewFolderPath, "README.md")
    If (Test-Path -Path $readmePath) {
        Remove-Item -Path $readmePath
    }
    New-Item -ItemType File $readmePath | Out-Null

    Add-Content $readmePath "# $dotNetFriendlyName API Changes"
    Add-Content $readmePath ""
    Add-Content $readmePath "The following API changes were made in $($dotNetFriendlyName):"
    Add-Content $readmePath ""
    ForEach ($sdk in $sdkNames) {
        Add-Content $readmePath "- [Microsoft.$sdk.App](./Microsoft.$sdk.App/$dotNetFullName.md)"
    }
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

## Read JSON manifest
$jsonText = ""

If (-not [System.String]::IsNullOrWhiteSpace($InputFile)) {
    If (-not (Test-Path $InputFile)) {
        Write-Error "Input file '$InputFile' does not exist." -ErrorAction Stop
    }
    $jsonText = Get-Content -Path $InputFile -Raw
}
ElseIf (-not [System.String]::IsNullOrWhiteSpace($InputJson)) {
    $jsonText = $InputJson
}
Else {
    # Try reading from stdin
    $jsonText = @($input) -join "`n"
}

If ([System.String]::IsNullOrWhiteSpace($jsonText)) {
    Write-Error "No JSON manifest provided. Supply via -InputJson, -InputFile, or stdin pipe." -ErrorAction Stop
}

$manifest = $jsonText | ConvertFrom-Json

## Validate required manifest fields
$requiredFields = @('beforeLabel', 'afterLabel', 'tableOfContentsTitle', 'outputPath', 'assembliesToExcludeFilePath', 'attributesToExcludeFilePath', 'currentMajorVersion', 'sdks')
ForEach ($field in $requiredFields) {
    If (-not ($manifest.PSObject.Properties.Name -contains $field)) {
        Write-Error "Manifest is missing required field '$field'." -ErrorAction Stop
    }
}

If ($manifest.sdks.Count -eq 0) {
    Write-Error "Manifest contains no SDK entries." -ErrorAction Stop
}

$outputPath = $manifest.outputPath
$beforeLabel = $manifest.beforeLabel
$afterLabel = $manifest.afterLabel
$tableOfContentsTitle = $manifest.tableOfContentsTitle
$assembliesToExclude = $manifest.assembliesToExcludeFilePath
$attributesToExclude = $manifest.attributesToExcludeFilePath
$currentMajorVersion = $manifest.currentMajorVersion

VerifyPathOrExit $outputPath
VerifyPathOrExit $assembliesToExclude
VerifyPathOrExit $attributesToExclude

## Install or verify the apidiff tool
$transportFeedUrl = "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet${currentMajorVersion}-transport/nuget/v3/index.json"
$InstallApiDiffCommand = "dotnet tool install --global Microsoft.DotNet.ApiDiff.Tool --source $transportFeedUrl --prerelease"

if ($InstallApiDiff) {
    Write-Color white "Installing ApiDiff tool..."
    Write-Color yellow $InstallApiDiffCommand
    & dotnet tool install --global Microsoft.DotNet.ApiDiff.Tool --source $transportFeedUrl --prerelease
}

$apiDiffCommand = get-command "apidiff" -ErrorAction SilentlyContinue

if (-Not $apiDiffCommand) {
    Write-Error "The command apidiff could not be found.  Please first install the tool using the following command: $InstallApiDiffCommand" -ErrorAction Stop
}

$apiDiffExe = $apiDiffCommand.Source

## Process each SDK
ForEach ($sdk in $manifest.sdks) {
    $sdkName = $sdk.name
    Write-Color white "Processing SDK: Microsoft.$sdkName.App"

    VerifyPathOrExit $sdk.beforePath
    VerifyPathOrExit $sdk.afterPath

    $targetFolder = [IO.Path]::Combine($outputPath, "Microsoft.$sdkName.App")
    RecreateFolder $targetFolder

    $refBefore = If ($sdk.refBeforePath) { $sdk.refBeforePath } Else { "" }
    $refAfter = If ($sdk.refAfterPath) { $sdk.refAfterPath } Else { "" }

    RunApiDiff `
        -apiDiffExe $apiDiffExe `
        -outputFolder $targetFolder `
        -beforeFolder $sdk.beforePath `
        -afterFolder $sdk.afterPath `
        -tableOfContentsFileNamePrefix $tableOfContentsTitle `
        -assembliesToExclude $assembliesToExclude `
        -attributesToExclude $attributesToExclude `
        -beforeFriendlyName $beforeLabel `
        -afterFriendlyName $afterLabel `
        -beforeReferenceFolder $refBefore `
        -afterReferenceFolder $refAfter
}

## Create summary README
$sdkNames = @($manifest.sdks | ForEach-Object { $_.name })

CreateReadme -previewFolderPath $outputPath -dotNetFriendlyName $afterLabel -dotNetFullName $tableOfContentsTitle -sdkNames $sdkNames

Write-Color green "API diff report generation complete. Output: $outputPath"

#####################
### End Execution ###
#####################
