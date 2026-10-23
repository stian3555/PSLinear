BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Get-LinearIssue' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
            $script:LinearTeamCache = @(
                [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-eng'; Key = 'ENG'; Name = 'Engineering' }
                [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-ops'; Key = 'OPS'; Name = 'Operations' }
            )
            $script:LinearTeamCacheExpires = [datetime]::UtcNow.AddMinutes(10)
        }

        # GetIssue returns the requested identifier; ENG-404 does not exist. ListIssues returns two issues.
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $request = Get-RequestBody -Body $Body
            if ($request.query -match 'query GetIssue') {
                if ($request.variables.id -eq 'ENG-404') {
                    return New-LinearTestResponse -Data @{ issue = $null } -Errors @(New-LinearTestError -Message 'Entity not found: Issue' -Code 'INVALID_INPUT' -Path 'issue')
                }
                return New-LinearTestResponse -Data @{ issue = (New-LinearTestIssueNode -Identifier $request.variables.id) }
            }
            New-LinearTestResponse -Data @{
                issues = (New-LinearTestConnection -Nodes @(
                        (New-LinearTestIssueNode -Identifier 'ENG-1' -Title 'First'),
                        (New-LinearTestIssueNode -Identifier 'ENG-2' -Title 'Second' -Assignee $null -Labels @())
                    ))
            }
        }
    }

    Context 'By identifier' {
        It 'gets one issue' {
            $issue = Get-LinearIssue -Id 'ENG-7'
            $issue.Identifier | Should -Be 'ENG-7'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestBody $Body).variables.id -eq 'ENG-7'
            }
        }

        It 'accepts an issue URL' {
            (Get-LinearIssue 'https://linear.app/acme/issue/ENG-8/some-title').Identifier | Should -Be 'ENG-8'
        }

        It 'accepts identifiers positionally and from the pipeline' {
            (Get-LinearIssue 'ENG-3').Identifier | Should -Be 'ENG-3'
            ('ENG-4', 'ENG-5' | Get-LinearIssue).Identifier | Should -Be @('ENG-4', 'ENG-5')
        }

        It 'refreshes PSLinear.Issue objects piped in, using their Id' {
            $existing = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'ENG-9'; Identifier = 'ENG-9'; Team = 'ENG' }
            ($existing | Get-LinearIssue).Identifier | Should -Be 'ENG-9'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestBody $Body).query -match 'query GetIssue'
            }
        }

        It 'writes a non-terminating error for a missing issue and continues' {
            $result = @('ENG-1', 'ENG-404', 'ENG-2' | Get-LinearIssue -ErrorAction SilentlyContinue -ErrorVariable issueErrors)
            $result.Identifier | Should -Be @('ENG-1', 'ENG-2')
            $issueErrors.Count | Should -Be 1
            $issueErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueNotFound*'
            $issueErrors[0].Exception.Message | Should -BeLike "*ENG-404*Entity not found*"
            $issueErrors[0].TargetObject | Should -Be 'ENG-404'
        }

        It 'still stops on authentication failures' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                New-LinearTestResponse -StatusCode 400 -Errors @(New-LinearTestError -Message 'Authentication required' -Code 'AUTHENTICATION_ERROR')
            }
            { 'ENG-1', 'ENG-2' | Get-LinearIssue } | Should -Throw -ErrorId 'PSLinear.AuthenticationFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
        }
    }

    Context 'Output object' {
        It 'returns typed, flattened objects' {
            $issue = Get-LinearIssue -Id 'ENG-1'
            $issue.PSObject.TypeNames | Should -Contain 'PSLinear.Issue'
            $issue.State | Should -Be 'Todo'
            $issue.StateType | Should -Be 'unstarted'
            $issue.Assignee | Should -Be 'Ada Lovelace'
            $issue.Team | Should -Be 'ENG'
            $issue.TeamId | Should -Be 'team-eng'
            $issue.Labels | Should -Be @('Bug')
            $issue.PriorityLabel | Should -Be 'High'
        }

        It 'flattens the milestone and delegate' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                New-LinearTestResponse -Data @{ issue = (New-LinearTestIssueNode -Identifier 'ENG-5' -Milestone 'Beta' -Delegate 'Agent Smith') }
            }
            $issue = Get-LinearIssue ENG-5
            $issue.Milestone | Should -Be 'Beta'
            $issue.MilestoneId | Should -Be 'milestone-x'
            $issue.Delegate | Should -Be 'Agent Smith'
            $issue.DelegateId | Should -Be 'user-agent'
        }

        It 'handles missing nested objects and empty label lists' {
            $issues = @(Get-LinearIssue)
            $issues[1].Assignee | Should -BeNullOrEmpty
            $issues[1].AssigneeId | Should -BeNullOrEmpty
            $issues[1].Project | Should -BeNullOrEmpty
            @($issues[1].Labels).Count | Should -Be 0
        }
    }

    Context 'Listing and filters' {
        It 'lists the most recently updated issues by default, 50 at a time' {
            Get-LinearIssue | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                $request.query -match 'query ListIssues' -and
                $request.variables.first -eq 50 -and
                $request.variables.orderBy -eq 'updatedAt' -and
                $request.variables.includeArchived -eq $false -and
                -not $request.variables.ContainsKey('filter')
            }
        }

        It 'resolves -Team by key, case-insensitively' {
            Get-LinearIssue -Team 'eng' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestBody $Body).variables.filter.team.id.eq -eq 'team-eng'
            }
        }

        It 'resolves -Team by name' {
            Get-LinearIssue -Team 'Operations' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestBody $Body).variables.filter.team.id.eq -eq 'team-ops'
            }
        }

        It 'fails clearly for an unknown team and lists the valid keys' {
            Mock -ModuleName PSLinear Get-LinearTeamCache {
                [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-eng'; Key = 'ENG'; Name = 'Engineering' }
                [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-ops'; Key = 'OPS'; Name = 'Operations' }
            }
            { Get-LinearIssue -Team 'NOPE' } | Should -Throw -ExpectedMessage "*Team 'NOPE' was not found*ENG, OPS*"
        }

        It 'filters by -Assignee me' {
            Get-LinearIssue -Assignee me | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestBody $Body).variables.filter.assignee.isMe.eq -eq $true
            }
        }

        It 'filters by assignee email' {
            Get-LinearIssue -Assignee 'ada@example.com' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestBody $Body).variables.filter.assignee.email.eqIgnoreCase -eq 'ada@example.com'
            }
        }

        It 'filters by assignee name or display name' {
            Get-LinearIssue -Assignee 'Ada Lovelace' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $assignee = (Get-RequestBody $Body).variables.filter.assignee
                $assignee.or.Count -eq 2 -and $assignee.or[0].name.eqIgnoreCase -eq 'Ada Lovelace'
            }
        }

        It 'filters unassigned issues' {
            Get-LinearIssue -Unassigned | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestBody $Body).variables.filter.assignee.null -eq $true
            }
        }

        It 'rejects -Assignee together with -Unassigned' {
            { Get-LinearIssue -Assignee me -Unassigned } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
        }

        It 'combines state names (OR) with state types' {
            Get-LinearIssue -State 'Todo', 'In Progress' -StateType Started | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $state = (Get-RequestBody $Body).variables.filter.state
                $state.or.Count -eq 2 -and
                $state.or[1].name.eqIgnoreCase -eq 'In Progress' -and
                ($state.type.in -join ',') -eq 'started'
            }
        }

        It 'sends a single state as a list' {
            Get-LinearIssue -State 'Todo' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestBody $Body).variables.filter.state.or -is [array]
            }
        }

        It 'maps priority names to Linear priority numbers' {
            Get-LinearIssue -Priority Urgent, Low | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                ((Get-RequestBody $Body).variables.filter.priority.in -join ',') -eq '1,4'
            }
        }

        It 'accepts priority numbers alongside names' {
            Get-LinearIssue -Priority 0, High | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                ((Get-RequestBody $Body).variables.filter.priority.in -join ',') -eq '0,2'
            }
        }

        It 'filters by cycle: <Cycle>' -ForEach @(
            @{ Cycle = 'next'; Key = 'isNext'; Value = $true }
            @{ Cycle = 'current'; Key = 'isActive'; Value = $true }
            @{ Cycle = 'previous'; Key = 'isPrevious'; Value = $true }
        ) {
            Get-LinearIssue -Cycle $Cycle | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestVariable $Body "filter.cycle.$Key.eq") -eq $Value
            }
        }

        It 'filters by cycle number or name' {
            Get-LinearIssue -Cycle 12 | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter { (Get-RequestVariable $Body 'filter.cycle.number.eq') -eq 12 }
            Get-LinearIssue -Cycle 'Release sprint' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter { (Get-RequestVariable $Body 'filter.cycle.name.eqIgnoreCase') -eq 'Release sprint' }
        }

        It 'rejects -Cycle together with -CurrentCycle' {
            { Get-LinearIssue -Cycle next -CurrentCycle } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
        }

        It 'filters by milestone and delegate' {
            Get-LinearIssue -Milestone Beta -Delegate me | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestVariable $Body 'filter.projectMilestone.name.eqIgnoreCase') -eq 'Beta' -and
                (Get-RequestVariable $Body 'filter.delegate.isMe.eq') -eq $true
            }
        }

        It 'matches any of several labels' {
            Get-LinearIssue -Label 'Bug', 'Frontend' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestBody $Body).variables.filter.labels.some.or.Count -eq 2
            }
        }

        It 'filters by project name, search text and current cycle' {
            Get-LinearIssue -Project 'Website' -Search 'login' -CurrentCycle | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $filter = (Get-RequestBody $Body).variables.filter
                $filter.project.name.eqIgnoreCase -eq 'Website' -and
                $filter.searchableContent.contains -eq 'login' -and
                $filter.cycle.isActive.eq -eq $true
            }
        }

        It 'combines a raw -Filter with the other parameters using AND' {
            Get-LinearIssue -Assignee me -Filter @{ dueDate = @{ lt = '2026-10-17' } } | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $filter = (Get-RequestBody $Body).variables.filter
                $filter.and.Count -eq 2 -and $filter.and[1].dueDate.lt -eq '2026-10-17'
            }
        }

        It 'uses a raw -Filter on its own as-is' {
            Get-LinearIssue -Filter @{ estimate = @{ gt = 3 } } | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestBody $Body).variables.filter.estimate.gt -eq 3
            }
        }

        It 'supports -OrderBy CreatedAt and -IncludeArchived' {
            Get-LinearIssue -OrderBy CreatedAt -IncludeArchived | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $variables = (Get-RequestBody $Body).variables
                $variables.orderBy -eq 'createdAt' -and $variables.includeArchived -eq $true
            }
        }

        It 'filters by attachment URL: <Url>' -ForEach @(
            @{ Url = 'https://monitor.example/alerts/1'; Comparator = 'eq'; Value = 'https://monitor.example/alerts/1' }
            @{ Url = 'https://monitor.example/alerts/*'; Comparator = 'startsWith'; Value = 'https://monitor.example/alerts/' }
            @{ Url = '*/alerts/1'; Comparator = 'endsWith'; Value = '/alerts/1' }
            @{ Url = '*monitor.example*'; Comparator = 'contains'; Value = 'monitor.example' }
            @{ Url = 'https://monitor.example/alerts?id=[1]'; Comparator = 'eq'; Value = 'https://monitor.example/alerts?id=[1]' }
        ) {
            Get-LinearIssue -AttachmentUrl $Url | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $conditions = @(Get-RequestVariable $Body 'filter.attachments.some.or')
                $conditions.Count -eq 1 -and @($conditions[0]['url'].Keys) -ceq $Comparator -and $conditions[0]['url'][$Comparator] -ceq $Value
            }
        }

        It 'matches any of several attachment URLs' {
            Get-LinearIssue -AttachmentUrl 'https://a.example/*', 'https://b.example/*' -StateType Completed | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $conditions = @(Get-RequestVariable $Body 'filter.attachments.some.or')
                $conditions.Count -eq 2 -and $conditions[1]['url']['startsWith'] -eq 'https://b.example/' -and
                (Get-RequestVariable $Body 'filter.state.type.in') -contains 'completed'
            }
        }

        It 'refuses a * in the middle of an attachment URL, before sending anything' {
            { Get-LinearIssue -AttachmentUrl 'https://*.example/alerts' } |
                Should -Throw -ErrorId 'PSLinear.InvalidFilter*' -ExpectedMessage '*Use * only at the start or the end*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'lists issues for each team piped in' {
            $teams = @(
                [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-eng'; Key = 'ENG'; Name = 'Engineering' }
                [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-ops'; Key = 'OPS'; Name = 'Operations' }
            )
            $teams | Get-LinearIssue | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestBody $Body).variables.filter.team.id.eq -eq 'team-ops'
            }
        }
    }

    Context 'With attachments' {
        BeforeEach {
            # ENG-1 has one attachment. ENG-2 has more than the list returns: b1 in the list, b1 and b2 in ListIssueAttachments.
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                $request = Get-RequestBody -Body $Body
                if ($request.query -match 'query ListIssuesWithAttachments') {
                    $first = New-LinearTestIssueNode -Identifier 'ENG-1' -Title 'First'
                    $first['attachments'] = New-LinearTestConnection -Nodes @(
                        New-LinearTestAttachmentNode -Id 'a1' -Title 'Alert 1' -Url 'https://monitor.example/alerts/1' -Issue 'ENG-1' -Metadata ([ordered]@{ alertId = 1; managed = $true })
                    )
                    $second = New-LinearTestIssueNode -Identifier 'ENG-2' -Title 'Second'
                    $second['attachments'] = New-LinearTestConnection -Nodes @(New-LinearTestAttachmentNode -Id 'b1' -Issue 'ENG-2') -HasNextPage $true -EndCursor 'b1'
                    return New-LinearTestResponse -Data @{ issues = New-LinearTestConnection -Nodes @($first, $second) }
                }
                if ($request.query -match 'query ListIssueAttachments') {
                    return New-LinearTestResponse -Data @{
                        issue = @{
                            attachments = New-LinearTestConnection -Nodes @(
                                (New-LinearTestAttachmentNode -Id 'b1' -Issue 'ENG-2'),
                                (New-LinearTestAttachmentNode -Id 'b2' -Url 'https://monitor.example/alerts/2' -Issue 'ENG-2')
                            )
                        }
                    }
                }
                New-LinearTestResponse -Data @{ issues = New-LinearTestConnection -Nodes @(New-LinearTestIssueNode -Identifier 'ENG-1') }
            }
        }

        It 'adds the attachments and their metadata to each issue' {
            $issues = @(Get-LinearIssue -AttachmentUrl 'https://monitor.example/*' -IncludeAttachment)
            $issues[0].Attachments.Count | Should -Be 1
            $issues[0].Attachments[0].PSObject.TypeNames | Should -Contain 'PSLinear.Attachment'
            $issues[0].Attachments[0].Url | Should -Be 'https://monitor.example/alerts/1'
            $issues[0].Attachments[0].Metadata.managed | Should -BeTrue
            $issues[0].Attachments[0].Issue | Should -Be 'ENG-1'
        }

        It 'reads 50 issues per request, so the query stays within the complexity limit' {
            Get-LinearIssue -IncludeAttachment -All | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListIssuesWithAttachments' -and (Get-RequestVariable $Body 'first') -eq 50
            }
        }

        It 'reads all attachments of an issue that has more than the list returns' {
            $issues = @(Get-LinearIssue -IncludeAttachment)
            $issues[1].Attachments.Id | Should -Be @('b1', 'b2')
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListIssueAttachments' -and (Get-RequestVariable $Body 'id') -eq $issues[1].Id
            }
        }

        It 'leaves the Attachments property out without -IncludeAttachment' {
            $issue = Get-LinearIssue | Select-Object -First 1
            $issue.PSObject.Properties['Attachments'] | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ListIssues' }
        }
    }
}
