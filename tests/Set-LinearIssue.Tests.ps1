BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Set-LinearIssue' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }

        # Lookups come from the fixture workspace. OPS-* issues belong to OPS, others to ENG.
        # ENG-404 does not exist, and Linear reports no success for ENG-500.
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $request = Get-RequestBody -Body $Body
            $lookup = Get-LinearTestLookupResponse -Request $request
            if ($null -ne $lookup) { return $lookup }

            $issueId = $request.variables.id
            $notFound = New-LinearTestError -Message 'Entity not found: Issue' -Code 'INPUT_ERROR'
            if ($request.query -match 'query GetIssueTeam') {
                if ($issueId -eq 'ENG-404') {
                    return New-LinearTestResponse -Data @{ issue = $null } -Errors @($notFound)
                }
                $team = if ($issueId -like 'OPS-*') { @{ id = 'team-ops'; key = 'OPS' } } else { @{ id = 'team-eng'; key = 'ENG' } }
                # ENG-7 is in the Website project; the others are in no project.
                $project = if ($issueId -eq 'ENG-7') { @{ id = 'project-web'; name = 'Website' } } else { $null }
                return New-LinearTestResponse -Data @{ issue = @{ id = [guid]::NewGuid().Guid; identifier = $issueId; team = $team; project = $project } }
            }

            if ($issueId -eq 'ENG-404') {
                return New-LinearTestResponse -Data @{ issueUpdate = $null } -Errors @($notFound)
            }
            if ($issueId -eq 'ENG-500') {
                return New-LinearTestResponse -Data @{ issueUpdate = @{ success = $false; issue = $null } }
            }
            $identifier = if ($issueId -match '^[A-Z]+-\d+$') { $issueId } else { 'ENG-1' }
            New-LinearTestResponse -Data @{ issueUpdate = @{ success = $true; issue = (New-LinearTestIssueNode -Identifier $identifier) } }
        }
    }

    Context 'Request' {
        It 'updates the given fields only and returns nothing' {
            Set-LinearIssue ENG-1 -Title 'New title' -Priority Urgent | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                (Get-RequestOperation $Body) -eq 'UpdateIssue' -and
                $request.variables.id -eq 'ENG-1' -and
                $request.variables.input.title -eq 'New title' -and
                $request.variables.input.priority -eq 1 -and
                $request.variables.input.Count -eq 2
            }
        }

        It 'looks up the team of an identifier to resolve the state and labels' {
            Set-LinearIssue OPS-7 -State 'doing' -AddLabel Incident
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'GetIssueTeam'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                (Get-RequestOperation $Body) -eq 'UpdateIssue' -and
                $issueInput.stateId -eq 'state-ops-doing' -and
                ($issueInput.addedLabelIds -join ',') -eq 'label-ops-incident'
            }
        }

        It 'uses the TeamId of piped issues instead of looking up the team' {
            $issueId = [guid]::NewGuid().Guid
            $existing = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = $issueId; Identifier = 'ENG-1'; Team = 'ENG'; TeamId = 'team-eng' }
            $existing | Set-LinearIssue -State Done
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'GetIssueTeam'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                (Get-RequestOperation $Body) -eq 'UpdateIssue' -and
                $request.variables.id -eq $issueId -and
                $request.variables.input.stateId -eq 'state-eng-done'
            }
        }

        It 'replaces all labels with -Label' {
            Set-LinearIssue ENG-1 -Label Bug, Backend
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                ($issueInput.labelIds -join ',') -eq 'label-bug,label-eng-backend' -and
                -not $issueInput.ContainsKey('addedLabelIds')
            }
        }

        It 'adds and removes labels in one request' {
            Set-LinearIssue ENG-1 -AddLabel Bug -RemoveLabel Feature, Backend
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                (Get-RequestOperation $Body) -eq 'UpdateIssue' -and
                $issueInput.addedLabelIds -is [array] -and
                ($issueInput.addedLabelIds -join ',') -eq 'label-bug' -and
                ($issueInput.removedLabelIds -join ',') -eq 'label-feature,label-eng-backend' -and
                -not $issueInput.ContainsKey('labelIds')
            }
        }

        It 'sends a null assignee for -Unassign' {
            Set-LinearIssue ENG-1 -Unassign
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                $null -ne $issueInput -and $issueInput.ContainsKey('assigneeId') -and $null -eq $issueInput.assigneeId
            }
        }

        It 'resolves the assignee by name' {
            Set-LinearIssue ENG-1 -Assignee 'Grace Hopper'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestBody $Body).variables.input.assigneeId -eq 'user-grace'
            }
        }

        It 'moves the issue with -Team and resolves the state in the new team' {
            Set-LinearIssue ENG-1 -Team OPS -State Doing
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'GetIssueTeam'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                $issueInput.teamId -eq 'team-ops' -and $issueInput.stateId -eq 'state-ops-doing'
            }
        }

        It 'sends project, estimate, due date, parent and an empty description' {
            Set-LinearIssue ENG-1 -Project Website -Estimate 5 -DueDate '2026-12-24' -Parent ENG-2 -Description ''
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                $null -ne $issueInput -and
                $issueInput.projectId -eq 'project-web' -and
                $issueInput.estimate -eq 5 -and
                $issueInput.dueDate -eq '2026-12-24' -and
                $issueInput.parentId -eq 'ENG-2' -and
                $issueInput.ContainsKey('description') -and $issueInput.description -eq ''
            }
        }

        It 'accepts issue URLs and priority numbers' {
            Set-LinearIssue 'https://linear.app/acme/issue/eng-7/some-title?foo=bar' -Priority 0
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                $request.variables.id -eq 'ENG-7' -and $request.variables.input.ContainsKey('priority') -and $request.variables.input.priority -eq 0
            }
        }

        It 'moves issues from several teams to the first completed state of each team' {
            'ENG-1', 'OPS-2' | Set-LinearIssue -State completed
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                $request.variables.id -eq 'ENG-1' -and $request.variables.input.stateId -eq 'state-eng-done'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                $request.variables.id -eq 'OPS-2' -and $request.variables.input.stateId -eq 'state-ops-done'
            }
        }

        It 'sends null for every field given to -Clear' {
            Set-LinearIssue ENG-1 -Clear Estimate, DueDate, Parent, Project, Cycle
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                $issueInput.Count -eq 5 -and
                @('estimate', 'dueDate', 'parentId', 'projectId', 'cycleId' | Where-Object { $issueInput.ContainsKey($_) -and $null -eq $issueInput[$_] }).Count -eq 5
            }
        }

        It 'removes all labels with -Clear Labels, without looking up the team' {
            Set-LinearIssue ENG-1 -Clear Labels
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                $issueInput = $request.variables.input
                (Get-RequestOperation $Body) -eq 'UpdateIssue' -and
                $request.query -notmatch 'GetIssueTeam' -and
                $issueInput.ContainsKey('labelIds') -and @($issueInput.labelIds).Count -eq 0
            }
        }

        It 'combines -Clear with other changes' {
            Set-LinearIssue ENG-1 -Clear DueDate -Priority High
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $issueInput = (Get-RequestBody $Body).variables.input
                $issueInput.Count -eq 2 -and $issueInput.priority -eq 2 -and $issueInput.ContainsKey('dueDate')
            }
        }

        It 'looks up the issue''s team and warns when the team does not use estimates' {
            Set-LinearIssue OPS-1 -Estimate 2 -WarningAction SilentlyContinue -WarningVariable estimateWarnings
            $estimateWarnings.Count | Should -Be 1
            $estimateWarnings[0].Message | Should -BeLike 'Team OPS does not use estimates*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'GetIssueTeam'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateIssue' -and (Get-RequestBody $Body).variables.input.estimate -eq 2
            }
        }

        It 'does not warn about estimates in a team that uses them' {
            Set-LinearIssue ENG-1 -Estimate 2 -WarningVariable estimateWarnings
            $estimateWarnings.Count | Should -Be 0
        }

        It 'resolves the cycle in the issue''s team' {
            Set-LinearIssue OPS-2 -Cycle active
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateIssue' -and (Get-RequestVariable $Body 'input.cycleId') -eq 'cycle-ops-3'
            }
        }

        It 'resolves a milestone in the issue''s own project' {
            Set-LinearIssue ENG-7 -Milestone alpha
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'GetIssueTeam' }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateIssue' -and (Get-RequestVariable $Body 'input.projectMilestoneId') -eq 'milestone-alpha'
            }
        }

        It 'resolves a milestone in -Project without looking up the issue' {
            Set-LinearIssue ENG-1 -Project Website -Milestone Beta
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'GetIssueTeam' }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestVariable $Body 'input.projectId') -eq 'project-web' -and (Get-RequestVariable $Body 'input.projectMilestoneId') -eq 'milestone-beta'
            }
        }

        It 'uses the ProjectId of piped issues for a milestone' {
            $issue = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-uuid'; Identifier = 'ENG-9'; TeamId = 'team-eng'; ProjectId = 'project-web' }
            $issue | Set-LinearIssue -Milestone Beta
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'GetIssueTeam' }
        }

        It 'stops when an issue without a project gets a milestone name' {
            { Set-LinearIssue ENG-1 -Milestone Beta } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage "*Issue 'ENG-1' is not in a project*"
        }

        It 'delegates to an agent, and clears the milestone and delegate' {
            Set-LinearIssue ENG-1 -Delegate 'grace@example.com'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter { (Get-RequestVariable $Body 'input.delegateId') -eq 'user-grace' }
            Set-LinearIssue ENG-1 -Clear Milestone, Delegate
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $issueInput = Get-RequestVariable $Body 'input'
                $null -ne $issueInput -and $issueInput.Contains('projectMilestoneId') -and $null -eq $issueInput['projectMilestoneId'] -and
                $issueInput.Contains('delegateId') -and $null -eq $issueInput['delegateId']
            }
        }

        It 'rejects -Clear Cycle together with -Cycle' {
            { Set-LinearIssue ENG-1 -Cycle next -Clear Cycle } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
        }

        It 'returns the updated issue with -PassThru' {
            $issue = Set-LinearIssue ENG-3 -Priority Low -PassThru
            $issue.Identifier | Should -Be 'ENG-3'
            $issue.PSObject.TypeNames | Should -Contain 'PSLinear.Issue'
        }
    }

    Context '-WhatIf' {
        It 'sends no request, not even the team and name lookups' {
            'ENG-1', 'OPS-2' | Set-LinearIssue -State Done -Assignee me -Label Bug -Project Website -WhatIf | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'sends no request for piped issue objects' {
            $existing = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-1'; Identifier = 'ENG-1'; TeamId = 'team-eng' }
            $existing | Set-LinearIssue -Unassign -Clear Labels -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Pipeline input' {
        It 'updates every identifier piped in' {
            'ENG-1', 'ENG-2' | Set-LinearIssue -Priority Low
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateIssue'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestBody $Body).variables.id -eq 'ENG-2'
            }
        }

        It 'accepts several identifiers positionally' {
            (Set-LinearIssue 'ENG-1', 'ENG-2' -Title 'Same' -PassThru).Identifier | Should -Be @('ENG-1', 'ENG-2')
        }

        It 'writes one error for a missing issue and updates the rest' {
            $updated = @('ENG-1', 'ENG-404', 'ENG-2' | Set-LinearIssue -Priority High -PassThru -ErrorAction SilentlyContinue -ErrorVariable updateErrors)
            $updated.Identifier | Should -Be @('ENG-1', 'ENG-2')
            $updateErrors.Count | Should -Be 1
            $updateErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueUpdateFailed*'
            $updateErrors[0].Exception.Message | Should -BeLike "Linear did not update issue 'ENG-404'. Linear API error: Entity not found*"
            $updateErrors[0].TargetObject | Should -Be 'ENG-404'
        }

        It 'writes one error when the team lookup cannot find the issue, and updates the rest' {
            $updated = @('ENG-404', 'ENG-2' | Set-LinearIssue -State Done -PassThru -ErrorAction SilentlyContinue -ErrorVariable updateErrors)
            $updated.Identifier | Should -Be @('ENG-2')
            $updateErrors.Count | Should -Be 1
            $updateErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueNotFound*'
            $updateErrors[0].Exception.Message | Should -BeLike "Issue 'ENG-404' was not found. Linear API error: Entity not found*"
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter {
                (Get-RequestBody $Body).query -match 'mutation UpdateIssue' -and (Get-RequestBody $Body).variables.id -eq 'ENG-404'
            }
        }
    }

    Context 'Errors' {
        It 'rejects -Assignee together with -Unassign before sending anything' {
            { Set-LinearIssue ENG-1 -Assignee me -Unassign } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage '*-Assignee or -Unassign*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'rejects -Label together with -AddLabel or -RemoveLabel' {
            { Set-LinearIssue ENG-1 -Label Bug -AddLabel Feature } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            { Set-LinearIssue ENG-1 -Label Bug -RemoveLabel Feature } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'rejects -Clear together with a value for the same field' {
            { Set-LinearIssue ENG-1 -Clear Estimate -Estimate 3 } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage '*-Clear Estimate or -Estimate*'
            { Set-LinearIssue ENG-1 -Clear Labels -AddLabel Bug } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage '*-Clear Labels or -AddLabel*'
            { Set-LinearIssue ENG-1 -Clear Project, DueDate -DueDate '2026-12-24' } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'requires at least one change' {
            { Set-LinearIssue ENG-1 } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage '*at least one property*'
            { Set-LinearIssue ENG-1 -Unassign:$false -PassThru } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'stops on a state that does not exist in the issue''s team, listing that team''s states' {
            { Set-LinearIssue OPS-1 -State 'In Progress' } |
                Should -Throw -ErrorId 'PSLinear.StateNotFound*' -ExpectedMessage "State 'In Progress' was not found in team OPS. Valid states: Todo, Doing, Done; state types: unstarted, started, completed."
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateIssue'
            }
        }

        It 'stops on an unknown label and lists the valid labels' {
            { Set-LinearIssue ENG-1 -RemoveLabel 'Nope' } |
                Should -Throw -ErrorId 'PSLinear.LabelNotFound*' -ExpectedMessage '*Valid labels: Backend, Bug, Feature, Frontend.'
        }

        It 'writes one error when Linear does not report success' {
            $issue = Set-LinearIssue ENG-500 -Title 'x' -PassThru -ErrorAction SilentlyContinue -ErrorVariable updateErrors
            $issue | Should -BeNullOrEmpty
            $updateErrors.Count | Should -Be 1
            $updateErrors[0].Exception.Message | Should -Be "Linear did not update issue 'ENG-500'."
        }
    }
}
