BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Milestone commands' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestLookupResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    Context 'Get-LinearMilestone' {
        It 'lists a project''s milestones in order, as typed objects' {
            $milestones = @(Get-LinearMilestone -Project Website)
            $milestones.Name | Should -Be @('Alpha', 'Beta')
            $milestones[0].PSObject.TypeNames | Should -Contain 'PSLinear.Milestone'
            $milestones[0].Status | Should -Be 'Done'
            $milestones[1].Status | Should -Be 'Next'
            $milestones[1].Project | Should -Be 'Website'
            $milestones[1].TargetDate | Should -Be '2026-12-01'
        }

        It 'lists every milestone without -Project' {
            @(Get-LinearMilestone).Count | Should -Be 2
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListProjectMilestones' -and $null -eq (Get-RequestVariable $Body 'filter')
            }
        }

        It 'takes projects and issues from the pipeline' {
            $project = [pscustomobject]@{ PSTypeName = 'PSLinear.Project'; Id = 'project-web'; Name = 'Website'; SlugId = 'a1b2c3d4e5f6' }
            @($project | Get-LinearMilestone).Count | Should -Be 2
            $issue = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-1'; Identifier = 'ENG-1'; Project = 'Website' }
            @($issue | Get-LinearMilestone).Count | Should -Be 2
        }

        It 'filters by name and reports names that match nothing' {
            $milestones = @(Get-LinearMilestone -Project Website -Name 'B*', 'GA' -ErrorAction SilentlyContinue -ErrorVariable milestoneErrors)
            $milestones.Name | Should -Be @('Beta')
            $milestoneErrors.Count | Should -Be 1
            $milestoneErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.MilestoneNotFound*'
        }

        It 'gets milestones by id, writing one error for a missing one' {
            $milestones = @(Get-LinearMilestone -Id 'milestone-beta', 'missing' -ErrorAction SilentlyContinue -ErrorVariable milestoneErrors)
            $milestones.Id | Should -Be @('milestone-beta')
            $milestoneErrors.Count | Should -Be 1
        }
    }

    Context 'New-LinearMilestone' {
        It 'creates a milestone in a project, and forgets the cached milestones' {
            InModuleScope PSLinear { $null = Get-LinearMilestoneCache -ProjectId 'project-web' }
            $milestone = New-LinearMilestone -Project Website -Name 'GA' -TargetDate '2027-01-15' -Description 'Launch' -SortOrder 5
            $milestone.Name | Should -Be 'GA'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateProjectMilestone' -and
                (Get-RequestVariable $Body 'input.projectId') -eq 'project-web' -and
                (Get-RequestVariable $Body 'input.name') -eq 'GA' -and
                (Get-RequestVariable $Body 'input.targetDate') -eq '2027-01-15' -and
                (Get-RequestVariable $Body 'input.description') -eq 'Launch' -and
                (Get-RequestVariable $Body 'input.sortOrder') -eq 5
            }
            InModuleScope PSLinear { $script:LinearMilestoneCache.ContainsKey('project-web') } | Should -BeFalse
        }

        It 'takes the project from piped PSLinear.Project objects' {
            $project = [pscustomobject]@{ PSTypeName = 'PSLinear.Project'; Id = 'project-mobile'; Name = 'Mobile App'; SlugId = 'f6e5d4c3b2a1' }
            ($project | New-LinearMilestone -Name 'Store review').Project | Should -Be 'Mobile App'
        }

        It 'sends nothing with -WhatIf and writes one error when Linear rejects it' {
            New-LinearMilestone -Project Website -Name 'GA' -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
            New-LinearMilestone -Project Website -Name 'reject' -ErrorAction SilentlyContinue -ErrorVariable milestoneErrors | Should -BeNullOrEmpty
            $milestoneErrors.Count | Should -Be 1
            $milestoneErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.MilestoneCreateFailed*'
        }

        It 'stops on an unknown project' {
            { New-LinearMilestone -Project Intranet -Name 'GA' } | Should -Throw -ErrorId 'PSLinear.ProjectNotFound*'
        }
    }

    Context 'Set-LinearMilestone' {
        It 'renames a milestone and returns nothing' {
            Set-LinearMilestone -Id milestone-beta -Name 'Public beta' | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateProjectMilestone' -and
                (Get-RequestVariable $Body 'id') -eq 'milestone-beta' -and
                (Get-RequestVariable $Body 'input.name') -eq 'Public beta'
            }
        }

        It 'clears the target date, moves to another project and returns the milestone with -PassThru' {
            $milestone = Set-LinearMilestone -Id milestone-beta -Clear TargetDate -Project 'Mobile App' -PassThru
            $milestone.Project | Should -Be 'Mobile App'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $milestoneInput = Get-RequestVariable $Body 'input'
                $null -ne $milestoneInput -and $milestoneInput.Contains('targetDate') -and $null -eq $milestoneInput['targetDate'] -and
                $milestoneInput['projectId'] -eq 'project-mobile'
            }
        }

        It 'updates piped milestones and forgets their project''s cached milestones' {
            InModuleScope PSLinear { $null = Get-LinearMilestoneCache -ProjectId 'project-web' }
            Get-LinearMilestone -Project Website | Set-LinearMilestone -TargetDate '2027-02-01'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateProjectMilestone' }
            InModuleScope PSLinear { $script:LinearMilestoneCache.ContainsKey('project-web') } | Should -BeFalse
        }

        It 'rejects conflicting or missing changes before sending anything' {
            { Set-LinearMilestone -Id milestone-beta -TargetDate '2027-01-01' -Clear TargetDate } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            { Set-LinearMilestone -Id milestone-beta } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'writes one error for a missing milestone and updates the rest' {
            $updated = @('missing', 'milestone-beta' | Set-LinearMilestone -Name 'x' -PassThru -ErrorAction SilentlyContinue -ErrorVariable milestoneErrors)
            $updated.Id | Should -Be @('milestone-beta')
            $milestoneErrors.Count | Should -Be 1
            $milestoneErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.MilestoneUpdateFailed*'
        }

        It 'sends nothing with -WhatIf' {
            'milestone-alpha', 'milestone-beta' | Set-LinearMilestone -Name 'x' -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Remove-LinearMilestone' {
        It 'deletes a milestone, after confirmation is skipped' {
            Remove-LinearMilestone -Id milestone-beta -Confirm:$false | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'DeleteProjectMilestone' -and (Get-RequestVariable $Body 'id') -eq 'milestone-beta'
            }
        }

        It 'deletes piped milestones and writes one error for a missing one' {
            Get-LinearMilestone -Project Website | Remove-LinearMilestone -Confirm:$false
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'DeleteProjectMilestone' }
            'missing' | Remove-LinearMilestone -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable milestoneErrors
            $milestoneErrors.Count | Should -Be 1
            $milestoneErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.MilestoneDeleteFailed*'
        }

        It 'sends nothing with -WhatIf' {
            Remove-LinearMilestone -Id milestone-beta -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }
}
