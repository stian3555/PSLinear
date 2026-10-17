BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Remove-LinearIssueRelation' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestRelationResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    Context 'By id or object' {
        It 'removes a relation and returns nothing' {
            Remove-LinearIssueRelation -Id relation-1 -Confirm:$false | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'DeleteIssueRelation' -and (Get-RequestVariable $Body 'id') -eq 'relation-1'
            }
        }

        It 'removes piped relations' {
            Get-LinearIssueRelation ENG-1 -Type Blocks, Related | Remove-LinearIssueRelation -Confirm:$false
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'DeleteIssueRelation' }
        }

        It 'writes one error for a missing relation and removes the rest' {
            'missing', 'relation-1' | Remove-LinearIssueRelation -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable relationErrors
            $relationErrors.Count | Should -Be 1
            $relationErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.RelationDeleteFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly
        }
    }

    Context 'Between two issues' {
        It 'removes every relation between them, in either direction' {
            Remove-LinearIssueRelation -Issue ENG-1 -RelatedIssue ENG-4 -Confirm:$false
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'DeleteIssueRelation' -and (Get-RequestVariable $Body 'id') -eq 'relation-3'
            }
        }

        It 'only removes relations of -Type, seen from -Issue' {
            Remove-LinearIssueRelation -Issue ENG-1 -RelatedIssue ENG-2 -Type Blocks -Confirm:$false
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestVariable $Body 'id') -eq 'relation-1'
            }
        }

        It 'writes RelationNotFound when there is no matching relation' {
            Remove-LinearIssueRelation -Issue ENG-1 -RelatedIssue ENG-2 -Type BlockedBy -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable relationErrors
            $relationErrors.Count | Should -Be 1
            $relationErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.RelationNotFound*'
            $relationErrors[0].Exception.Message | Should -Be 'ENG-1 has no BlockedBy relations with ENG-2.'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'DeleteIssueRelation' }
        }

        It 'writes IssueNotFound for a missing issue' {
            Remove-LinearIssueRelation -Issue ENG-404 -RelatedIssue ENG-2 -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable relationErrors
            $relationErrors.Count | Should -Be 1
            $relationErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueNotFound*'
        }
    }

    Context '-WhatIf' {
        It 'sends no request, not even the lookup of relations between two issues' {
            Remove-LinearIssueRelation -Id relation-1 -WhatIf
            Remove-LinearIssueRelation -Issue ENG-1 -RelatedIssue ENG-2 -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }
}
