@{
    RootModule           = 'PSLinear.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '40af22af-f469-4d7e-a6fa-4419ae93dbda'
    Author               = 'Stian'
    CompanyName          = 'Community'
    Copyright            = '(c) 2026 Stian. Released under the MIT License.'
    Description          = 'Unofficial PowerShell module for the Linear (linear.app) GraphQL API. Pipeline-friendly cmdlets for issues and teams, with automatic paging, rate-limit handling and an escape hatch for raw GraphQL.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FormatsToProcess     = @('PSLinear.Format.ps1xml')
    FunctionsToExport    = @(
        'Connect-Linear'
        'Disconnect-Linear'
        'Get-LinearIssue'
        'Get-LinearRateLimit'
        'Get-LinearTeam'
        'Get-LinearViewer'
        'Invoke-LinearGraphQL'
        'New-LinearIssue'
        'Set-LinearIssue'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('Linear', 'LinearApp', 'GraphQL', 'IssueTracking', 'ProjectManagement', 'API', 'PSEdition_Core', 'Windows', 'Linux', 'MacOS')
            LicenseUri   = 'https://github.com/stian3555/PSLinear/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/stian3555/PSLinear'
            ReleaseNotes = 'https://github.com/stian3555/PSLinear/blob/main/CHANGELOG.md'
            Prerelease   = 'preview1'
        }
    }
}
