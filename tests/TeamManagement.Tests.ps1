BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Team management commands' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $request = Get-RequestBody -Body $Body
            $lookup = Get-LinearTestLookupResponse -Request $request
            if ($lookup) { return $lookup }
            Get-LinearTestManagementResponse -Request $request
        }
    }

    Context 'New-LinearTeam' {
        It 'creates a team with key, description, parent and time zone' {
            $team = New-LinearTeam 'Mobile' -Key mob -Description 'Apps' -Parent ENG -Timezone 'Europe/Oslo'
            $team.PSObject.TypeNames | Should -Contain 'PSLinear.Team'
            $team.Key | Should -Be 'MOB'
            $team.Parent | Should -Be 'ENG'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateTeam' -and
                (Get-RequestVariable $Body 'input.name') -eq 'Mobile' -and
                (Get-RequestVariable $Body 'input.key') -eq 'MOB' -and
                (Get-RequestVariable $Body 'input.description') -eq 'Apps' -and
                (Get-RequestVariable $Body 'input.parentId') -eq 'team-eng' -and
                (Get-RequestVariable $Body 'input.timezone') -eq 'Europe/Oslo'
            }
        }

        It 'sends only the name when nothing else is given, and forgets the cached teams' {
            InModuleScope PSLinear { $null = Get-LinearTeamCache }
            $null = New-LinearTeam 'Plain'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateTeam' -and (@((Get-RequestBody $Body).variables.input.Keys) -join ',') -eq 'name'
            }
            InModuleScope PSLinear { $script:LinearTeamCache } | Should -BeNullOrEmpty
        }

        It 'rejects an invalid key and sends nothing with -WhatIf' {
            { New-LinearTeam 'Bad' -Key 'EN-G' } | Should -Throw -ExpectedMessage "*'EN-G' is not a team key*"
            New-LinearTeam 'Never' -Parent ENG -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'stops for an unknown parent, and writes one error when Linear rejects the team' {
            { New-LinearTeam 'Bad' -Parent NOPE } | Should -Throw -ErrorId 'PSLinear.TeamNotFound*'
            New-LinearTeam 'reject' -ErrorAction SilentlyContinue -ErrorVariable teamErrors | Should -BeNullOrEmpty
            $teamErrors.Count | Should -Be 1
            $teamErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.TeamCreateFailed*'
        }
    }

    Context 'Set-LinearTeam' {
        It 'changes a team by key and returns nothing' {
            Set-LinearTeam ENG -Name 'Product' -Key prod -Description '' -Timezone 'Europe/Oslo' | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateTeam' -and
                (Get-RequestVariable $Body 'id') -eq 'team-eng' -and
                (Get-RequestVariable $Body 'input.name') -eq 'Product' -and
                (Get-RequestVariable $Body 'input.key') -eq 'PROD' -and
                (Get-RequestVariable $Body 'input.description') -eq '' -and
                (Get-RequestVariable $Body 'input.timezone') -eq 'Europe/Oslo'
            }
        }

        It 'sets or clears the parent, and returns the team with -PassThru' {
            (Set-LinearTeam OPS -Parent ENG -PassThru).Parent | Should -Be 'ENG'
            Set-LinearTeam OPS -Clear Parent
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $teamInput = (Get-RequestBody $Body).variables['input']
                (Get-RequestOperation $Body) -eq 'UpdateTeam' -and $teamInput.Contains('parentId') -and $null -eq $teamInput['parentId']
            }
        }

        It 'updates piped teams and forgets their cached data' {
            InModuleScope PSLinear { $null = Get-LinearLabelCache -TeamId 'team-eng'; $null = Get-LinearTeamCache }
            Get-LinearTeam | Set-LinearTeam -Description 'Same for all'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateTeam' }
            InModuleScope PSLinear { $script:LinearLabelCache.ContainsKey('team-eng') } | Should -BeFalse
        }

        It 'rejects conflicting parameters, or no change, before sending anything' {
            { Set-LinearTeam ENG -Parent OPS -Clear Parent } | Should -Throw -ExpectedMessage 'Use either -Clear Parent or -Parent, not both.'
            { Set-LinearTeam ENG } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            Set-LinearTeam ENG -Name x -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'stops for an unknown team, and writes one error for a team Linear cannot update' {
            { Set-LinearTeam NOPE -Name x } | Should -Throw -ErrorId 'PSLinear.TeamNotFound*'
            Set-LinearTeam '00000000-0000-4000-8000-000000000000', ENG -Name x -ErrorAction SilentlyContinue -ErrorVariable teamErrors
            $teamErrors.Count | Should -Be 1
            $teamErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.TeamUpdateFailed*'
        }
    }

    Context 'Remove-LinearTeam' {
        It 'deletes teams by key and piped, forgetting the cached teams' {
            InModuleScope PSLinear { $null = Get-LinearTeamCache }
            Remove-LinearTeam OPS -Confirm:$false | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'DeleteTeam' -and (Get-RequestVariable $Body 'id') -eq 'team-ops'
            }
            InModuleScope PSLinear { $script:LinearTeamCache } | Should -BeNullOrEmpty
            Get-LinearTeam -Name ENG | Remove-LinearTeam -Confirm:$false
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'DeleteTeam' -and (Get-RequestVariable $Body 'id') -eq 'team-eng'
            }
        }

        It 'writes one error for a team Linear cannot delete, and sends nothing with -WhatIf' {
            Remove-LinearTeam '00000000-0000-4000-8000-000000000000' -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable teamErrors
            $teamErrors.Count | Should -Be 1
            $teamErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.TeamDeleteFailed*'
            Remove-LinearTeam ENG -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'DeleteTeam' -and (Get-RequestVariable $Body 'id') -eq 'team-eng'
            }
        }
    }

    Context 'Get-LinearTeamMember' {
        It 'lists a team''s members sorted by name, with ownership' {
            $members = @(Get-LinearTeamMember ENG)
            $members.Name | Should -Be @('Ada Lovelace', 'Grace Hopper')
            $members[0].PSObject.TypeNames | Should -Contain 'PSLinear.TeamMember'
            $members[0].Owner | Should -BeTrue
            $members[1].Owner | Should -BeFalse
            $members[0].Team | Should -Be 'ENG'
            $members[0].UserId | Should -Be 'user-ada'
            $members[0].MembershipId | Should -Be 'membership-eng-ada'
        }

        It 'takes teams from the pipeline, by key and as strings' {
            @(Get-LinearTeam | Get-LinearTeamMember).Count | Should -Be 3
            @('OPS' | Get-LinearTeamMember).Name | Should -Be @('Grace Hopper')
        }

        It 'filters by user and writes one error for someone who is not a member' {
            $members = @(Get-LinearTeamMember OPS -User grace, me -ErrorAction SilentlyContinue -ErrorVariable memberErrors)
            $members.Name | Should -Be @('Grace Hopper')
            $memberErrors.Count | Should -Be 1
            $memberErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.TeamMemberNotFound*'
        }

        It 'stops for an unknown team or user' {
            { Get-LinearTeamMember NOPE } | Should -Throw -ErrorId 'PSLinear.TeamNotFound*'
            { Get-LinearTeamMember ENG -User Nobody } | Should -Throw -ErrorId 'PSLinear.UserNotFound*'
        }
    }

    Context 'Add-LinearTeamMember' {
        It 'adds users and returns the memberships, skipping members with a warning' {
            $added = @(Add-LinearTeamMember OPS -User me, grace -WarningVariable memberWarnings -WarningAction SilentlyContinue)
            $added.Name | Should -Be @('Ada Lovelace')
            $added[0].PSObject.TypeNames | Should -Contain 'PSLinear.TeamMember'
            $memberWarnings.Count | Should -Be 1
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateTeamMembership' -and
                (Get-RequestVariable $Body 'input.teamId') -eq 'team-ops' -and (Get-RequestVariable $Body 'input.userId') -eq 'user-ada'
            }
        }

        It 'takes teams from the pipeline' {
            Get-LinearTeam -Name OPS | Add-LinearTeamMember -User alex.one@example.com | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateTeamMembership' -and (Get-RequestVariable $Body 'input.userId') -eq 'user-alex-1'
            }
        }

        It 'writes one error for a user Linear will not add and goes on' {
            $added = @(Add-LinearTeamMember OPS -User alex.two@example.com, me -ErrorAction SilentlyContinue -ErrorVariable memberErrors)
            $added.Name | Should -Be @('Ada Lovelace')
            $memberErrors.Count | Should -Be 1
            $memberErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.TeamMemberAddFailed*'
        }

        It 'sends nothing with -WhatIf' {
            Add-LinearTeamMember OPS -User me -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Remove-LinearTeamMember' {
        It 'removes users by team and user, through their membership' {
            Remove-LinearTeamMember ENG -User grace -Confirm:$false | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'DeleteTeamMembership' -and (Get-RequestVariable $Body 'id') -eq 'membership-eng-grace'
            }
        }

        It 'removes piped members without looking them up' {
            Get-LinearTeamMember ENG | Remove-LinearTeamMember -Confirm:$false
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'DeleteTeamMembership' }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ListTeamMemberships' }
        }

        It 'writes one error for a user who is not a member and goes on' {
            Remove-LinearTeamMember OPS -User me, grace -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable memberErrors
            $memberErrors.Count | Should -Be 1
            $memberErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.TeamMemberNotFound*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'DeleteTeamMembership' }
        }

        It 'sends nothing with -WhatIf' {
            Remove-LinearTeamMember ENG -User grace -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }
}
