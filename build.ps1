#Requires -Version 7.4
<#
.SYNOPSIS
    Builds, analyzes, tests and publishes the PSLinear module.

.DESCRIPTION
    Build    Creates output/PSLinear with a single merged PSLinear.psm1 (faster import).
    Analyze  Runs PSScriptAnalyzer with PSScriptAnalyzerSettings.psd1. Fails on any finding.
    Test     Runs the Pester suite against the built module and writes output/testResults.xml.
    Publish  Publishes output/PSLinear to the PowerShell Gallery.

.PARAMETER Task
    One or more tasks, run in the order given. Defaults to Build, Analyze, Test.

.PARAMETER Bootstrap
    Installs Pester and PSScriptAnalyzer for the current user when they are missing.

.PARAMETER ApiKey
    PowerShell Gallery API key for Publish. Defaults to $env:PSGALLERY_API_KEY.

.EXAMPLE
    ./build.ps1

    Builds, analyzes and tests.

.EXAMPLE
    ./build.ps1 -Task Build, Test -Bootstrap

    Installs missing tools, then builds and tests (as CI does).
#>
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Used by the task functions defined in this script.')]
[CmdletBinding()]
param(
    [ValidateSet('Build', 'Analyze', 'Test', 'Publish')]
    [string[]] $Task = @('Build', 'Analyze', 'Test'),

    [switch] $Bootstrap,

    [string] $ApiKey = $env:PSGALLERY_API_KEY
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$moduleName = 'PSLinear'
$sourcePath = Join-Path $PSScriptRoot 'src'
$outputRoot = Join-Path $PSScriptRoot 'output'
$outputPath = Join-Path $outputRoot $moduleName
$manifestPath = Join-Path $sourcePath "$moduleName.psd1"

$requiredModules = @{
    Pester           = [version]'5.5.0'
    PSScriptAnalyzer = [version]'1.22.0'
}

function Write-Step([string] $Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Assert-Tool([string] $Name) {
    $minimum = $requiredModules[$Name]
    $available = Get-Module -ListAvailable -Name $Name | Where-Object Version -GE $minimum | Sort-Object Version -Descending | Select-Object -First 1
    if ($available) { return }
    if (-not $Bootstrap) {
        throw "$Name $minimum or newer is required. Run ./build.ps1 -Bootstrap or: Install-PSResource $Name -Scope CurrentUser"
    }
    Write-Step "Installing $Name"
    Install-PSResource -Name $Name -Version "[$minimum,)" -Scope CurrentUser -TrustRepository -Quiet
}

function Invoke-Build {
    Write-Step 'Building module'
    if (Test-Path $outputRoot) { Remove-Item $outputRoot -Recurse -Force }
    $null = New-Item -Path $outputPath -ItemType Directory -Force

    Copy-Item -Path $manifestPath, (Join-Path $sourcePath "$moduleName.Format.ps1xml") -Destination $outputPath
    Copy-Item -Path (Join-Path $sourcePath 'GraphQL') -Destination $outputPath -Recurse
    Copy-Item -Path (Join-Path $PSScriptRoot 'LICENSE'), (Join-Path $PSScriptRoot 'README.md') -Destination $outputPath

    # Inline every function into one psm1, replacing the dot-sourcing region.
    $functionSource = foreach ($folder in 'Private', 'Public') {
        foreach ($file in Get-ChildItem -Path (Join-Path $sourcePath $folder) -Filter '*.ps1' | Sort-Object Name) {
            "# region $folder/$($file.Name)"
            (Get-Content -LiteralPath $file.FullName -Raw).TrimEnd()
            "# endregion $folder/$($file.Name)"
            ''
        }
    }
    $rootModule = Get-Content -LiteralPath (Join-Path $sourcePath "$moduleName.psm1") -Raw
    $pattern = '(?s)#region Functions.*?#endregion Functions'
    if ($rootModule -notmatch $pattern) { throw "Could not find the '#region Functions' block in $moduleName.psm1." }
    $merged = [regex]::Replace($rootModule, $pattern, { param($m) $null = $m; ($functionSource -join "`n").TrimEnd() })
    Set-Content -LiteralPath (Join-Path $outputPath "$moduleName.psm1") -Value $merged -Encoding utf8NoBOM

    $manifest = Test-ModuleManifest -Path (Join-Path $outputPath "$moduleName.psd1")
    $prerelease = $manifest.PrivateData.PSData.Prerelease
    $version = if ($prerelease) { "$($manifest.Version)-$prerelease" } else { "$($manifest.Version)" }
    Write-Host "    Built $moduleName $version -> $outputPath"
}

function Invoke-Analyze {
    Assert-Tool 'PSScriptAnalyzer'
    Import-Module PSScriptAnalyzer -MinimumVersion $requiredModules.PSScriptAnalyzer
    Write-Step 'Running PSScriptAnalyzer'
    $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
    $findings = @(Invoke-ScriptAnalyzer -Path $sourcePath -Recurse -Settings $settings)
    $findings += @(Invoke-ScriptAnalyzer -Path (Join-Path $PSScriptRoot 'build.ps1') -Settings $settings)
    if ($findings.Count -gt 0) {
        $findings | Format-Table -AutoSize Severity, RuleName, ScriptName, Line, Message | Out-String -Width 200 | Write-Host
        throw "PSScriptAnalyzer reported $($findings.Count) finding(s)."
    }
    Write-Host '    No findings.'
}

function Invoke-Test {
    Assert-Tool 'Pester'
    Import-Module Pester -MinimumVersion $requiredModules.Pester
    $builtManifest = Join-Path $outputPath "$moduleName.psd1"
    if (-not (Test-Path $builtManifest)) { throw 'Run the Build task before Test.' }

    Write-Step 'Running Pester tests against the built module'
    $env:PSLINEAR_TEST_MODULE = $builtManifest
    try {
        $configuration = New-PesterConfiguration
        $configuration.Run.Path = Join-Path $PSScriptRoot 'tests'
        $configuration.Run.Exit = $false
        $configuration.Run.PassThru = $true
        $configuration.Output.Verbosity = 'Detailed'
        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = 'NUnitXml'
        $configuration.TestResult.OutputPath = Join-Path $outputRoot 'testResults.xml'
        $result = Invoke-Pester -Configuration $configuration
    }
    finally {
        Remove-Item Env:\PSLINEAR_TEST_MODULE -ErrorAction SilentlyContinue
    }
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') {
        throw "$($result.FailedCount) test(s) failed."
    }
}

function Invoke-Publish {
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw 'Publishing needs a PowerShell Gallery API key: pass -ApiKey or set PSGALLERY_API_KEY.'
    }
    $builtManifest = Join-Path $outputPath "$moduleName.psd1"
    if (-not (Test-Path $builtManifest)) { throw 'Run the Build task before Publish.' }

    $psData = (Import-PowerShellDataFile $builtManifest).PrivateData.PSData
    foreach ($uri in $psData.ProjectUri, $psData.LicenseUri, $psData.ReleaseNotes) {
        if ($uri -match '/OWNER/') {
            throw "The manifest still contains the placeholder 'OWNER' ($uri). Replace it with your GitHub user or organization."
        }
    }

    Write-Step 'Publishing to the PowerShell Gallery'
    Publish-PSResource -Path $outputPath -Repository PSGallery -ApiKey $ApiKey
    Write-Host '    Published.'
}

foreach ($step in $Task) {
    switch ($step) {
        'Build' { Invoke-Build }
        'Analyze' { Invoke-Analyze }
        'Test' { Invoke-Test }
        'Publish' { Invoke-Publish }
    }
}
