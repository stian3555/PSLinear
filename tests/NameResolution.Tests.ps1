BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Name resolution' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestLookupResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    Context 'Teams' {
        It 'throws a TeamNotFound error that lists the team keys' {
            { InModuleScope PSLinear { Resolve-LinearTeamId -Team 'NOPE' } } |
                Should -Throw -ErrorId 'PSLinear.TeamNotFound*' -ExpectedMessage "*Team 'NOPE' was not found. Available team keys: ENG, OPS.*"
        }
    }

    Context 'Workflow states' {
        It 'resolves a state name within the team, case-insensitively' {
            InModuleScope PSLinear { Resolve-LinearWorkflowStateId -TeamId 'team-eng' -State 'in progress' } | Should -Be 'state-eng-progress'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                $request.query -match 'query ListWorkflowStates' -and $request.variables.filter.team.id.eq -eq 'team-eng'
            }
        }

        It 'only matches states of the given team' {
            InModuleScope PSLinear { Resolve-LinearWorkflowStateId -TeamId 'team-ops' -State 'Doing' } | Should -Be 'state-ops-doing'
            { InModuleScope PSLinear { Resolve-LinearWorkflowStateId -TeamId 'team-eng' -State 'Doing' } } | Should -Throw -ErrorId 'PSLinear.StateNotFound*'
        }

        It 'caches states per team' {
            InModuleScope PSLinear {
                Resolve-LinearWorkflowStateId -TeamId 'team-eng' -State 'Todo'
                Resolve-LinearWorkflowStateId -TeamId 'team-eng' -State 'Done'
                Resolve-LinearWorkflowStateId -TeamId 'team-ops' -State 'Done'
            } | Should -Be @('state-eng-todo', 'state-eng-done', 'state-ops-done')
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly
        }

        It 'refreshes the cache when a name is missing, so new states are found' {
            InModuleScope PSLinear {
                $script:LinearWorkflowStateCache['team-eng'] = @{
                    Items   = @([pscustomobject]@{ PSTypeName = 'PSLinear.WorkflowState'; Id = 'state-eng-todo'; Name = 'Todo'; Type = 'unstarted' })
                    Expires = [datetime]::UtcNow.AddMinutes(10)
                }
                Resolve-LinearWorkflowStateId -TeamId 'team-eng' -State 'In Progress'
            } | Should -Be 'state-eng-progress'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
        }

        It 'lists the valid states in workflow order for an unknown name' {
            { InModuleScope PSLinear { Resolve-LinearWorkflowStateId -TeamId 'team-eng' -State 'Doen' } } |
                Should -Throw -ErrorId 'PSLinear.StateNotFound*' -ExpectedMessage "State 'Doen' was not found in team ENG. Valid states: Backlog, Todo, In Progress, In Review, Done, Canceled, Duplicate; state types: backlog, unstarted, started, completed, canceled, duplicate."
        }

        It 'resolves a state type to the team''s first state of that type' {
            InModuleScope PSLinear {
                Resolve-LinearWorkflowStateId -TeamId 'team-eng' -State 'Started'
                Resolve-LinearWorkflowStateId -TeamId 'team-eng' -State 'completed'
                Resolve-LinearWorkflowStateId -TeamId 'team-ops' -State 'started'
            } | Should -Be @('state-eng-progress', 'state-eng-done', 'state-ops-doing')
        }

        It 'prefers a state name over a state type' {
            InModuleScope PSLinear {
                $script:LinearWorkflowStateCache['team-eng'] = @{
                    Items   = @(
                        [pscustomobject]@{ PSTypeName = 'PSLinear.WorkflowState'; Id = 'state-named-started'; Name = 'Started'; Type = 'unstarted'; Position = 0 }
                        [pscustomobject]@{ PSTypeName = 'PSLinear.WorkflowState'; Id = 'state-doing'; Name = 'Doing'; Type = 'started'; Position = 1 }
                    )
                    Expires = [datetime]::UtcNow.AddMinutes(10)
                }
                Resolve-LinearWorkflowStateId -TeamId 'team-eng' -State 'started'
            } | Should -Be 'state-named-started'
        }

        It 'accepts a state id without a lookup' {
            $stateId = [guid]::NewGuid().Guid
            InModuleScope PSLinear -Parameters @{ StateId = $stateId } {
                param($StateId)
                Resolve-LinearWorkflowStateId -TeamId 'team-eng' -State $StateId
            } | Should -Be $stateId
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Labels' {
        It 'resolves workspace labels and the team''s own labels, case-insensitively' {
            InModuleScope PSLinear { Resolve-LinearLabelId -TeamId 'team-eng' -Label 'bug', 'Backend', 'Frontend' } |
                Should -Be @('label-bug', 'label-eng-backend', 'label-frontend')
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $filter = (Get-RequestBody $Body).variables.filter
                $filter.or[0].team.null -eq $true -and $filter.or[1].team.id.eq -eq 'team-eng'
            }
        }

        It 'does not offer label groups, retired labels or other teams'' labels' {
            foreach ($name in 'Area', 'Old', 'Incident') {
                { InModuleScope PSLinear -Parameters @{ Name = $name } { param($Name) Resolve-LinearLabelId -TeamId 'team-eng' -Label $Name } } |
                    Should -Throw -ErrorId 'PSLinear.LabelNotFound*' -ExpectedMessage "*was not found in team ENG. Valid labels: Backend, Bug, Feature, Frontend."
            }
        }

        It 'reports an ambiguous label with its group and team' {
            { InModuleScope PSLinear { Resolve-LinearLabelId -TeamId 'team-ops' -Label 'Frontend' } } |
                Should -Throw -ErrorId 'PSLinear.AmbiguousLabel*' -ExpectedMessage '*Area/Frontend (workspace, id label-frontend)*Frontend (team OPS, id label-ops-frontend)*'
        }

        It 'accepts label ids without a lookup' {
            $labelId = [guid]::NewGuid().Guid
            InModuleScope PSLinear -Parameters @{ LabelId = $labelId } {
                param($LabelId)
                Resolve-LinearLabelId -TeamId 'team-eng' -Label $LabelId
            } | Should -Be $labelId
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Users' {
        It 'resolves me from the connection without a request' {
            InModuleScope PSLinear {
                $script:LinearContext.UserId = 'user-known'
                Resolve-LinearUserId -User 'me'
            } | Should -Be 'user-known'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'asks Linear for the viewer once when the connection does not know the user' {
            InModuleScope PSLinear {
                Resolve-LinearUserId -User 'me'
                Resolve-LinearUserId -User 'me'
                $script:LinearContext.UserId
            } | Should -Be @('user-ada', 'user-ada', 'user-ada')
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestBody $Body).query -match 'query Viewer'
            }
        }

        It 'resolves an email address, full name or display name, case-insensitively' {
            InModuleScope PSLinear {
                Resolve-LinearUserId -User 'GRACE@example.com'
                Resolve-LinearUserId -User 'grace hopper'
                Resolve-LinearUserId -User 'grace'
            } | Should -Be @('user-grace', 'user-grace', 'user-grace')
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
        }

        It 'reports an ambiguous name with the matching email addresses' {
            { InModuleScope PSLinear { Resolve-LinearUserId -User 'Alex Smith' } } |
                Should -Throw -ErrorId 'PSLinear.AmbiguousUser*' -ExpectedMessage '*Alex Smith <alex.one@example.com>, Alex Smith <alex.two@example.com>*'
        }

        It 'lists the valid users for an unknown name' {
            { InModuleScope PSLinear { Resolve-LinearUserId -User 'Linus' } } |
                Should -Throw -ErrorId 'PSLinear.UserNotFound*' -ExpectedMessage '*Valid users: Ada Lovelace <ada@example.com>, Alex Smith*Grace Hopper <grace@example.com>.'
        }

        It 'accepts a user id without a lookup' {
            $userId = [guid]::NewGuid().Guid
            InModuleScope PSLinear -Parameters @{ UserId = $userId } { param($UserId) Resolve-LinearUserId -User $UserId } | Should -Be $userId
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Projects' {
        It 'resolves a project name, case-insensitively' {
            InModuleScope PSLinear { Resolve-LinearProjectId -Project 'mobile app' } | Should -Be 'project-mobile'
        }

        It 'lists the valid projects for an unknown name' {
            { InModuleScope PSLinear { Resolve-LinearProjectId -Project 'Intranet' } } |
                Should -Throw -ErrorId 'PSLinear.ProjectNotFound*' -ExpectedMessage "Project 'Intranet' was not found. Valid projects: Mobile App, Website."
        }

        It 'accepts a project id without a lookup' {
            $projectId = [guid]::NewGuid().Guid
            InModuleScope PSLinear -Parameters @{ ProjectId = $projectId } { param($ProjectId) Resolve-LinearProjectId -Project $ProjectId } | Should -Be $projectId
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Valid value lists' {
        It 'lists at most 30 values and counts the rest' {
            $names = 1..35 | ForEach-Object { 'User{0:00}' -f $_ }
            $list = InModuleScope PSLinear -Parameters @{ Names = $names } { param($Names) Format-LinearValueList -Value $Names }
            $list | Should -BeLike 'User01, User02, *, User30 (and 5 more)'
        }

        It 'says so when there are no values' {
            InModuleScope PSLinear { Format-LinearValueList -Value @() } | Should -Be '(none)'
        }
    }

    Context 'Clear-LinearCache' {
        It 'empties every lookup cache' {
            InModuleScope PSLinear {
                $null = Resolve-LinearTeamId -Team 'ENG'
                $null = Resolve-LinearWorkflowStateId -TeamId 'team-eng' -State 'Todo'
                $null = Resolve-LinearLabelId -TeamId 'team-eng' -Label 'Bug'
                $null = Resolve-LinearUserId -User 'Grace Hopper'
                $null = Resolve-LinearProjectId -Project 'Website'

                Clear-LinearCache

                $script:LinearTeamCache | Should -BeNullOrEmpty
                $script:LinearWorkflowStateCache.Count | Should -Be 0
                $script:LinearLabelCache.Count | Should -Be 0
                $script:LinearUserCache | Should -BeNullOrEmpty
                $script:LinearProjectCache | Should -BeNullOrEmpty
            }
        }
    }
}
