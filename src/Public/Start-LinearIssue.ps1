function Start-LinearIssue {
    <#
    .SYNOPSIS
        Starts work on a Linear issue: assigns it to you, moves it to a started state and checks
        out its git branch.

    .DESCRIPTION
        Assigns the issue to you and, if it is still in triage, the backlog or an unstarted
        state, moves it to the team's first started state (such as In Progress). An issue that
        is already started, done or canceled keeps its state unless you give -State. Then it
        checks out the issue's git branch in the current repository, using the branch name
        Linear suggests (Issue.BranchName), and creates the branch when it does not exist yet.

        Use -NoBranch to skip git, for example outside a repository or to start several issues
        at once. Nothing is returned unless you use -PassThru. With -WhatIf nothing is sent and
        no branch is created.

        A missing issue, or a change Linear rejects, writes a non-terminating error. If git
        cannot check out the branch, the issue stays started and the command writes an error
        with git's message.

    .PARAMETER Id
        The issue identifier (ENG-123), UUID or URL.

    .PARAMETER InputObject
        A PSLinear.Issue object, typically from Get-LinearIssue.

    .PARAMETER State
        The state to move the issue to instead: a state name, a state type, or an id. Given
        this way, the state is set even when the issue is already started.

    .PARAMETER NoAssign
        Leaves the assignee as it is.

    .PARAMETER NoBranch
        Does not check out a git branch.

    .PARAMETER BranchName
        The branch to check out or create instead of the one Linear suggests.

    .PARAMETER From
        The commit, branch or tag to create a new branch from. By default the new branch starts
        at the current commit. Ignored, with a warning, when the branch already exists.

    .PARAMETER PassThru
        Returns the started issue.

    .EXAMPLE
        Start-LinearIssue ENG-123

        Assigns ENG-123 to you, moves it to In Progress and checks out its branch, such as
        ada/eng-123-fix-login.

    .EXAMPLE
        Start-LinearIssue ENG-123 -From origin/main

        Starts the issue on a new branch based on origin/main.

    .EXAMPLE
        Get-LinearIssue -Assignee me -Cycle active -StateType Unstarted | Start-LinearIssue -NoBranch

        Starts every unstarted issue of yours in the current cycle, without touching git.

    .INPUTS
        System.String
        PSLinear.Issue

    .OUTPUTS
        PSLinear.Issue

    .LINK
        Get-LinearIssue

    .LINK
        Set-LinearIssue
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('PSLinear.Issue')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [Alias('Identifier')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Issue')]
        [object[]] $InputObject,

        [ValidateNotNullOrEmpty()]
        [string] $State,

        [switch] $NoAssign,

        [switch] $NoBranch,

        [ValidateNotNullOrEmpty()]
        [string] $BranchName,

        [ValidateNotNullOrEmpty()]
        [string] $From,

        [switch] $PassThru
    )

    begin {
        if ($NoBranch -and ($BranchName -or $From)) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message '-BranchName and -From apply to the git branch; do not combine them with -NoBranch.' `
                        -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }
        if (-not $NoBranch) {
            try {
                $inRepository = Test-LinearGitRepository
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }
            if (-not $inRepository) {
                $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message "$((Get-Location).Path) is not in a git repository. Run the command in your repository, or use -NoBranch." `
                            -ErrorId 'PSLinear.NotInGitRepository' -Category ObjectNotFound -TargetObject (Get-Location).Path))
            }
        }

        $steps = @(
            if (-not $NoAssign) { 'assign to you' }
            if ($State) { "move to '$State'" } else { 'move to a started state' }
            if (-not $NoBranch) { "check out $(if ($BranchName) { "branch '$BranchName'" } else { 'its git branch' })" }
        )
        $action = "Start issue ($($steps -join ', '))"
        $issueQuery = Get-LinearGraphQLDocument -Name 'GetIssue'
        $updateQuery = Get-LinearGraphQLDocument -Name 'UpdateIssue'
        $started = 0
    }

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ById') { Get-LinearIssueTarget -Id $Id } else { Get-LinearIssueTarget -InputObject $InputObject }

        foreach ($target in $targets) {
            if (-not $NoBranch -and $started -ge 1) {
                $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message "Only one git branch can be checked out, so $($target.Name) was not started. Use -NoBranch to start several issues." `
                            -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument -TargetObject $target.Name))
            }
            if (-not $PSCmdlet.ShouldProcess($target.Name, $action)) {
                continue
            }

            # Fetch the issue for its team, state, assignee and suggested branch name.
            $result = Invoke-LinearRequest -Query $issueQuery -Variables @{ id = $target.Id } -IncludeErrors
            $node = Get-LinearNestedValue -InputObject $result.Data -Name 'issue'
            if ($null -eq $node) {
                $message = Format-LinearFailureMessage -Message "Issue '$($target.Name)' was not found." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.IssueNotFound' -Category ObjectNotFound -TargetObject $target.Name))
                continue
            }
            $issue = ConvertTo-LinearIssue -InputObject $node

            try {
                $issueInput = @{}
                if (-not $NoAssign) {
                    $viewerId = Resolve-LinearUserId -User 'me'
                    if ($issue.AssigneeId -ne $viewerId) { $issueInput['assigneeId'] = $viewerId }
                }
                if ($State) {
                    $issueInput['stateId'] = Resolve-LinearWorkflowStateId -TeamId $issue.TeamId -State $State
                }
                elseif ($issue.StateType -in 'triage', 'backlog', 'unstarted') {
                    $issueInput['stateId'] = Resolve-LinearWorkflowStateId -TeamId $issue.TeamId -State 'started'
                }
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }

            if ($issueInput.Count -gt 0) {
                $result = Invoke-LinearRequest -Query $updateQuery -Variables @{ id = $issue.Id; input = $issueInput } -IncludeErrors
                $updated = Get-LinearNestedValue -InputObject $result.Data -Name 'issueUpdate.issue'
                if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'issueUpdate.success') -or $null -eq $updated) {
                    $message = Format-LinearFailureMessage -Message "Linear did not start issue '$($issue.Identifier)'." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.IssueUpdateFailed' -Category WriteError -TargetObject $issue.Identifier))
                    continue
                }
                $issue = ConvertTo-LinearIssue -InputObject $updated
            }
            $started++

            if (-not $NoBranch) {
                $branch = if ($BranchName) { $BranchName } else { $issue.BranchName }
                $exists = (Invoke-LinearGit -Argument 'rev-parse', '--verify', '--quiet', "refs/heads/$branch").ExitCode -eq 0
                $gitArguments = if ($exists) {
                    if ($From) { Write-Warning "Branch '$branch' already exists, so -From $From is ignored." }
                    @('switch', $branch)
                }
                else {
                    @('switch', '--create', $branch) + @(if ($From) { $From })
                }
                $git = Invoke-LinearGit -Argument $gitArguments
                if ($git.ExitCode -ne 0) {
                    $message = "Issue $($issue.Identifier) was started, but git could not check out branch '$branch': $($git.Output -join ' ')"
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.GitFailed' -Category InvalidResult -TargetObject $branch))
                }
                else {
                    Write-Verbose ($git.Output -join [Environment]::NewLine)
                }
            }

            if ($PassThru) {
                $issue
            }
        }
    }
}
