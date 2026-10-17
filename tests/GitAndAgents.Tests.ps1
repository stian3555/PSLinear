BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force

    function Get-TestIssueResponse {
        # GetIssue and UpdateIssue for a few ENG issues. ENG-1 is unstarted and unassigned, ENG-2
        # is in progress and assigned to Ada (the viewer), ENG-404 does not exist. UpdateIssue
        # applies stateId and assigneeId; ENG-9 cannot be updated.
        param([hashtable] $Request)
        $states = @{
            'state-eng-todo'     = @('Todo', 'unstarted')
            'state-eng-progress' = @('In Progress', 'started')
            'state-eng-done'     = @('Done', 'completed')
        }
        $issueNode = {
            param($Identifier, $StateId, $AssigneeId)
            $node = New-LinearTestIssueNode -Identifier $Identifier -State $states[$StateId][0] -StateType $states[$StateId][1] -Assignee $(if ($AssigneeId) { 'Ada Lovelace' } else { '' })
            $node['id'] = "issue-uuid-$Identifier"
            $node['state']['id'] = $StateId
            if ($AssigneeId) { $node['assignee']['id'] = $AssigneeId }
            $node
        }
        $initial = @{
            'ENG-1' = @('state-eng-todo', $null)
            'ENG-2' = @('state-eng-progress', 'user-ada')
            'ENG-3' = @('state-eng-todo', $null)
            'ENG-9' = @('state-eng-todo', $null)
        }
        $variables = $Request['variables']
        $identifier = [string]$variables['id'] -replace '^issue-uuid-'
        if ($Request.query -match 'query GetIssue\b') {
            if (-not $initial.ContainsKey($identifier)) {
                return New-LinearTestResponse -Data $null -Errors @(New-LinearTestError -Message 'Entity not found: Issue' -Code 'INPUT_ERROR' -Path 'issue')
            }
            return New-LinearTestResponse -Data @{ issue = (& $issueNode $identifier $initial[$identifier][0] $initial[$identifier][1]) }
        }
        if ($Request.query -match 'mutation UpdateIssue\b') {
            if ($identifier -eq 'ENG-9') { return New-LinearTestResponse -Data @{ issueUpdate = $null } -Errors @(New-LinearTestError -Message 'Argument Validation Error' -Code 'INPUT_ERROR') }
            $issueInput = $variables['input']
            $stateId = if ($issueInput.Contains('stateId')) { $issueInput['stateId'] } else { $initial[$identifier][0] }
            $assigneeId = if ($issueInput.Contains('assigneeId')) { $issueInput['assigneeId'] } else { $initial[$identifier][1] }
            return New-LinearTestResponse -Data @{ issueUpdate = @{ success = $true; issue = (& $issueNode $identifier $stateId $assigneeId) } }
        }
        $null
    }

    function Get-TestAgentSessionResponse {
        # Three sessions, newest first: session-3 (Active, ENG-1), session-2 (awaiting input,
        # ENG-2), session-1 (complete, ENG-1). The id 'missing' does not exist.
        param([hashtable] $Request)
        $session = {
            param($Id, $Status, $Issue, $Summary)
            @{
                id = $Id; status = $Status; summary = $Summary; url = "https://linear.app/acme/issue/$Issue#agent-$Id"
                createdAt = '2026-10-17T09:00:00.000Z'; updatedAt = '2026-10-17T09:30:00.000Z'; startedAt = '2026-10-17T09:01:00.000Z'
                endedAt = $(if ($Status -eq 'complete') { '2026-10-17T09:30:00.000Z' } else { $null }); dismissedAt = $null
                appUser = @{ id = 'user-agent'; name = 'Claude' }; creator = @{ id = 'user-ada'; name = 'Ada Lovelace' }
                issue = @{ id = "issue-uuid-$Issue"; identifier = $Issue }
                externalLinks = @(@{ label = 'Pull request'; url = 'https://github.com/acme/app/pull/1' })
            }
        }
        $sessions = @(
            (& $session 'session-3' 'active' 'ENG-1' 'Fixing the login bug'),
            (& $session 'session-2' 'awaitingInput' 'ENG-2' 'Needs a decision'),
            (& $session 'session-1' 'complete' 'ENG-1' 'Wrote a reproduction')
        )
        if ($Request.query -match 'query ListAgentSessions') {
            return New-LinearTestResponse -Data @{ agentSessions = New-LinearTestConnection -Nodes $sessions }
        }
        if ($Request.query -match 'query GetAgentSession') {
            $match = @($sessions | Where-Object { $_.id -eq $Request['variables']['id'] })
            if ($match.Count -eq 0) { return New-LinearTestResponse -Data $null -Errors @(New-LinearTestError -Message 'Entity not found: AgentSession' -Code 'INPUT_ERROR') }
            return New-LinearTestResponse -Data @{ agentSession = $match[0] }
        }
        $null
    }
}

