BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Get-LinearTeam' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
            Clear-LinearCache
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            New-LinearTestResponse -Data @{
                teams = (New-LinearTestConnection -Nodes @(
                        (New-LinearTestTeamNode -Key 'ENG' -Name 'Engineering' -Id 'team-eng'),
                        (New-LinearTestTeamNode -Key 'PLAT' -Name 'Platform' -Id 'team-plat'),
                        (New-LinearTestTeamNode -Key 'OPS' -Name 'Operations' -Id 'team-ops')
                    ))
            }
        }
    }

    It 'lists all teams as typed objects' {
        $teams = @(Get-LinearTeam)
        $teams.Count | Should -Be 3
        $teams[0].PSObject.TypeNames | Should -Contain 'PSLinear.Team'
        $teams.Key | Should -Be @('ENG', 'PLAT', 'OPS')
    }

    It 'filters by key, name and wildcard' {
        (Get-LinearTeam -Name 'eng').Key | Should -Be 'ENG'
        (Get-LinearTeam -Name 'Operations').Key | Should -Be 'OPS'
        (Get-LinearTeam -Name 'P*').Key | Should -Be 'PLAT'
    }

    It 'accepts names from the pipeline with a single request' {
        ('ENG', 'OPS' | Get-LinearTeam).Key | Should -Be @('ENG', 'OPS')
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
    }

    It 'writes an error for a team that does not exist' {
        $result = Get-LinearTeam -Name 'NOPE' -ErrorAction SilentlyContinue -ErrorVariable teamErrors
        $result | Should -BeNullOrEmpty
        $teamErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.TeamNotFound*'
    }

    It 'does not error when a wildcard matches nothing' {
        Get-LinearTeam -Name 'ZZ*' -ErrorVariable teamErrors
        $teamErrors | Should -BeNullOrEmpty
    }

    It 'refreshes the cache used for team name resolution' {
        Get-LinearTeam | Out-Null
        InModuleScope PSLinear { Resolve-LinearTeamId -Team 'Platform' } | Should -Be 'team-plat'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
    }

    It 'asks for archived teams with -IncludeArchived' {
        Get-LinearTeam -IncludeArchived | Out-Null
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter { (Get-RequestBody $Body).variables.includeArchived -eq $true }
    }
}

Describe 'Team tab completion' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
            $script:LinearTeamCache = @(
                [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-eng'; Key = 'ENG'; Name = 'Engineering' }
                [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-ops'; Key = 'OPS'; Name = 'Operations' }
            )
            $script:LinearTeamCacheExpires = [datetime]::UtcNow.AddMinutes(10)
        }
    }

    It 'completes team keys' {
        $line = 'Get-LinearIssue -Team E'
        $completions = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $completions.CompletionMatches.CompletionText | Should -Be @('ENG')
    }

    It 'returns nothing (and does not throw) when not connected' {
        InModuleScope PSLinear { $script:LinearContext = $null }
        $env:LINEAR_API_KEY = $null
        $line = 'Get-LinearIssue -Team E'
        $completions = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $completions.CompletionMatches | Should -BeNullOrEmpty
    }
}
