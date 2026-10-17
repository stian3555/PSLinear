BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Get-LinearProject' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestLookupResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    It 'lists the projects as typed objects, sorted by name' {
        $projects = @(Get-LinearProject)
        $projects.Name | Should -Be @('Mobile App', 'Website')
        $website = $projects[1]
        $website.PSObject.TypeNames | Should -Contain 'PSLinear.Project'
        $website.Status | Should -Be 'In Progress'
        $website.Lead | Should -Be 'Grace Hopper'
        $website.LeadId | Should -Be 'user-grace'
        $website.Progress | Should -Be 0.5
        $website.TargetDate | Should -Be '2026-12-01'
        $projects[0].Lead | Should -BeNullOrEmpty
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            (Get-RequestBody $Body).variables.includeArchived -eq $false
        }
    }

    It 'includes archived projects with -IncludeArchived' {
        $legacy = Get-LinearProject -IncludeArchived | Where-Object Name -EQ 'Legacy'
        $legacy.ArchivedAt | Should -Not -BeNullOrEmpty
    }

    It 'filters by name with wildcards and reports names that match nothing' {
        (Get-LinearProject -Name 'web*').Id | Should -Be 'project-web'
        $projects = @(Get-LinearProject -Name 'Website', 'Intranet' -ErrorAction SilentlyContinue -ErrorVariable projectErrors)
        $projects.Id | Should -Be @('project-web')
        $projectErrors.Count | Should -Be 1
        $projectErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.ProjectNotFound*'
    }

    It 'accepts names from the pipeline and fetches the projects once' {
        @('Website', 'Mobile App' | Get-LinearProject).Id | Should -Be @('project-web', 'project-mobile')
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
    }
}
