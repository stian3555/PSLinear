BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Remove-LinearIssue' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }

        # ENG-404 does not exist, and Linear reports no success for ENG-500.
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $request = Get-RequestBody -Body $Body
            $field = if ($request.query -match 'mutation DeleteIssue') { 'issueDelete' } else { 'issueArchive' }
            switch ($request.variables.id) {
                'ENG-404' {
                    New-LinearTestResponse -Data @{ $field = $null } -Errors @(New-LinearTestError -Message 'Entity not found: Issue' -Code 'INVALID_INPUT')
                }
                'ENG-500' {
                    New-LinearTestResponse -Data @{ $field = @{ success = $false } }
                }
                default {
                    New-LinearTestResponse -Data @{ $field = @{ success = $true } }
                }
            }
        }
    }

    Context 'Request' {
        It 'archives the issue by default and returns nothing' {
            Remove-LinearIssue ENG-1 -Confirm:$false | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                (Get-RequestOperation $Body) -eq 'ArchiveIssue' -and $request.variables.id -eq 'ENG-1'
            }
        }

        It 'moves the issue to the trash with -Delete, without deleting it permanently' {
            Remove-LinearIssue ENG-1 -Delete -Confirm:$false
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                (Get-RequestOperation $Body) -eq 'DeleteIssue' -and
                $request.variables.id -eq 'ENG-1' -and
                -not $request.variables.ContainsKey('permanentlyDelete') -and
                $request.query -notmatch 'permanentlyDelete'
            }
        }
    }

    Context '-WhatIf' {
        It 'sends no request when archiving' {
            'ENG-1', 'ENG-2' | Remove-LinearIssue -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'sends no request when deleting' {
            $existing = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-1'; Identifier = 'ENG-1' }
            $existing | Remove-LinearIssue -Delete -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Pipeline input' {
        It 'removes every identifier piped in' {
            'ENG-1', 'ENG-2' | Remove-LinearIssue -Confirm:$false
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestBody $Body).variables.id -eq 'ENG-2'
            }
        }

        It 'uses the Id of piped issue objects' {
            $issueId = [guid]::NewGuid().Guid
            [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = $issueId; Identifier = 'ENG-9' } | Remove-LinearIssue -Confirm:$false
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestBody $Body).variables.id -eq $issueId
            }
        }

        It 'writes one error for a missing issue and processes the rest' {
            'ENG-1', 'ENG-404', 'ENG-2' | Remove-LinearIssue -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable removeErrors
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 3 -Exactly
            $removeErrors.Count | Should -Be 1
            $removeErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueArchiveFailed*'
            $removeErrors[0].Exception.Message | Should -BeLike "Linear did not archive issue 'ENG-404'. Linear API error: Entity not found*"
            $removeErrors[0].TargetObject | Should -Be 'ENG-404'
        }
    }

    Context 'Errors' {
        It 'writes one error when Linear does not report success for -Delete' {
            Remove-LinearIssue ENG-500 -Delete -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable removeErrors
            $removeErrors.Count | Should -Be 1
            $removeErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueDeleteFailed*'
            $removeErrors[0].Exception.Message | Should -Be "Linear did not delete issue 'ENG-500'."
        }

        It 'still stops on authentication failures' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                New-LinearTestResponse -StatusCode 400 -Errors @(New-LinearTestError -Message 'Authentication required' -Code 'AUTHENTICATION_ERROR')
            }
            { 'ENG-1', 'ENG-2' | Remove-LinearIssue -Confirm:$false } | Should -Throw -ErrorId 'PSLinear.AuthenticationFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
        }
    }
}
