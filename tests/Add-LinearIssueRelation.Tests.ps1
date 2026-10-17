BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Add-LinearIssueRelation' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestRelationResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    It 'creates <Type> as Linear type <ApiType> from <From> to <To>, returned from ENG-1''s side' -ForEach @(
        @{ Type = 'Blocks'; ApiType = 'blocks'; From = 'ENG-1'; To = 'ENG-2' }
        @{ Type = 'BlockedBy'; ApiType = 'blocks'; From = 'ENG-2'; To = 'ENG-1' }
        @{ Type = 'Related'; ApiType = 'related'; From = 'ENG-1'; To = 'ENG-2' }
        @{ Type = 'DuplicateOf'; ApiType = 'duplicate'; From = 'ENG-1'; To = 'ENG-2' }
        @{ Type = 'DuplicatedBy'; ApiType = 'duplicate'; From = 'ENG-2'; To = 'ENG-1' }
        @{ Type = 'Similar'; ApiType = 'similar'; From = 'ENG-1'; To = 'ENG-2' }
    ) {
        $relation = Add-LinearIssueRelation ENG-1 $Type ENG-2
        $relation.Issue | Should -Be 'ENG-1'
        $relation.Type | Should -Be $Type
        $relation.RelatedIssue | Should -Be 'ENG-2'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            (Get-RequestVariable $Body 'input.type') -eq $ApiType -and
            (Get-RequestVariable $Body 'input.issueId') -eq $From -and
            (Get-RequestVariable $Body 'input.relatedIssueId') -eq $To
        }
    }

    It 'relates the issue to several issues, accepting URLs' {
        $relations = @(Add-LinearIssueRelation -Issue 'https://linear.app/acme/issue/ENG-1/x' -Type Blocks -RelatedIssue ENG-2, 'https://linear.app/acme/issue/ENG-3/y')
        $relations.RelatedIssue | Should -Be @('ENG-2', 'ENG-3')
    }

    It 'binds the issue from piped PSLinear.Issue objects' {
        $issues = @(
            [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-uuid-ENG-5'; Identifier = 'ENG-5' }
            [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-uuid-ENG-6'; Identifier = 'ENG-6' }
        )
        ($issues | Add-LinearIssueRelation -Type Related -RelatedIssue ENG-1).Issue | Should -Be @('ENG-5', 'ENG-6')
    }

    It 'sends no request with -WhatIf' {
        Add-LinearIssueRelation ENG-1 Blocks ENG-2, ENG-3 -WhatIf
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
    }

    It 'writes one error for a relation Linear rejects and creates the rest' {
        $relations = @(Add-LinearIssueRelation ENG-1 Related ENG-404, ENG-2 -ErrorAction SilentlyContinue -ErrorVariable relationErrors)
        $relations.RelatedIssue | Should -Be @('ENG-2')
        $relationErrors.Count | Should -Be 1
        $relationErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.RelationCreateFailed*'
        $relationErrors[0].Exception.Message | Should -BeLike 'Linear did not relate ENG-1 (Related) to ENG-404. Linear API error: Entity not found*'
    }

    It 'rejects an unknown type' {
        { Add-LinearIssueRelation ENG-1 Causes ENG-2 } | Should -Throw
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
    }
}
