BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Get-LinearCycle' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestLookupResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    It 'lists the cycles of every team, sorted by team and number, in one request' {
        $cycles = @(Get-LinearCycle)
        ($cycles | ForEach-Object { '{0}-{1}' -f $_.Team, $_.Number }) | Should -Be @('ENG-10', 'ENG-11', 'ENG-12', 'ENG-13', 'OPS-3')
        $cycles[0].PSObject.TypeNames | Should -Contain 'PSLinear.Cycle'
        $cycles[0].Number | Should -BeOfType [int]
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            $request = Get-RequestBody $Body
            (Get-RequestOperation $Body) -eq 'ListCycles' -and -not $request.variables.ContainsKey('filter')
        }
    }

    It 'gives each cycle a status' {
        (Get-LinearCycle -Team ENG | ForEach-Object Status) | Should -Be @('Past', 'Previous', 'Active', 'Next')
    }

    It 'filters by team' {
        @(Get-LinearCycle -Team OPS).Id | Should -Be @('cycle-ops-3')
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
            (Get-RequestBody $Body).variables.filter.team.id.eq -eq 'team-ops'
        }
    }

    It 'combines -Previous, -Active and -Next with OR' {
        @(Get-LinearCycle -Team ENG -Previous -Active -Next).Number | Should -Be @(11, 12, 13)
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
            $filter = (Get-RequestBody $Body).variables.filter
            $null -ne $filter -and $filter.or.Count -eq 3
        }
    }

    It 'returns the active cycle of every team' {
        @(Get-LinearCycle -Active).Id | Should -Be @('cycle-eng-12', 'cycle-ops-3')
    }

    It 'filters by number' {
        @(Get-LinearCycle -Team ENG -Number 10, 13).Id | Should -Be @('cycle-eng-10', 'cycle-eng-13')
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
            ((Get-RequestBody $Body).variables.filter.number.in -join ',') -eq '10,13'
        }
    }

    It 'takes teams from the pipeline' {
        $team = [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-ops'; Key = 'OPS'; Name = 'Operations' }
        @($team | Get-LinearCycle).Id | Should -Be @('cycle-ops-3')
    }

    It 'stops on an unknown team' {
        { Get-LinearCycle -Team NOPE } | Should -Throw -ErrorId 'PSLinear.TeamNotFound*'
    }
}
