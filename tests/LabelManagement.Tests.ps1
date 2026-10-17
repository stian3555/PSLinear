BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Label management commands' {
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

    Context 'Get-LinearLabel -IncludeGroups and -IncludeRetired' {
        It 'adds label groups and retired labels on request' {
            @(Get-LinearLabel).Name | Should -Not -Contain 'Area'
            @(Get-LinearLabel -IncludeGroups).Name | Should -Contain 'Area'
            @(Get-LinearLabel -IncludeGroups).Name | Should -Not -Contain 'Old'
            (Get-LinearLabel -IncludeRetired -Name Old).RetiredAt | Should -Not -BeNullOrEmpty
            (Get-LinearLabel -IncludeGroups -Name Area).IsGroup | Should -BeTrue
        }

        It 'works with -Team, keeping the team lineage' {
            $names = @(Get-LinearLabel -Team ENG -IncludeGroups -IncludeRetired).Name
            $names | Should -Contain 'Backend'
            $names | Should -Contain 'Area'
            $names | Should -Not -Contain 'Incident'
        }

        It 'exposes the group id of labels in a group' {
            (Get-LinearLabel -Name Frontend -Team ENG).GroupId | Should -Be 'label-area'
        }
    }

    Context 'New-LinearLabel' {
        It 'creates a workspace label with color and description' {
            $label = New-LinearLabel 'Needs design' -Color '#F2994A' -Description 'Waiting on design'
            $label.PSObject.TypeNames | Should -Contain 'PSLinear.Label'
            $label.Name | Should -Be 'Needs design'
            $label.Team | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateIssueLabel' -and
                (Get-RequestVariable $Body 'input.name') -eq 'Needs design' -and
                (Get-RequestVariable $Body 'input.color') -eq '#F2994A' -and
                (Get-RequestVariable $Body 'input.description') -eq 'Waiting on design' -and
                -not (Get-RequestBody $Body).variables.input.Contains('teamId')
            }
        }

        It 'creates a team label in a workspace group, and label groups' {
            $label = New-LinearLabel 'Mobile' -Team ENG -Group Area
            $label.Team | Should -Be 'ENG'
            $label.Group | Should -Be 'Area'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateIssueLabel' -and
                (Get-RequestVariable $Body 'input.teamId') -eq 'team-eng' -and (Get-RequestVariable $Body 'input.parentId') -eq 'label-area'
            }
            (New-LinearLabel 'Platform' -IsGroup).IsGroup | Should -BeTrue
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestVariable $Body 'input.isGroup') -eq $true }
        }

        It 'forgets the cached labels so the new label can be used right away' {
            InModuleScope PSLinear { $null = Get-LinearLabelCache -TeamId 'team-eng' }
            $null = New-LinearLabel 'Fresh' -Team ENG
            InModuleScope PSLinear { $script:LinearLabelCache.Count } | Should -Be 0
        }

        It 'stops with the valid groups for a group that does not exist or is not a group' {
            { New-LinearLabel 'x' -Group Bug } |
                Should -Throw -ErrorId 'PSLinear.LabelNotFound*' -ExpectedMessage "Label group 'Bug' was not found in the workspace. Valid label groups: Area."
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'CreateIssueLabel' }
        }

        It 'rejects an invalid color, and sends nothing with -WhatIf' {
            { New-LinearLabel 'x' -Color red } | Should -Throw -ExpectedMessage "*'red' is not a hex color*"
            New-LinearLabel 'x' -Team ENG -Group Area -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'writes one error when Linear rejects the label' {
            New-LinearLabel 'reject' -ErrorAction SilentlyContinue -ErrorVariable labelErrors | Should -BeNullOrEmpty
            $labelErrors.Count | Should -Be 1
            $labelErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.LabelCreateFailed*'
        }
    }

    Context 'Set-LinearLabel' {
        It 'changes a workspace label by name and returns nothing' {
            Set-LinearLabel Bug -Name 'Defect' -Color '#EB5757' -Description '' | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateIssueLabel' -and
                (Get-RequestVariable $Body 'id') -eq 'label-bug' -and
                (Get-RequestVariable $Body 'input.name') -eq 'Defect' -and
                (Get-RequestVariable $Body 'input.color') -eq '#EB5757' -and
                (Get-RequestVariable $Body 'input.description') -eq ''
            }
        }

        It 'looks names up in a team''s own labels with -Team, and accepts Group/Name' {
            Set-LinearLabel Backend -Team ENG -Color '#000001'
            Set-LinearLabel 'Area/Frontend' -Color '#000002'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateIssueLabel' -and (Get-RequestVariable $Body 'id') -eq 'label-eng-backend'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateIssueLabel' -and (Get-RequestVariable $Body 'id') -eq 'label-frontend'
            }
        }

        It 'does not find team labels without -Team, and lists the valid names' {
            { Set-LinearLabel Backend -Color '#000001' } |
                Should -Throw -ErrorId 'PSLinear.LabelNotFound*' -ExpectedMessage "Label 'Backend' was not found in the workspace. Valid labels: Area, Bug, Feature, Area/Frontend, Old."
        }

        It 'retires and restores labels, and moves them in and out of groups' {
            Set-LinearLabel Bug -Retire
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                # ConvertFrom-Json turns the ISO 8601 timestamp back into a DateTime.
                $retiredAt = Get-RequestVariable $Body 'input.retiredAt'
                $null -ne $retiredAt -and ([datetime]::UtcNow - ([datetime]$retiredAt).ToUniversalTime()).TotalMinutes -lt 5
            }
            Set-LinearLabel Old -Restore
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $labelInput = (Get-RequestBody $Body).variables['input']
                (Get-RequestVariable $Body 'id') -eq 'label-old' -and $labelInput.Contains('retiredAt') -and $null -eq $labelInput['retiredAt']
            }
            Set-LinearLabel Feature -Group Area
            Set-LinearLabel 'Area/Frontend' -Clear Group
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestVariable $Body 'id') -eq 'label-feature' -and (Get-RequestVariable $Body 'input.parentId') -eq 'label-area'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $labelInput = (Get-RequestBody $Body).variables['input']
                (Get-RequestVariable $Body 'id') -eq 'label-frontend' -and $labelInput.Contains('parentId') -and $null -eq $labelInput['parentId']
            }
        }

        It 'updates piped labels by id and returns them with -PassThru' {
            $labels = @(Get-LinearLabel -Team ENG | Set-LinearLabel -Color '#123456' -PassThru)
            $labels.Count | Should -Be 4
            $labels[0].PSObject.TypeNames | Should -Contain 'PSLinear.Label'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListIssueLabels' -and $null -ne (Get-RequestVariable $Body 'filter.team')
            }
        }

        It 'rejects conflicting parameters, or no change at all, before sending anything' {
            { Set-LinearLabel Bug -Retire -Restore } | Should -Throw -ExpectedMessage 'Use either -Retire or -Restore, not both.'
            { Set-LinearLabel Bug -Group Area -Clear Group } | Should -Throw -ExpectedMessage 'Use either -Clear Group or -Group, not both.'
            { Set-LinearLabel Bug } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            Set-LinearLabel Bug -Name x -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'writes one error for a label Linear cannot update and goes on' {
            Set-LinearLabel '00000000-0000-4000-8000-000000000000', Bug -Color '#000000' -ErrorAction SilentlyContinue -ErrorVariable labelErrors
            $labelErrors.Count | Should -Be 1
            $labelErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.LabelUpdateFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateIssueLabel' }
        }
    }

    Context 'Remove-LinearLabel' {
        It 'deletes labels by name, in a team, and piped' {
            Remove-LinearLabel Bug -Confirm:$false | Should -BeNullOrEmpty
            Remove-LinearLabel Incident -Team OPS -Confirm:$false
            Get-LinearLabel -Team ENG -Name Backend | Remove-LinearLabel -Confirm:$false
            foreach ($labelId in 'label-bug', 'label-ops-incident', 'label-eng-backend') {
                Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                    (Get-RequestOperation $Body) -eq 'DeleteIssueLabel' -and (Get-RequestVariable $Body 'id') -eq $labelId
                }
            }
        }

        It 'writes one error for a label Linear cannot delete and goes on, and forgets the cache' {
            InModuleScope PSLinear { $null = Get-LinearLabelCache -TeamId 'team-eng' }
            Remove-LinearLabel '00000000-0000-4000-8000-000000000000', Feature -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable labelErrors
            $labelErrors.Count | Should -Be 1
            $labelErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.LabelDeleteFailed*'
            InModuleScope PSLinear { $script:LinearLabelCache.Count } | Should -Be 0
        }

        It 'stops for an unknown name and sends nothing with -WhatIf' {
            { Remove-LinearLabel Nope -Confirm:$false } | Should -Throw -ErrorId 'PSLinear.LabelNotFound*'
            Remove-LinearLabel Bug -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'DeleteIssueLabel' }
        }
    }
}
