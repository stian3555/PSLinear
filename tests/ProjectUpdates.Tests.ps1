BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Project update commands' {
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

    Context 'Get-LinearProjectUpdate' {
        It 'lists a project''s updates, newest first, as typed objects' {
            $updates = @(Get-LinearProjectUpdate -Project Website)
            $updates.Id | Should -Be @('update-2', 'update-1')
            $updates[0].PSObject.TypeNames | Should -Contain 'PSLinear.ProjectUpdate'
            $updates[0].Health | Should -Be 'AtRisk'
            $updates[1].Health | Should -Be 'OnTrack'
            $updates[0].Project | Should -Be 'Website'
            $updates[0].ProjectId | Should -Be 'project-web'
            $updates[0].Author | Should -Be 'Ada Lovelace'
            $updates[0].AuthorId | Should -Be 'user-ada'
            $updates[0].Body | Should -Be "Slipping`nWaiting on design"
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListProjectUpdates' -and (Get-RequestVariable $Body 'filter.project.id.eq') -eq 'project-web'
            }
        }

        It 'lists every update in the workspace without -Project' {
            $updates = @(Get-LinearProjectUpdate)
            $updates.Id | Should -Be @('update-2', 'update-1', 'update-m1')
            $updates[2].Health | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListProjectUpdates' -and $null -eq (Get-RequestVariable $Body 'filter')
            }
        }

        It 'returns only the newest updates with -First' {
            @(Get-LinearProjectUpdate -Project Website -First 1).Id | Should -Be @('update-2')
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListProjectUpdates' -and (Get-RequestVariable $Body 'first') -eq 1
            }
        }

        It 'takes projects and issues from the pipeline' {
            @(Get-LinearProject -Name 'Mobile App' | Get-LinearProjectUpdate).Id | Should -Be @('update-m1')
            $issue = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-1'; Identifier = 'ENG-1'; Project = 'Website' }
            @($issue | Get-LinearProjectUpdate).Id | Should -Be @('update-2', 'update-1')
        }

        It 'gets updates by id, writing one error for a missing one' {
            $updates = @(Get-LinearProjectUpdate -Id 'update-1', 'missing' -ErrorAction SilentlyContinue -ErrorVariable updateErrors)
            $updates.Id | Should -Be @('update-1')
            $updateErrors.Count | Should -Be 1
            $updateErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.ProjectUpdateNotFound*'
        }

        It 'stops with the valid names for an unknown project' {
            { Get-LinearProjectUpdate -Project Intranet } |
                Should -Throw -ErrorId 'PSLinear.ProjectNotFound*' -ExpectedMessage "Project 'Intranet' was not found. Valid projects: Mobile App, Website."
        }
    }

    Context 'New-LinearProjectUpdate' {
        It 'posts an update with a body and health' {
            $update = New-LinearProjectUpdate -Project Website 'Build started' -Health AtRisk
            $update.PSObject.TypeNames | Should -Contain 'PSLinear.ProjectUpdate'
            $update.Health | Should -Be 'AtRisk'
            $update.Body | Should -Be 'Build started'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateProjectUpdate' -and
                (Get-RequestVariable $Body 'input.projectId') -eq 'project-web' -and
                (Get-RequestVariable $Body 'input.body') -eq 'Build started' -and
                (Get-RequestVariable $Body 'input.health') -eq 'atRisk'
            }
        }

        It 'posts a health-only update with an empty body, which Linear requires' {
            $null = New-LinearProjectUpdate -Project 'a1b2c3d4e5f6' -Health OffTrack
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateProjectUpdate' -and
                (Get-RequestVariable $Body 'input.health') -eq 'offTrack' -and
                (Get-RequestBody $Body).variables.input['body'] -eq ''
            }
        }

        It 'sends no health when only a body is given' {
            $null = New-LinearProjectUpdate -Project Website 'Just text'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateProjectUpdate' -and -not (Get-RequestBody $Body).variables.input.Contains('health')
            }
        }

        It 'takes the project from piped PSLinear.Project objects' {
            (Get-LinearProject -Name 'Mobile App' | New-LinearProjectUpdate -Body 'Kickoff done').Project | Should -Be 'Mobile App'
        }

        It 'needs a body or a health' {
            { New-LinearProjectUpdate -Project Website } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage 'Specify -Body, -Health or both.'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'rejects an unknown health before sending anything' {
            { New-LinearProjectUpdate -Project Website -Health Great } | Should -Throw
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'sends nothing with -WhatIf' {
            New-LinearProjectUpdate -Project Website 'x' -Health OnTrack -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'writes one error when Linear rejects the update' {
            New-LinearProjectUpdate -Project Website 'reject' -ErrorAction SilentlyContinue -ErrorVariable updateErrors | Should -BeNullOrEmpty
            $updateErrors.Count | Should -Be 1
            $updateErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.ProjectUpdateCreateFailed*'
        }
    }

    Context 'Set-LinearProjectUpdate' {
        It 'changes the health and returns nothing' {
            Set-LinearProjectUpdate -Id update-1 -Health OffTrack | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateProjectUpdate' -and
                (Get-RequestVariable $Body 'id') -eq 'update-1' -and
                (Get-RequestVariable $Body 'input.health') -eq 'offTrack' -and
                -not (Get-RequestBody $Body).variables.input.Contains('body')
            }
        }

        It 'returns the edited update with -PassThru' {
            $update = Set-LinearProjectUpdate update-2 -Body 'Back on track' -Health OnTrack -PassThru
            $update.Body | Should -Be 'Back on track'
            $update.Health | Should -Be 'OnTrack'
            $update.EditedAt | Should -Not -BeNullOrEmpty
        }

        It 'edits piped updates and writes one error for a missing one' {
            Get-LinearProjectUpdate -Project Website | Set-LinearProjectUpdate -Body 'Edited'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateProjectUpdate' }
            'missing', 'update-1' | Set-LinearProjectUpdate -Body 'x' -ErrorAction SilentlyContinue -ErrorVariable updateErrors
            $updateErrors.Count | Should -Be 1
            $updateErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.ProjectUpdateUpdateFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 4 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateProjectUpdate' }
        }

        It 'needs a change and sends nothing with -WhatIf' {
            { Set-LinearProjectUpdate -Id update-1 } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            Set-LinearProjectUpdate -Id update-1 -Health AtRisk -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Remove-LinearProjectUpdate' {
        It 'archives an update' {
            Remove-LinearProjectUpdate -Id update-1 -Confirm:$false | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ArchiveProjectUpdate' -and (Get-RequestVariable $Body 'id') -eq 'update-1'
            }
        }

        It 'removes piped updates and writes one error for a missing one' {
            Get-LinearProjectUpdate -Project Website | Remove-LinearProjectUpdate -Confirm:$false
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ArchiveProjectUpdate' }
            Remove-LinearProjectUpdate -Id 'missing' -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable updateErrors
            $updateErrors.Count | Should -Be 1
            $updateErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.ProjectUpdateDeleteFailed*'
        }

        It 'sends nothing with -WhatIf' {
            Remove-LinearProjectUpdate -Id update-1 -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }
}
