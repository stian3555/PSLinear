BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Project write commands' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $request = Get-RequestBody -Body $Body
            $lookup = Get-LinearTestLookupResponse -Request $request
            if ($lookup) { return $lookup }
            Get-LinearTestProjectResponse -Request $request
        }
    }

    Context 'New-LinearProject' {
        It 'creates a project, resolving every name to an id' {
            $parameters = @{
                Name        = 'Relaunch'
                Team        = 'ENG', 'ops'
                Description = 'Short summary'
                Content     = "# Plan`nDetails"
                Lead        = 'me'
                Member      = 'grace', 'ada@example.com'
                Status      = 'Beta testing'
                Priority    = 'High'
                StartDate   = [datetime]'2026-11-01 15:30'
                TargetDate  = [datetime]'2027-02-01'
                Label       = 'Infrastructure', 'customer'
                Template    = 'Kickoff'
            }
            $project = New-LinearProject @parameters
            $project.PSObject.TypeNames | Should -Contain 'PSLinear.Project'
            $project.Name | Should -Be 'Relaunch'
            $project.Teams | Should -Be @('ENG', 'OPS')
            $project.Status | Should -Be 'Beta testing'
            $project.Lead | Should -Be 'Ada Lovelace'
            $project.Labels | Should -Be @('Infrastructure', 'Customer')
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateProject' -and
                (Get-RequestVariable $Body 'input.name') -eq 'Relaunch' -and
                ((Get-RequestVariable $Body 'input.teamIds') -join ',') -eq 'team-eng,team-ops' -and
                (Get-RequestVariable $Body 'input.description') -eq 'Short summary' -and
                (Get-RequestVariable $Body 'input.content') -eq "# Plan`nDetails" -and
                (Get-RequestVariable $Body 'input.leadId') -eq 'user-ada' -and
                ((Get-RequestVariable $Body 'input.memberIds') -join ',') -eq 'user-grace,user-ada' -and
                (Get-RequestVariable $Body 'input.statusId') -eq 'pstatus-beta' -and
                (Get-RequestVariable $Body 'input.priority') -eq 2 -and
                (Get-RequestVariable $Body 'input.startDate') -eq '2026-11-01' -and
                (Get-RequestVariable $Body 'input.targetDate') -eq '2027-02-01' -and
                ((Get-RequestVariable $Body 'input.labelIds') -join ',') -eq 'plabel-infra,plabel-customer' -and
                (Get-RequestVariable $Body 'input.templateId') -eq 'template-kickoff'
            }
        }

        It 'sends only the name and teams when nothing else is given' {
            $null = New-LinearProject 'Plain' -Team ENG
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateProject' -and
                (@((Get-RequestBody $Body).variables.input.Keys | Sort-Object) -join ',') -eq 'name,teamIds'
            }
        }

        It 'picks the first status of a status type' {
            $null = New-LinearProject 'Typed' -Team ENG -Status started
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestVariable $Body 'input.statusId') -eq 'pstatus-progress'
            }
        }

        It 'caches project statuses and labels between commands' {
            $null = New-LinearProject 'One' -Team ENG -Status planned -Label Customer
            $null = New-LinearProject 'Two' -Team ENG -Status completed -Label Infrastructure
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ListProjectStatuses' }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ListProjectLabels' }
        }

        It 'forgets the cached projects, so the new one resolves by name' {
            InModuleScope PSLinear { $null = Get-LinearProjectCache }
            $null = New-LinearProject 'Fresh' -Team ENG
            InModuleScope PSLinear { $script:LinearProjectCache } | Should -BeNullOrEmpty
        }

        It 'sends nothing with -WhatIf' {
            New-LinearProject 'Never' -Team ENG -Status planned -Lead me -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'stops with the valid statuses for an unknown status, before creating anything' {
            { New-LinearProject 'Bad' -Team ENG -Status Shipped } |
                Should -Throw -ErrorId 'PSLinear.ProjectStatusNotFound*' -ExpectedMessage '*Valid statuses: Backlog, Planned, In Progress, Beta testing, Paused, Completed, Canceled;*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'CreateProject' }
        }

        It 'stops with the valid labels for an unknown, retired or group label' {
            foreach ($label in 'Nope', 'Old', 'Theme') {
                { New-LinearProject 'Bad' -Team ENG -Label $label } |
                    Should -Throw -ErrorId 'PSLinear.LabelNotFound*' -ExpectedMessage "Project label '$label' was not found. Valid project labels: Customer, Growth, Infrastructure."
            }
        }

        It 'stops for an ambiguous label and lists the matches' {
            { New-LinearProject 'Bad' -Team ENG -Label Growth } |
                Should -Throw -ErrorId 'PSLinear.AmbiguousLabel*' -ExpectedMessage "Project label 'Growth' is ambiguous. Use the label id instead. Matches: Growth (team ENG, id plabel-eng-growth); Theme/Growth (workspace, id plabel-growth)."
            $labelId = '11111111-2222-4333-8444-555555555555'
            $null = New-LinearProject 'Good' -Team ENG -Label $labelId
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                ((Get-RequestVariable $Body 'input.labelIds') -join ',') -eq $labelId
            }
        }

        It 'stops for an unknown team or lead' {
            { New-LinearProject 'Bad' -Team NOPE } | Should -Throw -ErrorId 'PSLinear.TeamNotFound*'
            { New-LinearProject 'Bad' -Team ENG -Lead 'Nobody' } | Should -Throw -ErrorId 'PSLinear.UserNotFound*'
        }

        It 'writes one error when Linear rejects the project' {
            New-LinearProject 'reject' -Team ENG -ErrorAction SilentlyContinue -ErrorVariable projectErrors | Should -BeNullOrEmpty
            $projectErrors.Count | Should -Be 1
            $projectErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.ProjectCreateFailed*'
            $projectErrors[0].Exception.Message | Should -BeLike "Linear did not create project 'reject'.*Argument Validation Error*"
        }

        It 'rejects an invalid priority before sending anything' {
            { New-LinearProject 'Bad' -Team ENG -Priority Highest } | Should -Throw -ExpectedMessage "*'Highest' is not a priority*"
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Set-LinearProject' {
        It 'updates a project given by name and returns nothing' {
            $parameters = @{
                Name        = 'Site'
                Description = ''
                Content     = 'New content'
                Lead        = 'grace'
                Status      = 'completed'
                Priority    = '4'
                StartDate   = [datetime]'2026-09-15'
                TargetDate  = [datetime]'2027-01-31'
            }
            Set-LinearProject Website @parameters | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateProject' -and
                (Get-RequestVariable $Body 'id') -eq 'project-web' -and
                (Get-RequestVariable $Body 'input.name') -eq 'Site' -and
                (Get-RequestVariable $Body 'input.description') -eq '' -and
                (Get-RequestVariable $Body 'input.content') -eq 'New content' -and
                (Get-RequestVariable $Body 'input.leadId') -eq 'user-grace' -and
                (Get-RequestVariable $Body 'input.statusId') -eq 'pstatus-completed' -and
                (Get-RequestVariable $Body 'input.priority') -eq 4 -and
                (Get-RequestVariable $Body 'input.startDate') -eq '2026-09-15' -and
                (Get-RequestVariable $Body 'input.targetDate') -eq '2027-01-31'
            }
        }

        It 'returns the updated project with -PassThru' {
            $project = Set-LinearProject Website -Status planned -PassThru
            $project.PSObject.TypeNames | Should -Contain 'PSLinear.Project'
            $project.Status | Should -Be 'Planned'
        }

        It 'accepts slug ids and URLs' {
            Set-LinearProject 'f6e5d4c3b2a1', 'https://linear.app/acme/project/website-a1b2c3d4e5f6' -Priority Low
            foreach ($projectId in 'project-mobile', 'project-web') {
                Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                    (Get-RequestOperation $Body) -eq 'UpdateProject' -and (Get-RequestVariable $Body 'id') -eq $projectId
                }
            }
        }

        It 'updates piped projects by id' {
            Get-LinearProject | Set-LinearProject -Priority Urgent
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateProject' -and (Get-RequestVariable $Body 'input.priority') -eq 1
            }
        }

        It 'replaces teams, labels and members' {
            Set-LinearProject Website -Team OPS -Label Infrastructure -Member grace
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                ((Get-RequestVariable $Body 'input.teamIds') -join ',') -eq 'team-ops' -and
                ((Get-RequestVariable $Body 'input.labelIds') -join ',') -eq 'plabel-infra' -and
                ((Get-RequestVariable $Body 'input.memberIds') -join ',') -eq 'user-grace'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'GetProject' }
        }

        It 'adds and removes teams, labels and members, keeping the others' {
            Set-LinearProject Website -AddTeam OPS -AddLabel Infrastructure, Customer -RemoveMember grace -AddMember ada@example.com
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'GetProject' -and (Get-RequestVariable $Body 'id') -eq 'project-web'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateProject' -and
                ((Get-RequestVariable $Body 'input.teamIds') -join ',') -eq 'team-eng,team-ops' -and
                ((Get-RequestVariable $Body 'input.labelIds') -join ',') -eq 'plabel-customer,plabel-infra' -and
                ((Get-RequestVariable $Body 'input.memberIds') -join ',') -eq 'user-ada'
            }
        }

        It 'removes a team from a project with two' {
            Set-LinearProject 'Mobile App' -RemoveTeam ENG -RemoveLabel Customer
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateProject' -and
                ((Get-RequestVariable $Body 'input.teamIds') -join ',') -eq 'team-ops' -and
                @(Get-RequestVariable $Body 'input.labelIds').Count -eq 0
            }
        }

        It 'refuses to remove the last team and goes on with the next project' {
            Set-LinearProject Website, 'Mobile App' -RemoveTeam ENG -ErrorAction SilentlyContinue -ErrorVariable projectErrors
            $projectErrors.Count | Should -Be 1
            $projectErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.InvalidArgument*'
            $projectErrors[0].Exception.Message | Should -BeLike "*at least one team*project 'Website'*"
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateProject' -and (Get-RequestVariable $Body 'id') -eq 'project-mobile'
            }
        }

        It 'clears values with -Clear' {
            Set-LinearProject Website -Clear Lead, StartDate, TargetDate, Labels, Members
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $variables = (Get-RequestBody $Body).variables
                $projectInput = $variables['input']
                (Get-RequestOperation $Body) -eq 'UpdateProject' -and
                $projectInput.Contains('leadId') -and $null -eq $projectInput['leadId'] -and
                $projectInput.Contains('startDate') -and $null -eq $projectInput['startDate'] -and
                $projectInput.Contains('targetDate') -and $null -eq $projectInput['targetDate'] -and
                @($projectInput['labelIds']).Count -eq 0 -and @($projectInput['memberIds']).Count -eq 0
            }
        }

        It 'rejects conflicting parameters, or no change at all, before sending anything' {
            { Set-LinearProject Website -Label Customer -AddLabel Infrastructure } |
                Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage '*-Label to replace all labels, or -AddLabel and -RemoveLabel*'
            { Set-LinearProject Website -Team ENG -RemoveTeam OPS } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            { Set-LinearProject Website -Member grace -AddMember ada@example.com } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            { Set-LinearProject Website -Clear Lead -Lead me } | Should -Throw -ExpectedMessage 'Use either -Clear Lead or -Lead, not both.'
            { Set-LinearProject Website -Clear Members -RemoveMember grace } | Should -Throw -ExpectedMessage 'Use either -Clear Members or -RemoveMember, not both.'
            { Set-LinearProject Website } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage 'Specify at least one property to change*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'sends nothing with -WhatIf' {
            Set-LinearProject Website -Status completed -AddTeam OPS -WhatIf
            Get-LinearProject | Set-LinearProject -Lead me -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ListProjects' }
        }

        It 'forgets the cached projects only when the name changes' {
            InModuleScope PSLinear { $null = Get-LinearProjectCache }
            Set-LinearProject Website -Priority Low
            InModuleScope PSLinear { $script:LinearProjectCache } | Should -Not -BeNullOrEmpty
            Set-LinearProject Website -Name 'Site'
            InModuleScope PSLinear { $script:LinearProjectCache } | Should -BeNullOrEmpty
        }

        It 'stops with the valid names for an unknown project name' {
            { Set-LinearProject Intranet -Priority Low } |
                Should -Throw -ErrorId 'PSLinear.ProjectNotFound*' -ExpectedMessage "Project 'Intranet' was not found. Valid projects: Mobile App, Website."
        }

        It 'writes one error for a project Linear cannot update and goes on' {
            $missing = '00000000-0000-4000-8000-000000000000'
            Set-LinearProject $missing, Website -Priority Low -ErrorAction SilentlyContinue -ErrorVariable projectErrors
            $projectErrors.Count | Should -Be 1
            $projectErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.ProjectUpdateFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateProject' }
        }

        It 'writes one error when the project to merge into does not exist' {
            Set-LinearProject '00000000-0000-4000-8000-000000000000' -AddTeam OPS -ErrorAction SilentlyContinue -ErrorVariable projectErrors
            $projectErrors.Count | Should -Be 1
            $projectErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.ProjectNotFound*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateProject' }
        }
    }

    Context 'Remove-LinearProject' {
        It 'moves a project to the trash and forgets the cached projects' {
            InModuleScope PSLinear { $null = Get-LinearProjectCache }
            Remove-LinearProject Website -Confirm:$false | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'DeleteProject' -and (Get-RequestVariable $Body 'id') -eq 'project-web'
            }
            InModuleScope PSLinear { $script:LinearProjectCache } | Should -BeNullOrEmpty
        }

        It 'removes piped projects by id' {
            Get-LinearProject | Remove-LinearProject -Confirm:$false
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'DeleteProject' }
        }

        It 'sends nothing with -WhatIf' {
            Remove-LinearProject Website -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'writes one error for a project Linear cannot remove and goes on' {
            Remove-LinearProject '00000000-0000-4000-8000-000000000000', 'f6e5d4c3b2a1' -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable projectErrors
            $projectErrors.Count | Should -Be 1
            $projectErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.ProjectDeleteFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'DeleteProject' -and (Get-RequestVariable $Body 'id') -eq 'project-mobile'
            }
        }

        It 'stops for an unknown project name' {
            { Remove-LinearProject Intranet -Confirm:$false } | Should -Throw -ErrorId 'PSLinear.ProjectNotFound*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'DeleteProject' }
        }
    }

    Context 'Caches' {
        It 'Clear-LinearCache forgets project statuses and labels' {
            InModuleScope PSLinear {
                $null = Get-LinearProjectStatusCache
                $null = Get-LinearProjectLabelCache
                Clear-LinearCache
                $script:LinearProjectStatusCache | Should -BeNullOrEmpty
                $script:LinearProjectLabelCache | Should -BeNullOrEmpty
            }
        }

        It 'sorts project statuses by type, then position' {
            InModuleScope PSLinear { (Get-LinearProjectStatusCache).Name } |
                Should -Be @('Backlog', 'Planned', 'In Progress', 'Beta testing', 'Paused', 'Completed', 'Canceled')
        }

        It 'refreshes the status cache once when a name is not found' {
            $null = New-LinearProject 'One' -Team ENG -Status planned
            { New-LinearProject 'Two' -Team ENG -Status Shipped } | Should -Throw
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ListProjectStatuses' }
        }
    }
}
