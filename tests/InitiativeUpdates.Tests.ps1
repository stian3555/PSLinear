BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Initiative update commands' {
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

    Context 'Get-LinearInitiativeUpdate' {
        It 'lists an initiative''s updates, newest first, as typed objects' {
            $updates = @(Get-LinearInitiativeUpdate -Initiative 'Q1 growth')
            $updates.Id | Should -Be @('iupdate-2', 'iupdate-1')
            $updates[0].PSObject.TypeNames | Should -Contain 'PSLinear.InitiativeUpdate'
            $updates[0].Health | Should -Be 'AtRisk'
            $updates[0].Initiative | Should -Be 'Q1 growth'
            $updates[0].InitiativeId | Should -Be 'initiative-growth'
            $updates[0].Author | Should -Be 'Ada Lovelace'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListInitiativeUpdates' -and (Get-RequestVariable $Body 'filter.initiative.id.eq') -eq 'initiative-growth'
            }
        }

        It 'lists every update without -Initiative, and only the newest with -First' {
            @(Get-LinearInitiativeUpdate).Id | Should -Be @('iupdate-2', 'iupdate-1', 'iupdate-r1')
            @(Get-LinearInitiativeUpdate -Initiative 'Q1 growth' -First 1).Id | Should -Be @('iupdate-2')
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListInitiativeUpdates' -and (Get-RequestVariable $Body 'first') -eq 1
            }
        }

        It 'takes initiatives from the pipeline' {
            @(Get-LinearInitiative -Name 'Platform reliability' | Get-LinearInitiativeUpdate).Id | Should -Be @('iupdate-r1')
        }

        It 'gets updates by id, writing one error for a missing one' {
            $updates = @(Get-LinearInitiativeUpdate -Id 'iupdate-1', 'missing' -ErrorAction SilentlyContinue -ErrorVariable updateErrors)
            $updates.Id | Should -Be @('iupdate-1')
            $updateErrors.Count | Should -Be 1
            $updateErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.InitiativeUpdateNotFound*'
        }

        It 'stops with the valid names for an unknown initiative' {
            { Get-LinearInitiativeUpdate -Initiative Moonshot } | Should -Throw -ErrorId 'PSLinear.InitiativeNotFound*'
        }
    }

    Context 'New-LinearInitiativeUpdate' {
        It 'posts an update with a body and health' {
            $update = New-LinearInitiativeUpdate -Initiative 'Q1 growth' 'Hiring done' -Health OffTrack
            $update.PSObject.TypeNames | Should -Contain 'PSLinear.InitiativeUpdate'
            $update.Health | Should -Be 'OffTrack'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateInitiativeUpdate' -and
                (Get-RequestVariable $Body 'input.initiativeId') -eq 'initiative-growth' -and
                (Get-RequestVariable $Body 'input.body') -eq 'Hiring done' -and
                (Get-RequestVariable $Body 'input.health') -eq 'offTrack'
            }
        }

        It 'posts a health-only update with an empty body' {
            $null = Get-LinearInitiative -Name 'Q1 growth' | New-LinearInitiativeUpdate -Health AtRisk
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateInitiativeUpdate' -and (Get-RequestBody $Body).variables.input['body'] -eq ''
            }
        }

        It 'needs a body or a health, and sends nothing with -WhatIf' {
            { New-LinearInitiativeUpdate -Initiative 'Q1 growth' } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            New-LinearInitiativeUpdate -Initiative 'Q1 growth' 'x' -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'writes one error when Linear rejects the update' {
            New-LinearInitiativeUpdate -Initiative 'Q1 growth' 'reject' -ErrorAction SilentlyContinue -ErrorVariable updateErrors | Should -BeNullOrEmpty
            $updateErrors.Count | Should -Be 1
            $updateErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.InitiativeUpdateCreateFailed*'
        }
    }

    Context 'Set-LinearInitiativeUpdate' {
        It 'edits the health and returns nothing, or the update with -PassThru' {
            Set-LinearInitiativeUpdate -Id iupdate-1 -Health AtRisk | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateInitiativeUpdate' -and (Get-RequestVariable $Body 'id') -eq 'iupdate-1' -and
                (Get-RequestVariable $Body 'input.health') -eq 'atRisk' -and -not (Get-RequestBody $Body).variables.input.Contains('body')
            }
            $update = Set-LinearInitiativeUpdate iupdate-2 -Body 'Recovered' -Health OnTrack -PassThru
            $update.Body | Should -Be 'Recovered'
            $update.Health | Should -Be 'OnTrack'
        }

        It 'edits piped updates and writes one error for a missing one' {
            Get-LinearInitiativeUpdate -Initiative 'Q1 growth' | Set-LinearInitiativeUpdate -Body 'Edited'
            'missing' | Set-LinearInitiativeUpdate -Body 'x' -ErrorAction SilentlyContinue -ErrorVariable updateErrors
            $updateErrors.Count | Should -Be 1
            $updateErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.InitiativeUpdateUpdateFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 3 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateInitiativeUpdate' }
        }

        It 'needs a change and sends nothing with -WhatIf' {
            { Set-LinearInitiativeUpdate -Id iupdate-1 } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            Set-LinearInitiativeUpdate -Id iupdate-1 -Health AtRisk -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Remove-LinearInitiativeUpdate' {
        It 'archives updates, by id and piped, and writes one error for a missing one' {
            Remove-LinearInitiativeUpdate -Id iupdate-1 -Confirm:$false | Should -BeNullOrEmpty
            Get-LinearInitiativeUpdate -Initiative 'Platform reliability' | Remove-LinearInitiativeUpdate -Confirm:$false
            Remove-LinearInitiativeUpdate -Id missing -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable updateErrors
            $updateErrors.Count | Should -Be 1
            $updateErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.InitiativeUpdateDeleteFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 3 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ArchiveInitiativeUpdate' }
        }

        It 'sends nothing with -WhatIf' {
            Remove-LinearInitiativeUpdate -Id iupdate-1 -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }
}