Describe 'Git and agent commands' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $request = Get-RequestBody -Body $Body
            $lookup = Get-LinearTestLookupResponse -Request $request
            if ($lookup) { return $lookup }
            $response = Get-TestIssueResponse -Request $request
            if ($null -ne $response) { return $response }
            Get-TestAgentSessionResponse -Request $request
        }

        # A fake git repository: $script:gitRepository, the current branch and the local branches.
        $script:gitRepository = $true
        $script:gitBranch = 'main'
        $script:gitBranches = [System.Collections.Generic.List[string]]@('main')
        $script:gitFails = $false
        Mock -ModuleName PSLinear Invoke-LinearGit {
            $joined = $Argument -join ' '
            $ok = { param([string[]] $Output) [pscustomobject]@{ ExitCode = 0; Output = $Output } }
            $fail = { param([string] $Message) [pscustomobject]@{ ExitCode = 128; Output = @($Message) } }
            if (-not $script:gitRepository) { return (& $fail 'fatal: not a git repository (or any of the parent directories): .git') }
            switch -Regex ($joined) {
                '^rev-parse --is-inside-work-tree$' { return (& $ok @('true')) }
                '^rev-parse --abbrev-ref HEAD$' { return (& $ok @($script:gitBranch)) }
                '^rev-parse --verify --quiet refs/heads/(.+)$' {
                    if ($script:gitBranches -contains $Matches[1]) { return (& $ok @('0123abc')) } else { return [pscustomobject]@{ ExitCode = 1; Output = @() } }
                }
                '^switch --create (\S+)' {
                    if ($script:gitFails) { return (& $fail "fatal: a branch named '$($Matches[1])' cannot be created") }
                    $script:gitBranches.Add($Matches[1]); $script:gitBranch = $Matches[1]
                    return (& $ok @("Switched to a new branch '$($Matches[1])'"))
                }
                '^switch (\S+)$' { $script:gitBranch = $Matches[1]; return (& $ok @("Switched to branch '$($Matches[1])'")) }
            }
            & $fail "unexpected git call: $joined"
        }
    }

    Context 'Find-LinearIssueIdentifier' {
        It 'finds identifiers with a team key, in any case and position' {
            InModuleScope PSLinear {
                Find-LinearIssueIdentifier -Branch 'ada/eng-123-fix-login' | Should -Be 'ENG-123'
                Find-LinearIssueIdentifier -Branch 'OPS-7' | Should -Be 'OPS-7'
                Find-LinearIssueIdentifier -Branch 'feature/ops-42_cleanup' | Should -Be 'OPS-42'
                Find-LinearIssueIdentifier -Branch 'release-2-eng-9-hotfix' | Should -Be 'ENG-9'
                Find-LinearIssueIdentifier -Branch 'main' | Should -BeNullOrEmpty
                Find-LinearIssueIdentifier -Branch 'weng-12' | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Get-LinearIssue -Current' {
        It 'gets the issue named in the current branch' {
            $script:gitBranch = 'ada/eng-1-fix-login'
            (Get-LinearIssue -Current).Identifier | Should -Be 'ENG-1'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'GetIssue' -and (Get-RequestVariable $Body 'id') -eq 'ENG-1'
            }
        }

        It 'stops with the team keys when the branch names no issue' {
            { Get-LinearIssue -Current } |
                Should -Throw -ErrorId 'PSLinear.NoIssueInBranch*' -ExpectedMessage "The branch 'main' does not contain an issue identifier with a team key (ENG, OPS)."
        }

        It 'stops outside a git repository and on a detached HEAD' {
            $script:gitRepository = $false
            { Get-LinearIssue -Current } | Should -Throw -ErrorId 'PSLinear.NotInGitRepository*'
            $script:gitRepository = $true
            $script:gitBranch = 'HEAD'
            { Get-LinearIssue -Current } | Should -Throw -ErrorId 'PSLinear.DetachedHead*'
        }

        It 'writes one error when the issue in the branch does not exist' {
            $script:gitBranch = 'eng-404-gone'
            Get-LinearIssue -Current -ErrorAction SilentlyContinue -ErrorVariable issueErrors | Should -BeNullOrEmpty
            $issueErrors.Count | Should -Be 1
            $issueErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueNotFound*'
        }
    }

    Context 'Start-LinearIssue' {
        It 'assigns an unstarted issue to you, moves it to the first started state and creates its branch' {
            Start-LinearIssue ENG-1 | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateIssue' -and
                (Get-RequestVariable $Body 'id') -eq 'issue-uuid-ENG-1' -and
                (Get-RequestVariable $Body 'input.assigneeId') -eq 'user-ada' -and
                (Get-RequestVariable $Body 'input.stateId') -eq 'state-eng-progress'
            }
            $script:gitBranch | Should -Be 'ada/eng-1'
            Should -Invoke Invoke-LinearGit -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { ($Argument -join ' ') -eq 'switch --create ada/eng-1' }
        }

        It 'returns the started issue with -PassThru' {
            $issue = Start-LinearIssue ENG-1 -PassThru
            $issue.PSObject.TypeNames | Should -Contain 'PSLinear.Issue'
            $issue.StateType | Should -Be 'started'
            $issue.BranchName | Should -Be 'ada/eng-1'
        }

        It 'creates the branch from -From, or uses -BranchName' {
            Start-LinearIssue ENG-1 -From origin/main
            Should -Invoke Invoke-LinearGit -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { ($Argument -join ' ') -eq 'switch --create ada/eng-1 origin/main' }
            Start-LinearIssue ENG-3 -BranchName 'fix/eng-3'
            $script:gitBranch | Should -Be 'fix/eng-3'
        }

        It 'switches to an existing branch, warning that -From is ignored' {
            $script:gitBranches.Add('ada/eng-1')
            Start-LinearIssue ENG-1 -From main -WarningVariable startWarnings -WarningAction SilentlyContinue
            $script:gitBranch | Should -Be 'ada/eng-1'
            $startWarnings.Count | Should -Be 1
            Should -Invoke Invoke-LinearGit -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { $Argument -contains '--create' }
        }

        It 'leaves a started issue''s state alone, and sends no update when nothing changes' {
            Start-LinearIssue ENG-2
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateIssue' }
            $script:gitBranch | Should -Be 'ada/eng-2'
        }

        It 'moves to -State even when the issue is started, and skips the assignee with -NoAssign' {
            Start-LinearIssue ENG-2 -State Done -NoBranch
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateIssue' -and (Get-RequestVariable $Body 'input.stateId') -eq 'state-eng-done'
            }
            Start-LinearIssue ENG-1 -NoAssign -NoBranch
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateIssue' -and (Get-RequestVariable $Body 'id') -eq 'issue-uuid-ENG-1' -and
                -not (Get-RequestBody $Body).variables.input.Contains('assigneeId')
            }
        }

        It 'starts several piped issues with -NoBranch, without calling git' {
            $issues = @('ENG-1', 'ENG-3' | Start-LinearIssue -NoBranch -PassThru)
            $issues.Identifier | Should -Be @('ENG-1', 'ENG-3')
            Should -Invoke Invoke-LinearGit -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'stops at the second issue when it would check out a branch for each' {
            { 'ENG-1', 'ENG-3' | Start-LinearIssue } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage '*ENG-3 was not started. Use -NoBranch*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateIssue' }
        }

        It 'stops before sending anything outside a git repository' {
            $script:gitRepository = $false
            { Start-LinearIssue ENG-1 } | Should -Throw -ErrorId 'PSLinear.NotInGitRepository*' -ExpectedMessage '*use -NoBranch*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'rejects -BranchName or -From with -NoBranch' {
            { Start-LinearIssue ENG-1 -NoBranch -BranchName x } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            { Start-LinearIssue ENG-1 -NoBranch -From main } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
        }

        It 'sends nothing and creates no branch with -WhatIf' {
            Start-LinearIssue ENG-1 -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
            Should -Invoke Invoke-LinearGit -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { $Argument[0] -eq 'switch' }
        }

        It 'writes one error when git fails, after starting the issue' {
            $script:gitFails = $true
            $issue = Start-LinearIssue ENG-1 -PassThru -ErrorAction SilentlyContinue -ErrorVariable startErrors
            $issue.StateType | Should -Be 'started'
            $startErrors.Count | Should -Be 1
            $startErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.GitFailed*'
            $startErrors[0].Exception.Message | Should -BeLike "Issue ENG-1 was started, but git could not check out branch 'ada/eng-1': fatal:*"
        }

        It 'writes one error for a missing issue or a rejected update' {
            Start-LinearIssue ENG-404 -NoBranch -ErrorAction SilentlyContinue -ErrorVariable startErrors
            $startErrors.Count | Should -Be 1
            $startErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueNotFound*'
            Start-LinearIssue ENG-9 -NoBranch -ErrorAction SilentlyContinue -ErrorVariable updateErrors
            $updateErrors.Count | Should -Be 1
            $updateErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueUpdateFailed*'
        }

        It 'takes issue objects from the pipeline' {
            $issue = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-uuid-ENG-1'; Identifier = 'ENG-1'; TeamId = 'team-eng' }
            ($issue | Start-LinearIssue -NoBranch -PassThru).Identifier | Should -Be 'ENG-1'
        }
    }

    Context 'Get-LinearAgentSession' {
        It 'lists sessions newest first as typed objects' {
            $sessions = @(Get-LinearAgentSession)
            $sessions.Id | Should -Be @('session-3', 'session-2', 'session-1')
            $sessions[0].PSObject.TypeNames | Should -Contain 'PSLinear.AgentSession'
            $sessions[0].Agent | Should -Be 'Claude'
            $sessions[0].Status | Should -Be 'Active'
            $sessions[1].Status | Should -Be 'AwaitingInput'
            $sessions[0].Issue | Should -Be 'ENG-1'
            $sessions[0].ExternalLinks[0].Url | Should -Be 'https://github.com/acme/app/pull/1'
            $sessions[2].EndedAt | Should -Not -BeNullOrEmpty
        }

        It 'filters by issue and status, applying -First afterwards' {
            @(Get-LinearAgentSession -Issue ENG-1).Id | Should -Be @('session-3', 'session-1')
            @(Get-LinearAgentSession -Issue 'https://linear.app/acme/issue/ENG-2/title').Id | Should -Be @('session-2')
            @(Get-LinearAgentSession -Status Active, AwaitingInput).Id | Should -Be @('session-3', 'session-2')
            @(Get-LinearAgentSession -Issue ENG-1 -First 1).Id | Should -Be @('session-3')
        }

        It 'asks only for the newest sessions with -First and no filter' {
            $null = Get-LinearAgentSession -First 2
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListAgentSessions' -and (Get-RequestVariable $Body 'first') -eq 2
            }
        }

        It 'gets sessions by id, writing one error for a missing one' {
            $sessions = @(Get-LinearAgentSession -Id 'session-2', 'missing' -ErrorAction SilentlyContinue -ErrorVariable sessionErrors)
            $sessions.Id | Should -Be @('session-2')
            $sessionErrors.Count | Should -Be 1
            $sessionErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.AgentSessionNotFound*'
        }

        It 'rejects an unknown status' {
            { Get-LinearAgentSession -Status Running } | Should -Throw
        }
    }
}
