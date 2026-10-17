BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Initiative commands' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $request = Get-RequestBody -Body $Body
            $lookup = Get-LinearTestLookupResponse -Request $request
            if ($lookup) { return $lookup }
            Get-LinearTestInitiativeResponse -Request $request
        }
    }

    Context 'Get-LinearInitiative' {
        It 'lists the initiatives as typed objects, sorted by name' {
            $initiatives = @(Get-LinearInitiative)
            $initiatives.Name | Should -Be @('Platform reliability', 'Q1 growth')
            $growth = $initiatives[1]
            $growth.PSObject.TypeNames | Should -Contain 'PSLinear.Initiative'
            $growth.Status | Should -Be 'Active'
            $growth.Health | Should -Be 'OnTrack'
            $growth.Priority | Should -Be 2
            $growth.PriorityLabel | Should -Be 'High'
            $growth.Owner | Should -Be 'Ada Lovelace'
            $growth.OwnerId | Should -Be 'user-ada'
            $growth.LeadTeam | Should -Be 'ENG'
            $growth.LeadTeamId | Should -Be 'team-eng'
            $growth.Projects | Should -Be @('Website')
            $growth.ProjectIds | Should -Be @('project-web')
            $growth.Labels | Should -Be @('Strategic')
            $growth.TargetDate | Should -Be '2027-03-31'
            $growth.Content | Should -BeNullOrEmpty
            $growth.SubInitiatives | Should -BeNullOrEmpty
            $initiatives[0].Owner | Should -BeNullOrEmpty
            $initiatives[0].Health | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListInitiatives' -and (Get-RequestVariable $Body 'includeArchived') -eq $false
            }
        }

        It 'filters by name with wildcards and reports names that match nothing' {
            (Get-LinearInitiative -Name 'q1*').Id | Should -Be 'initiative-growth'
            $initiatives = @(Get-LinearInitiative -Name 'Q1 growth', 'Moonshot' -ErrorAction SilentlyContinue -ErrorVariable initiativeErrors)
            $initiatives.Id | Should -Be @('initiative-growth')
            $initiativeErrors.Count | Should -Be 1
            $initiativeErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.InitiativeNotFound*'
        }

        It 'filters by status' {
            @(Get-LinearInitiative -Status Planned).Name | Should -Be @('Platform reliability')
            @(Get-LinearInitiative -Status Active, Planned).Count | Should -Be 2
            @(Get-LinearInitiative -Status Completed) | Should -BeNullOrEmpty
            { Get-LinearInitiative -Status Shipped } | Should -Throw
        }

        It 'includes archived initiatives with -IncludeArchived' {
            (Get-LinearInitiative -IncludeArchived -Status Completed).ArchivedAt | Should -Not -BeNullOrEmpty
        }

        It 'gets the full initiative by id, slug id or URL' {
            foreach ($value in 'initiative-growth', '5f2c9a1b7e3d', 'https://linear.app/acme/initiative/q1-growth-5f2c9a1b7e3d') {
                $initiative = Get-LinearInitiative -Id $value
                $initiative.Id | Should -Be 'initiative-growth'
                $initiative.Content | Should -Be "# Q1 growth`nPlan"
                $initiative.SubInitiatives | Should -Be @('Growth: EMEA')
                $initiative.Projects | Should -Be @('Website')
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'GetInitiative' -and (Get-RequestVariable $Body 'id') -eq '5f2c9a1b7e3d'
            }
        }

        It 'writes one error for a missing initiative and returns the others' {
            $initiatives = @(Get-LinearInitiative -Id 'initiative-growth', 'nope' -ErrorAction SilentlyContinue -ErrorVariable initiativeErrors)
            $initiatives.Id | Should -Be @('initiative-growth')
            $initiativeErrors.Count | Should -Be 1
            $initiativeErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.InitiativeNotFound*'
        }

        It 'returns piped initiatives in full' {
            $initiatives = @(Get-LinearInitiative | Get-LinearInitiative)
            $initiatives[1].SubInitiatives | Should -Be @('Growth: EMEA')
            $initiatives[0].SubInitiatives.Count | Should -Be 0
        }
    }

    Context 'New-LinearInitiative' {
        It 'creates an initiative, resolving names to ids' {
            $initiative = New-LinearInitiative 'Q2 bets' -Description 'Short' -Content '# Bets' -Owner grace -LeadTeam ops -Status Proposed `
                -Priority Urgent -TargetDate '2027-06-30' -Label Bets, Strategic
            $initiative.PSObject.TypeNames | Should -Contain 'PSLinear.Initiative'
            $initiative.Name | Should -Be 'Q2 bets'
            $initiative.Owner | Should -Be 'Grace Hopper'
            $initiative.LeadTeam | Should -Be 'OPS'
            $initiative.Labels | Should -Be @('Bets', 'Strategic')
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateInitiative' -and
                (Get-RequestVariable $Body 'input.name') -eq 'Q2 bets' -and
                (Get-RequestVariable $Body 'input.description') -eq 'Short' -and
                (Get-RequestVariable $Body 'input.content') -eq '# Bets' -and
                (Get-RequestVariable $Body 'input.ownerId') -eq 'user-grace' -and
                (Get-RequestVariable $Body 'input.leadTeamId') -eq 'team-ops' -and
                (Get-RequestVariable $Body 'input.status') -eq 'Proposed' -and
                (Get-RequestVariable $Body 'input.priority') -eq 1 -and
                (Get-RequestVariable $Body 'input.targetDate') -eq '2027-06-30' -and
                ((Get-RequestVariable $Body 'input.labelIds') -join ',') -eq 'ilabel-bets,ilabel-strategic'
            }
        }

        It 'sends only the name when nothing else is given, and forgets the cached initiatives' {
            InModuleScope PSLinear { $null = Get-LinearInitiativeCache }
            $null = New-LinearInitiative 'Plain'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateInitiative' -and (@((Get-RequestBody $Body).variables.input.Keys) -join ',') -eq 'name'
            }
            InModuleScope PSLinear { $script:LinearInitiativeCache } | Should -BeNullOrEmpty
        }

        It 'sends nothing with -WhatIf' {
            New-LinearInitiative 'Never' -Owner me -Label Bets -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'stops with the valid labels for an unknown, retired or group label' {
            foreach ($label in 'Nope', 'Legacy', 'Horizon') {
                { New-LinearInitiative 'Bad' -Label $label } |
                    Should -Throw -ErrorId 'PSLinear.LabelNotFound*' -ExpectedMessage "Initiative label '$label' was not found. Valid initiative labels: Bets, Now, Strategic."
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'CreateInitiative' }
        }

        It 'rejects an unknown status before sending anything' {
            { New-LinearInitiative 'Bad' -Status Shipped } | Should -Throw
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'writes one error when Linear rejects the initiative' {
            New-LinearInitiative 'reject' -ErrorAction SilentlyContinue -ErrorVariable initiativeErrors | Should -BeNullOrEmpty
            $initiativeErrors.Count | Should -Be 1
            $initiativeErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.InitiativeCreateFailed*'
        }
    }

    Context 'Set-LinearInitiative' {
        It 'updates an initiative given by name and returns nothing' {
            Set-LinearInitiative 'Q1 growth' -Name 'Q1 growth (EU)' -Description '' -Owner grace -LeadTeam OPS -Status Completed -Priority Low -TargetDate '2027-04-30' |
                Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateInitiative' -and
                (Get-RequestVariable $Body 'id') -eq 'initiative-growth' -and
                (Get-RequestVariable $Body 'input.name') -eq 'Q1 growth (EU)' -and
                (Get-RequestVariable $Body 'input.description') -eq '' -and
                (Get-RequestVariable $Body 'input.ownerId') -eq 'user-grace' -and
                (Get-RequestVariable $Body 'input.leadTeamId') -eq 'team-ops' -and
                (Get-RequestVariable $Body 'input.status') -eq 'Completed' -and
                (Get-RequestVariable $Body 'input.priority') -eq 4 -and
                (Get-RequestVariable $Body 'input.targetDate') -eq '2027-04-30'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'GetInitiative' }
        }

        It 'returns the updated initiative with -PassThru, and accepts slug ids and URLs' {
            (Set-LinearInitiative '7a8b9c0d1e2f' -Status Active -PassThru).Status | Should -Be 'Active'
            Set-LinearInitiative 'https://linear.app/acme/initiative/q1-growth-5f2c9a1b7e3d' -Priority High
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateInitiative' -and (Get-RequestVariable $Body 'id') -eq 'initiative-growth'
            }
        }

        It 'updates piped initiatives by id' {
            Get-LinearInitiative | Set-LinearInitiative -Status Active
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateInitiative' }
        }

        It 'replaces labels, or adds and removes them keeping the others' {
            Set-LinearInitiative 'Q1 growth' -Label Now
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                ((Get-RequestVariable $Body 'input.labelIds') -join ',') -eq 'ilabel-now'
            }
            Set-LinearInitiative 'Q1 growth' -AddLabel Bets -RemoveLabel Strategic
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateInitiative' -and ((Get-RequestVariable $Body 'input.labelIds') -join ',') -eq 'ilabel-bets'
            }
        }

        It 'clears values with -Clear' {
            Set-LinearInitiative 'Q1 growth' -Clear Owner, LeadTeam, TargetDate, Labels
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $initiativeInput = (Get-RequestBody $Body).variables['input']
                (Get-RequestOperation $Body) -eq 'UpdateInitiative' -and
                $initiativeInput.Contains('ownerId') -and $null -eq $initiativeInput['ownerId'] -and
                $initiativeInput.Contains('leadTeamId') -and $null -eq $initiativeInput['leadTeamId'] -and
                $initiativeInput.Contains('targetDate') -and $null -eq $initiativeInput['targetDate'] -and
                @($initiativeInput['labelIds']).Count -eq 0
            }
        }

        It 'adds projects, skipping those already in the initiative, without updating fields' {
            Set-LinearInitiative 'Q1 growth' -AddProject Website, 'Mobile App'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateInitiativeToProject' -and
                (Get-RequestVariable $Body 'input.initiativeId') -eq 'initiative-growth' -and
                (Get-RequestVariable $Body 'input.projectId') -eq 'project-mobile'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'CreateInitiativeToProject' }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateInitiative' }
        }

        It 'removes a project through its link, and ignores projects that are not in the initiative' {
            Set-LinearInitiative 'Q1 growth' -RemoveProject Website, 'Mobile App'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListProjectInitiativeLinks' -and (Get-RequestVariable $Body 'id') -eq 'project-web'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'DeleteInitiativeToProject' -and (Get-RequestVariable $Body 'id') -eq 'link-web-growth'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'DeleteInitiativeToProject' }
        }

        It 'returns the initiative fetched again after project changes with -PassThru' {
            $initiative = Set-LinearInitiative 'Q1 growth' -Status Completed -AddProject 'Mobile App' -PassThru
            $initiative.Id | Should -Be 'initiative-growth'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'GetInitiative' }
        }

        It 'writes one error for a project Linear will not add and goes on' {
            Set-LinearInitiative 'Platform reliability' -AddProject '00000000-0000-4000-8000-000000000000', Website -ErrorAction SilentlyContinue -ErrorVariable initiativeErrors
            $initiativeErrors.Count | Should -Be 1
            $initiativeErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.InitiativeProjectAddFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'CreateInitiativeToProject' }
        }

        It 'rejects conflicting parameters, or no change at all, before sending anything' {
            { Set-LinearInitiative 'Q1 growth' -Label Bets -AddLabel Now } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            { Set-LinearInitiative 'Q1 growth' -Clear Owner -Owner me } | Should -Throw -ExpectedMessage 'Use either -Clear Owner or -Owner, not both.'
            { Set-LinearInitiative 'Q1 growth' -Clear Labels -RemoveLabel Bets } | Should -Throw -ExpectedMessage 'Use either -Clear Labels or -RemoveLabel, not both.'
            { Set-LinearInitiative 'Q1 growth' } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage 'Specify at least one property to change*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'sends nothing with -WhatIf' {
            Set-LinearInitiative 'Q1 growth' -Status Completed -AddProject Website -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'forgets the cached initiatives only when the name changes' {
            InModuleScope PSLinear { $null = Get-LinearInitiativeCache }
            Set-LinearInitiative 'Q1 growth' -Priority Low
            InModuleScope PSLinear { $script:LinearInitiativeCache } | Should -Not -BeNullOrEmpty
            Set-LinearInitiative 'Q1 growth' -Name 'Growth'
            InModuleScope PSLinear { $script:LinearInitiativeCache } | Should -BeNullOrEmpty
        }

        It 'stops with the valid names for an unknown initiative name' {
            { Set-LinearInitiative Moonshot -Priority Low } |
                Should -Throw -ErrorId 'PSLinear.InitiativeNotFound*' -ExpectedMessage "Initiative 'Moonshot' was not found. Valid initiatives: Platform reliability, Q1 growth."
        }

        It 'writes one error for an initiative Linear cannot update and goes on' {
            Set-LinearInitiative '00000000-0000-4000-8000-000000000000', 'Q1 growth' -Priority Low -ErrorAction SilentlyContinue -ErrorVariable initiativeErrors
            $initiativeErrors.Count | Should -Be 1
            $initiativeErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.InitiativeUpdateFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateInitiative' }
        }
    }

    Context 'Remove-LinearInitiative' {
        It 'moves an initiative to the trash and forgets the cached initiatives' {
            InModuleScope PSLinear { $null = Get-LinearInitiativeCache }
            Remove-LinearInitiative 'Q1 growth' -Confirm:$false | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'DeleteInitiative' -and (Get-RequestVariable $Body 'id') -eq 'initiative-growth'
            }
            InModuleScope PSLinear { $script:LinearInitiativeCache } | Should -BeNullOrEmpty
        }

        It 'archives piped initiatives with -Archive' {
            Get-LinearInitiative | Remove-LinearInitiative -Archive -Confirm:$false
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ArchiveInitiative' }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'DeleteInitiative' }
        }

        It 'sends nothing with -WhatIf' {
            Remove-LinearInitiative 'Q1 growth' -WhatIf
            Remove-LinearInitiative 'Q1 growth' -Archive -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'writes one error for an initiative Linear cannot remove and goes on' {
            Remove-LinearInitiative '00000000-0000-4000-8000-000000000000', '7a8b9c0d1e2f' -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable initiativeErrors
            $initiativeErrors.Count | Should -Be 1
            $initiativeErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.InitiativeDeleteFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'DeleteInitiative' -and (Get-RequestVariable $Body 'id') -eq 'initiative-reliability'
            }
        }

        It 'stops for an unknown initiative name' {
            { Remove-LinearInitiative Moonshot -Confirm:$false } | Should -Throw -ErrorId 'PSLinear.InitiativeNotFound*'
        }
    }

    Context 'Caches' {
        It 'Clear-LinearCache forgets initiatives and initiative labels' {
            InModuleScope PSLinear {
                $null = Get-LinearInitiativeCache
                $null = Get-LinearInitiativeLabelCache
                Clear-LinearCache
                $script:LinearInitiativeCache | Should -BeNullOrEmpty
                $script:LinearInitiativeLabelCache | Should -BeNullOrEmpty
            }
        }

        It 'resolves initiatives by name, case-insensitively, and refreshes once when a name is not found' {
            InModuleScope PSLinear { Resolve-LinearInitiativeId -Initiative 'q1 GROWTH' } | Should -Be 'initiative-growth'
            { InModuleScope PSLinear { Resolve-LinearInitiativeId -Initiative 'Moonshot' } } | Should -Throw
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ListInitiatives' }
        }
    }
}
