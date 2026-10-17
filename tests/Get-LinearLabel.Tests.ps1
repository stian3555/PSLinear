BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Get-LinearLabel' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestLookupResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    It 'lists every label in the workspace, without groups or retired labels' {
        $labels = @(Get-LinearLabel)
        $labels.Name | Should -Be @('Backend', 'Bug', 'Feature', 'Frontend', 'Frontend', 'Incident')
        $labels[0].PSObject.TypeNames | Should -Contain 'PSLinear.Label'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            -not (Get-RequestBody $Body).ContainsKey('variables') -or -not (Get-RequestBody $Body).variables.ContainsKey('filter')
        }
    }

    It 'shows the group and team of each label' {
        $frontend = @(Get-LinearLabel -Name Frontend)
        ($frontend | Where-Object Id -EQ 'label-frontend').Group | Should -Be 'Area'
        ($frontend | Where-Object Id -EQ 'label-ops-frontend').Team | Should -Be 'OPS'
    }

    It 'lists the labels a team can use with -Team' {
        @(Get-LinearLabel -Team ENG).Name | Should -Be @('Backend', 'Bug', 'Feature', 'Frontend')
    }

    It 'takes teams from the pipeline' {
        $team = [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-ops'; Key = 'OPS'; Name = 'Operations' }
        @($team | Get-LinearLabel -Name Incident).Id | Should -Be @('label-ops-incident')
    }

    It 'accepts names from the pipeline and fetches the labels once' {
        @('Bug', 'Backend' | Get-LinearLabel).Id | Should -Be @('label-bug', 'label-eng-backend')
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
    }

    It 'writes a non-terminating error for a name that matches no label' {
        $labels = @(Get-LinearLabel -Name 'Bug', 'Nope' -ErrorAction SilentlyContinue -ErrorVariable labelErrors)
        $labels.Id | Should -Be @('label-bug')
        $labelErrors.Count | Should -Be 1
        $labelErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.LabelNotFound*'
    }

    It 'stops on an unknown team' {
        { Get-LinearLabel -Team NOPE } | Should -Throw -ErrorId 'PSLinear.TeamNotFound*'
    }
}
