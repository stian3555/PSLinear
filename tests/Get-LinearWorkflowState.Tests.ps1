BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Get-LinearWorkflowState' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestLookupResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    It 'lists a team''s states in workflow order' {
        $states = @(Get-LinearWorkflowState -Team ENG)
        $states.Name | Should -Be @('Backlog', 'Todo', 'In Progress', 'In Review', 'Done', 'Canceled', 'Duplicate')
        $states[0].PSObject.TypeNames | Should -Contain 'PSLinear.WorkflowState'
        $states[0].Team | Should -Be 'ENG'
        $states[0].Type | Should -Be 'backlog'
    }

    It 'lists the states of every team without -Team' {
        $states = @(Get-LinearWorkflowState)
        ($states | Where-Object Team -EQ 'OPS').Name | Should -Be @('Todo', 'Doing', 'Done')
        $states.Count | Should -Be 10
    }

    It 'filters by type and by name with wildcards' {
        @(Get-LinearWorkflowState -Team ENG -Type Started).Name | Should -Be @('In Progress', 'In Review')
        @(Get-LinearWorkflowState -Name 'In *').Name | Should -Be @('In Progress', 'In Review')
    }

    It 'takes teams from the pipeline' {
        $teams = @(
            [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-eng'; Key = 'ENG'; Name = 'Engineering' }
            [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-ops'; Key = 'OPS'; Name = 'Operations' }
        )
        @($teams | Get-LinearWorkflowState -Name 'Done').Id | Should -Be @('state-eng-done', 'state-ops-done')
    }

    It 'reports a name only when no piped team has it' {
        $teams = @(
            [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-eng'; Key = 'ENG'; Name = 'Engineering' }
            [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-ops'; Key = 'OPS'; Name = 'Operations' }
        )
        $states = @($teams | Get-LinearWorkflowState -Name 'Doing', 'Nope' -ErrorAction SilentlyContinue -ErrorVariable stateErrors)
        $states.Id | Should -Be @('state-ops-doing')
        $stateErrors.Count | Should -Be 1
        $stateErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.StateNotFound*'
        $stateErrors[0].TargetObject | Should -Be 'Nope'
    }

    It 'stops on an unknown team' {
        { Get-LinearWorkflowState -Team NOPE } | Should -Throw -ErrorId 'PSLinear.TeamNotFound*'
    }

    It 'refreshes the state cache used for -State' {
        Get-LinearWorkflowState -Team ENG | Out-Null
        InModuleScope PSLinear { Resolve-LinearWorkflowStateId -TeamId 'team-eng' -State 'Done' } | Should -Be 'state-eng-done'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            (Get-RequestOperation $Body) -eq 'ListWorkflowStates'
        }
    }
}
