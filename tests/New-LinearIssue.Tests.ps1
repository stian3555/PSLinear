BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'New-LinearIssue' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }

        # Lookups come from the fixture workspace. CreateIssue echoes the title; Linear rejects
        # issues for the OPS team, and reports no success for the title 'No success'.
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $request = Get-RequestBody -Body $Body
            $lookup = Get-LinearTestLookupResponse -Request $request
            if ($null -ne $lookup) { return $lookup }

            $issueInput = $request.variables.input
            if ($issueInput.teamId -eq 'team-ops') {
                return New-LinearTestResponse -Data @{ issueCreate = $null } -Errors @(
                    New-LinearTestError -Message 'Argument Validation Error' -Code 'INVALID_INPUT' -Path 'issueCreate'
                )
            }
            if ($issueInput.title -eq 'No success') {
                return New-LinearTestResponse -Data @{ issueCreate = @{ success = $false; issue = $null } }
            }
            New-LinearTestResponse -Data @{
                issueCreate = @{ success = $true; issue = (New-LinearTestIssueNode -Identifier 'ENG-100' -Title $issueInput.title) }
            }
        }
    }

    Context 'Request' {
        It 'creates an issue with only a team and a title' {
            $issue = New-LinearIssue -Team ENG -Title 'Retry webhooks'
            $issue.Identifier | Should -Be 'ENG-100'
            $issue.Title | Should -Be 'Retry webhooks'
            $issue.PSObject.TypeNames | Should -Contain 'PSLinear.Issue'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                (Get-RequestOperation $Body) -eq 'CreateIssue' -and
                $issueInput.teamId -eq 'team-eng' -and
                $issueInput.title -eq 'Retry webhooks' -and
                $issueInput.Count -eq 2
            }
        }

        It 'sends every optional field, resolved to ids' {
            $parameters = @{
                Team        = 'Engineering'
                Title       = 'Login fails'
                Description = "Steps:`n1. Open Safari"
                State       = 'in progress'
                Assignee    = 'grace@example.com'
                Priority    = 'high'
                Label       = 'Bug', 'Backend'
                Project     = 'Website'
                Estimate    = 0
                DueDate     = [datetime]'2026-11-01T23:30:00'
                Parent      = 'ENG-1'
            }
            New-LinearIssue @parameters | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                (Get-RequestOperation $Body) -eq 'CreateIssue' -and
                $issueInput.teamId -eq 'team-eng' -and
                $issueInput.description -eq "Steps:`n1. Open Safari" -and
                $issueInput.stateId -eq 'state-eng-progress' -and
                $issueInput.assigneeId -eq 'user-grace' -and
                $issueInput.priority -eq 2 -and
                ($issueInput.labelIds -join ',') -eq 'label-bug,label-eng-backend' -and
                $issueInput.projectId -eq 'project-web' -and
                $issueInput.estimate -eq 0 -and $issueInput.ContainsKey('estimate') -and
                $issueInput.dueDate -eq '2026-11-01' -and
                $issueInput.parentId -eq 'ENG-1'
            }
        }

        It 'maps priority None to 0' {
            New-LinearIssue -Team ENG -Title 'x' -Priority None | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                $null -ne $issueInput -and $issueInput.ContainsKey('priority') -and $issueInput.priority -eq 0
            }
        }

        It 'sends a single label as a list' {
            New-LinearIssue -Team ENG -Title 'x' -Label Bug | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestBody $Body).variables.input.labelIds -is [array]
            }
        }

        It 'accepts priority numbers and a parent issue URL' {
            New-LinearIssue -Team ENG -Title 'x' -Priority 3 -Parent 'https://linear.app/acme/issue/ENG-42/fix-login' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                $null -ne $issueInput -and $issueInput.priority -eq 3 -and $issueInput.parentId -eq 'ENG-42'
            }
        }

        It 'rejects an unknown priority before sending anything' {
            { New-LinearIssue -Team ENG -Title 'x' -Priority 7 } | Should -Throw -ExpectedMessage "*'7' is not a priority*"
            { New-LinearIssue -Team ENG -Title 'x' -Priority 'Highest' } | Should -Throw -ExpectedMessage "*'Highest' is not a priority*"
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'resolves a state type in the issue''s team' {
            New-LinearIssue -Team ENG -Title 'x' -State Started | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestBody $Body).variables.input.stateId -eq 'state-eng-progress'
            }
        }

        It 'warns when the team does not use estimates, and still sends the estimate' {
            New-LinearIssue -Team OPS -Title 'x' -Estimate 3 -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -WarningVariable estimateWarnings | Out-Null
            $estimateWarnings.Count | Should -Be 1
            $estimateWarnings[0].Message | Should -BeLike 'Team OPS does not use estimates*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                $null -ne $issueInput -and $issueInput.estimate -eq 3
            }
        }

        It 'does not warn about estimates in a team that uses them' {
            New-LinearIssue -Team ENG -Title 'x' -Estimate 3 -WarningVariable estimateWarnings | Out-Null
            $estimateWarnings.Count | Should -Be 0
        }

        It 'resolves the cycle, milestone, delegate and template' {
            New-LinearIssue -Team ENG -Title 'x' -Cycle next -Project Website -Milestone Beta -Delegate 'Grace Hopper' -Template 'Bug report' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateIssue' -and
                (Get-RequestVariable $Body 'input.cycleId') -eq 'cycle-eng-13' -and
                (Get-RequestVariable $Body 'input.projectId') -eq 'project-web' -and
                (Get-RequestVariable $Body 'input.projectMilestoneId') -eq 'milestone-beta' -and
                (Get-RequestVariable $Body 'input.delegateId') -eq 'user-grace' -and
                (Get-RequestVariable $Body 'input.templateId') -eq 'template-eng-bug'
            }
        }

        It 'needs -Project for a milestone name, but not for a milestone id' {
            { New-LinearIssue -Team ENG -Title 'x' -Milestone Beta } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage '*give -Project with -Milestone*'
            $milestoneId = [guid]::NewGuid().Guid
            New-LinearIssue -Team ENG -Title 'x' -Milestone $milestoneId | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestVariable $Body 'input.projectMilestoneId') -eq $milestoneId
            }
        }

        It 'stops on an unknown cycle or template' {
            { New-LinearIssue -Team ENG -Title 'x' -Cycle 'Sprint 99' } | Should -Throw -ErrorId 'PSLinear.CycleNotFound*'
            { New-LinearIssue -Team ENG -Title 'x' -Template 'Nope' } | Should -Throw -ErrorId 'PSLinear.TemplateNotFound*'
        }

        It 'resolves -Assignee me to the connected user' {
            New-LinearIssue -Team ENG -Title 'x' -Assignee me | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestBody $Body).variables.input.assigneeId -eq 'user-ada'
            }
        }

        It 'resolves the state in the issue''s team' {
            InModuleScope PSLinear { $script:LinearContext.UserId = 'user-ada' }
            # OPS issues are rejected by the mock; the request is still sent with OPS's state id.
            New-LinearIssue -Team OPS -Title 'x' -State Doing -ErrorAction SilentlyContinue | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                $issueInput.teamId -eq 'team-ops' -and $issueInput.stateId -eq 'state-ops-doing'
            }
        }
    }

    Context '-WhatIf' {
        It 'sends no request, not even name lookups' {
            New-LinearIssue -Team ENG -Title 'x' -State Todo -Assignee me -Label Bug -Project Website -Milestone Beta -Cycle next -Delegate grace -Template 'Bug report' -WhatIf |
                Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'sends no request for teams from the pipeline' {
            $teams = @(
                [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-eng'; Key = 'ENG'; Name = 'Engineering' }
                [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-ops'; Key = 'OPS'; Name = 'Operations' }
            )
            $teams | New-LinearIssue -Title 'x' -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Pipeline input' {
        It 'creates one issue per team piped in, writing an error for the one Linear rejects' {
            $teams = @(
                [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-ops'; Key = 'OPS'; Name = 'Operations' }
                [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-eng'; Key = 'ENG'; Name = 'Engineering' }
            )
            $created = @($teams | New-LinearIssue -Title 'Rotate keys' -ErrorAction SilentlyContinue -ErrorVariable createErrors)
            $created.Count | Should -Be 1
            $createErrors.Count | Should -Be 1
            $createErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueCreateFailed*'
            $createErrors[0].Exception.Message | Should -BeLike "Linear did not create issue 'Rotate keys' in team OPS. Linear API error: Argument Validation Error*"
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateIssue'
            }
        }

        It 'binds the team of objects with a Team property' {
            $existing = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-1'; Identifier = 'ENG-1'; Team = 'ENG' }
            $existing | New-LinearIssue -Title 'Follow-up' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestBody $Body).variables.input.teamId -eq 'team-eng'
            }
        }
    }

    Context 'Errors' {
        It 'stops on an unknown state, lists the valid states and creates nothing' {
            { New-LinearIssue -Team ENG -Title 'x' -State 'Doen' } |
                Should -Throw -ErrorId 'PSLinear.StateNotFound*' -ExpectedMessage '*Valid states: Backlog, Todo, In Progress, In Review, Done, Canceled, Duplicate; state types: *'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateIssue'
            }
        }

        It 'stops on an unknown team' {
            { New-LinearIssue -Team 'NOPE' -Title 'x' } | Should -Throw -ErrorId 'PSLinear.TeamNotFound*' -ExpectedMessage '*ENG, OPS*'
        }

        It 'stops on an unknown label, assignee or project' {
            { New-LinearIssue -Team ENG -Title 'x' -Label 'Nope' } | Should -Throw -ErrorId 'PSLinear.LabelNotFound*'
            { New-LinearIssue -Team ENG -Title 'x' -Assignee 'Nobody' } | Should -Throw -ErrorId 'PSLinear.UserNotFound*'
            { New-LinearIssue -Team ENG -Title 'x' -Project 'Nope' } | Should -Throw -ErrorId 'PSLinear.ProjectNotFound*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateIssue'
            }
        }

        It 'writes one error when Linear does not report success' {
            $issue = New-LinearIssue -Team ENG -Title 'No success' -ErrorAction SilentlyContinue -ErrorVariable createErrors
            $issue | Should -BeNullOrEmpty
            $createErrors.Count | Should -Be 1
            $createErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueCreateFailed*'
        }

        It 'still stops on authentication failures' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                New-LinearTestResponse -StatusCode 400 -Errors @(New-LinearTestError -Message 'Authentication required' -Code 'AUTHENTICATION_ERROR')
            }
            { New-LinearIssue -Team ENG -Title 'x' } | Should -Throw -ErrorId 'PSLinear.AuthenticationFailed*'
        }
    }
}
