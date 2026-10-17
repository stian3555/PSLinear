BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Get-LinearIssueRelation' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestRelationResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    It 'returns relations in both directions, seen from the issue, oldest first' {
        $relations = @(Get-LinearIssueRelation ENG-1)
        ($relations | ForEach-Object { '{0} {1} {2}' -f $_.Issue, $_.Type, $_.RelatedIssue }) |
            Should -Be @('ENG-1 Blocks ENG-2', 'ENG-1 Related ENG-3', 'ENG-1 DuplicatedBy ENG-4')
        $relations[0].PSObject.TypeNames | Should -Contain 'PSLinear.IssueRelation'
        $relations[0].RelatedTitle | Should -Be 'Issue ENG-2'
        $relations[0].RelatedState | Should -Be 'In Progress'
        $relations[2].ApiType | Should -Be 'duplicate'
        $relations[2].IssueId | Should -Be 'issue-uuid-ENG-1'
        $relations[2].RelatedIssueId | Should -Be 'issue-uuid-ENG-4'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ListIssueRelations' }
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ListIssueInverseRelations' }
    }

    It 'filters by type' {
        (Get-LinearIssueRelation ENG-1 -Type Blocks, DuplicatedBy).RelatedIssue | Should -Be @('ENG-2', 'ENG-4')
    }

    It 'accepts URLs, identifiers from the pipeline and issue objects' {
        @(Get-LinearIssueRelation 'https://linear.app/acme/issue/ENG-1/title').Count | Should -Be 3
        @('ENG-1', 'ENG-5' | Get-LinearIssueRelation).Count | Should -Be 3
        $issue = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-uuid-ENG-1'; Identifier = 'ENG-1' }
        @($issue | Get-LinearIssueRelation).Count | Should -Be 3
    }

    It 'writes one error for a missing issue and lists the rest' {
        $relations = @('ENG-404', 'ENG-1' | Get-LinearIssueRelation -ErrorAction SilentlyContinue -ErrorVariable relationErrors)
        $relations.Count | Should -Be 3
        $relationErrors.Count | Should -Be 1
        $relationErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueNotFound*'
    }
}
