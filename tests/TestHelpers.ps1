# Shared helpers for the PSLinear test suite. Dot-source from BeforeAll.

function Get-PSLinearTestModulePath {
    # CI tests the built module (build.ps1 sets PSLINEAR_TEST_MODULE); locally we test the source.
    if ($env:PSLINEAR_TEST_MODULE) { return $env:PSLINEAR_TEST_MODULE }
    Join-Path $PSScriptRoot '..' 'src' 'PSLinear.psd1'
}

function ConvertTo-TestObject {
    # Round-trips through JSON so test data has the same shape as a real Invoke-RestMethod result.
    param([Parameter(Mandatory)][AllowNull()][object] $InputObject)
    if ($null -eq $InputObject) { return $null }
    $InputObject | ConvertTo-Json -Depth 32 | ConvertFrom-Json
}

function New-LinearTestResponse {
    param(
        [object] $Data,
        [object[]] $Errors,
        [int] $StatusCode = 200,
        [hashtable] $Headers = @{}
    )
    $body = [ordered]@{}
    if ($PSBoundParameters.ContainsKey('Data')) { $body['data'] = $Data }
    if ($Errors) { $body['errors'] = $Errors }
    [pscustomobject]@{
        StatusCode = $StatusCode
        Headers    = $Headers
        Content    = ConvertTo-TestObject -InputObject $body
    }
}

function New-LinearTestError {
    param(
        [string] $Message = 'Something went wrong',
        [string] $Code,
        [string[]] $Path
    )
    $graphQLError = [ordered]@{ message = $Message }
    if ($Code) { $graphQLError['extensions'] = @{ code = $Code } }
    if ($Path) { $graphQLError['path'] = $Path }
    $graphQLError
}

function New-LinearTestIssueNode {
    param(
        [string] $Identifier = 'ENG-1',
        [string] $Title = 'Test issue',
        [string] $State = 'Todo',
        [string] $StateType = 'unstarted',
        [string] $Assignee = 'Ada Lovelace',
        [string[]] $Labels = @('Bug'),
        [int] $Priority = 2,
        [string] $Milestone,
        [string] $Delegate
    )
    $number = [int]($Identifier -replace '^.*-', '')
    [ordered]@{
        id            = [guid]::NewGuid().Guid
        identifier    = $Identifier
        number        = $number
        title         = $Title
        description   = 'Some **markdown**'
        priority      = $Priority
        priorityLabel = @('No priority', 'Urgent', 'High', 'Medium', 'Low')[$Priority]
        estimate      = 3
        dueDate       = $null
        url           = "https://linear.app/acme/issue/$Identifier"
        branchName    = "ada/$($Identifier.ToLower())"
        createdAt     = '2026-10-01T08:00:00.000Z'
        updatedAt     = '2026-10-15T08:00:00.000Z'
        startedAt     = $null
        completedAt   = $null
        canceledAt    = $null
        archivedAt    = $null
        state         = @{ id = 'state-1'; name = $State; type = $StateType }
        assignee      = if ($Assignee) { @{ id = 'user-1'; name = $Assignee; displayName = 'ada'; email = 'ada@example.com' } } else { $null }
        creator       = @{ id = 'user-2'; name = 'Grace Hopper' }
        team          = @{ id = 'team-eng'; key = 'ENG'; name = 'Engineering' }
        project       = $null
        cycle         = $null
        parent        = $null
        delegate      = if ($Delegate) { @{ id = 'user-agent'; name = $Delegate } } else { $null }
        projectMilestone = if ($Milestone) { @{ id = 'milestone-x'; name = $Milestone } } else { $null }
        labels        = @{ nodes = @(foreach ($label in $Labels) { @{ id = "label-$label"; name = $label } }) }
    }
}

function New-LinearTestTeamNode {
    param(
        [string] $Key = 'ENG',
        [string] $Name = 'Engineering',
        [string] $Id = 'team-eng',
        [string] $EstimationType = 'fibonacci'
    )
    [ordered]@{
        id                     = $Id
        key                    = $Key
        name                   = $Name
        description            = $null
        visibility             = 'public'
        createdAt              = '2025-01-01T00:00:00.000Z'
        archivedAt             = $null
        issueEstimationType    = $EstimationType
        inheritIssueEstimation = $false
        parent                 = $null
    }
}

function New-LinearTestConnection {
    param(
        [object[]] $Nodes,
        [bool] $HasNextPage = $false,
        [string] $EndCursor = $null
    )
    @{
        nodes    = @($Nodes)
        pageInfo = @{ hasNextPage = $HasNextPage; endCursor = $EndCursor }
    }
}

function Get-RequestBody {
    # Parses the JSON body that was passed to Send-LinearHttpRequest.
    param([Parameter(Mandatory)][string] $Body)
    $Body | ConvertFrom-Json -AsHashtable
}

function Get-LinearTestLookupResponse {
    # Serves the lookup queries used for name resolution from a small fixed workspace, or returns
    # $null for any other request. Use it at the top of a Send-LinearHttpRequest mock:
    #   $lookup = Get-LinearTestLookupResponse -Request $request; if ($lookup) { return $lookup }
    #
    # Teams:    ENG (team-eng, uses estimates), OPS (team-ops, estimates turned off)
    # States:   ENG Backlog, Todo, In Progress, In Review, Done, Canceled, Duplicate; OPS Todo, Doing, Done
    # Labels:   workspace Bug, Feature, group Area with Frontend, retired Old;
    #           ENG Backend; OPS Incident and a second Frontend
    # Users:    Ada Lovelace (the viewer), Grace Hopper, two users named Alex Smith, and the
    #           disabled Old Timer (only with includeDisabled)
    # Projects: Website, Mobile App, and the archived Legacy (only with includeArchived)
    # Cycles:   ENG 10 (past), 11 (previous), 12 (active), 13 (next, named 'Release sprint'); OPS 3 (active)
    # Milestones: Website has Alpha and Beta; Mobile App has none
    # Templates: issue templates 'Bug report' (workspace and ENG's own) and 'Incident' (OPS),
    #           project template 'Kickoff', document template 'RFC'
    param([Parameter(Mandatory)][hashtable] $Request)

    $query = $Request.query
    $variables = if ($Request.ContainsKey('variables')) { $Request.variables } else { @{} }

    if ($query -match 'query ListTeams') {
        return New-LinearTestResponse -Data @{
            teams = New-LinearTestConnection -Nodes @(
                (New-LinearTestTeamNode -Key 'ENG' -Name 'Engineering' -Id 'team-eng'),
                (New-LinearTestTeamNode -Key 'OPS' -Name 'Operations' -Id 'team-ops' -EstimationType 'notUsed')
            )
        }
    }

    if ($query -match 'query ListWorkflowStates') {
        $teamId = $variables.filter.team.id.eq
        # Deliberately not in workflow order, so sorting is tested.
        $states = switch ($teamId) {
            'team-eng' {
                @(
                    @{ id = 'state-eng-duplicate'; name = 'Duplicate'; type = 'duplicate'; position = 0 }
                    @{ id = 'state-eng-review'; name = 'In Review'; type = 'started'; position = 2.5 }
                    @{ id = 'state-eng-done'; name = 'Done'; type = 'completed'; position = 3 }
                    @{ id = 'state-eng-backlog'; name = 'Backlog'; type = 'backlog'; position = 0 }
                    @{ id = 'state-eng-progress'; name = 'In Progress'; type = 'started'; position = 2 }
                    @{ id = 'state-eng-canceled'; name = 'Canceled'; type = 'canceled'; position = 4 }
                    @{ id = 'state-eng-todo'; name = 'Todo'; type = 'unstarted'; position = 1 }
                )
            }
            'team-ops' {
                @(
                    @{ id = 'state-ops-todo'; name = 'Todo'; type = 'unstarted'; position = 0 }
                    @{ id = 'state-ops-doing'; name = 'Doing'; type = 'started'; position = 1 }
                    @{ id = 'state-ops-done'; name = 'Done'; type = 'completed'; position = 2 }
                )
            }
            default { @() }
        }
        $teamKey = if ($teamId -eq 'team-ops') { 'OPS' } else { 'ENG' }
        $nodes = foreach ($state in $states) {
            $state['color'] = '#000000'
            $state['team'] = @{ id = $teamId; key = $teamKey }
            $state
        }
        return New-LinearTestResponse -Data @{ workflowStates = New-LinearTestConnection -Nodes @($nodes) }
    }

    if ($query -match 'query ListIssueLabels') {
        # Without a filter every label is returned; with one, workspace labels and the listed teams'.
        $teamIds = if ($variables.ContainsKey('filter')) { @($variables.filter.or[1].team.id.in) } else { $null }
        $engTeam = @{ id = 'team-eng'; key = 'ENG' }
        $opsTeam = @{ id = 'team-ops'; key = 'OPS' }
        $areaGroup = @{ id = 'label-area'; name = 'Area' }
        $all = @(
            @{ id = 'label-bug'; name = 'Bug'; isGroup = $false; retiredAt = $null; parent = $null; team = $null }
            @{ id = 'label-feature'; name = 'Feature'; isGroup = $false; retiredAt = $null; parent = $null; team = $null }
            @{ id = 'label-area'; name = 'Area'; isGroup = $true; retiredAt = $null; parent = $null; team = $null }
            @{ id = 'label-frontend'; name = 'Frontend'; isGroup = $false; retiredAt = $null; parent = $areaGroup; team = $null }
            @{ id = 'label-old'; name = 'Old'; isGroup = $false; retiredAt = '2026-01-01T00:00:00.000Z'; parent = $null; team = $null }
            @{ id = 'label-eng-backend'; name = 'Backend'; isGroup = $false; retiredAt = $null; parent = $null; team = $engTeam }
            @{ id = 'label-ops-incident'; name = 'Incident'; isGroup = $false; retiredAt = $null; parent = $null; team = $opsTeam }
            @{ id = 'label-ops-frontend'; name = 'Frontend'; isGroup = $false; retiredAt = $null; parent = $null; team = $opsTeam }
        )
        $nodes = foreach ($label in $all) {
            if ($null -ne $teamIds -and $null -ne $label.team -and $label.team.id -notin $teamIds) { continue }
            $label['color'] = '#000000'
            $label['description'] = $null
            $label
        }
        return New-LinearTestResponse -Data @{ issueLabels = New-LinearTestConnection -Nodes @($nodes) }
    }

    if ($query -match 'query ListUsers') {
        $users = @(
            (New-LinearTestUserNode -Id 'user-ada' -Name 'Ada Lovelace' -DisplayName 'ada' -Email 'ada@example.com'),
            (New-LinearTestUserNode -Id 'user-grace' -Name 'Grace Hopper' -DisplayName 'grace' -Email 'grace@example.com'),
            (New-LinearTestUserNode -Id 'user-alex-1' -Name 'Alex Smith' -DisplayName 'alex1' -Email 'alex.one@example.com'),
            (New-LinearTestUserNode -Id 'user-alex-2' -Name 'Alex Smith' -DisplayName 'alex2' -Email 'alex.two@example.com')
        )
        if ($variables.includeDisabled -eq $true) {
            $disabled = New-LinearTestUserNode -Id 'user-old' -Name 'Old Timer' -DisplayName 'old' -Email 'old@example.com'
            $disabled['active'] = $false
            $users += $disabled
        }
        return New-LinearTestResponse -Data @{ users = New-LinearTestConnection -Nodes $users }
    }

    if ($query -match 'query Viewer') {
        return New-LinearTestResponse -Data @{
            viewer       = New-LinearTestUserNode -Id 'user-ada' -Name 'Ada Lovelace' -DisplayName 'ada' -Email 'ada@example.com'
            organization = @{ id = 'org-acme'; name = 'Acme'; urlKey = 'acme' }
        }
    }

    if ($query -match 'query ListProjects') {
        $projects = @(
            @{
                id = 'project-web'; name = 'Website'; slugId = 'a1b2c3d4e5f6'; url = 'https://linear.app/acme/project/website-a1b2c3d4e5f6'; status = @{ name = 'In Progress' }
                lead = @{ id = 'user-grace'; name = 'Grace Hopper' }; progress = 0.5; startDate = '2026-09-01'; targetDate = '2026-12-01'; archivedAt = $null
            }
            @{
                id = 'project-mobile'; name = 'Mobile App'; slugId = 'f6e5d4c3b2a1'; url = 'https://linear.app/acme/project/mobile-app-f6e5d4c3b2a1'; status = @{ name = 'Planned' }
                lead = $null; progress = 0; startDate = $null; targetDate = $null; archivedAt = $null
            }
        )
        if ($variables.includeArchived -eq $true) {
            $projects += @{
                id = 'project-legacy'; name = 'Legacy'; slugId = '0a0b0c0d0e0f'; url = 'https://linear.app/acme/project/legacy-0a0b0c0d0e0f'; status = @{ name = 'Completed' }
                lead = $null; progress = 1; startDate = $null; targetDate = $null; archivedAt = '2026-01-01T00:00:00.000Z'
            }
        }
        return New-LinearTestResponse -Data @{ projects = New-LinearTestConnection -Nodes $projects }
    }

    if ($query -match 'query ListProjectMilestones') {
        # Without a filter, every milestone in the workspace.
        $projectId = if ($variables.ContainsKey('filter')) { $variables.filter.project.id.eq } else { 'project-web' }
        $nodes = if ($projectId -eq 'project-web') {
            @(
                @{ id = 'milestone-beta'; name = 'Beta'; description = $null; targetDate = '2026-12-01'; status = 'next'; progress = 0.1; sortOrder = 2; project = @{ id = 'project-web'; name = 'Website' } }
                @{ id = 'milestone-alpha'; name = 'Alpha'; description = 'First cut'; targetDate = '2026-11-01'; status = 'done'; progress = 1; sortOrder = 1; project = @{ id = 'project-web'; name = 'Website' } }
            )
        }
        else { @() }
        return New-LinearTestResponse -Data @{ projectMilestones = New-LinearTestConnection -Nodes $nodes }
    }

    if ($query -match 'query GetProjectMilestone|mutation (Create|Update|Delete)ProjectMilestone') {
        # Milestone writes: the id 'missing' does not exist, and the name 'reject' is rejected.
        $milestoneError = New-LinearTestError -Message 'Entity not found: ProjectMilestone' -Code 'INPUT_ERROR'
        $newMilestone = {
            param($Id, $Name, $ProjectId, $TargetDate, $Description)
            @{
                id = $Id; name = $Name; description = $Description; targetDate = $TargetDate; status = 'unstarted'; progress = 0; sortOrder = 3
                project = @{ id = $ProjectId; name = $(if ($ProjectId -eq 'project-mobile') { 'Mobile App' } else { 'Website' }) }
            }
        }
        if ($query -match 'query GetProjectMilestone') {
            if ($variables.id -eq 'missing') { return New-LinearTestResponse -Data $null -Errors @($milestoneError) }
            return New-LinearTestResponse -Data @{ projectMilestone = (& $newMilestone $variables.id 'Beta' 'project-web' '2026-12-01' $null) }
        }
        if ($query -match 'mutation CreateProjectMilestone') {
            $milestoneInput = $variables.input
            if ($milestoneInput['name'] -eq 'reject') {
                return New-LinearTestResponse -Data @{ projectMilestoneCreate = $null } -Errors @(New-LinearTestError -Message 'Argument Validation Error' -Code 'INPUT_ERROR')
            }
            $node = & $newMilestone 'milestone-new' $milestoneInput['name'] $milestoneInput['projectId'] $milestoneInput['targetDate'] $milestoneInput['description']
            return New-LinearTestResponse -Data @{ projectMilestoneCreate = @{ success = $true; projectMilestone = $node } }
        }
        if ($query -match 'mutation UpdateProjectMilestone') {
            if ($variables.id -eq 'missing') { return New-LinearTestResponse -Data @{ projectMilestoneUpdate = $null } -Errors @($milestoneError) }
            $milestoneInput = $variables.input
            $name = if ($milestoneInput.Contains('name')) { $milestoneInput['name'] } else { 'Beta' }
            $projectId = if ($milestoneInput.Contains('projectId')) { $milestoneInput['projectId'] } else { 'project-web' }
            $targetDate = if ($milestoneInput.Contains('targetDate')) { $milestoneInput['targetDate'] } else { '2026-12-01' }
            $node = & $newMilestone $variables.id $name $projectId $targetDate $milestoneInput['description']
            return New-LinearTestResponse -Data @{ projectMilestoneUpdate = @{ success = $true; projectMilestone = $node } }
        }
        if ($variables.id -eq 'missing') { return New-LinearTestResponse -Data @{ projectMilestoneDelete = $null } -Errors @($milestoneError) }
        return New-LinearTestResponse -Data @{ projectMilestoneDelete = @{ success = $true; entityId = $variables.id } }
    }

    if ($query -match 'query ListTemplates') {
        return New-LinearTestResponse -Data @{
            templates = @(
                @{ id = 'template-bug'; name = 'Bug report'; type = 'issue'; description = 'Workspace bug form'; content = '## Steps'; lastAppliedAt = $null; team = $null }
                @{ id = 'template-eng-bug'; name = 'Bug report'; type = 'issue'; description = 'ENG bug form'; content = '## Repro'; lastAppliedAt = $null; team = @{ id = 'team-eng'; key = 'ENG' } }
                @{ id = 'template-ops-incident'; name = 'Incident'; type = 'issue'; description = $null; content = $null; lastAppliedAt = $null; team = @{ id = 'team-ops'; key = 'OPS' } }
                @{ id = 'template-kickoff'; name = 'Kickoff'; type = 'project'; description = $null; content = $null; lastAppliedAt = $null; team = $null }
                @{ id = 'template-rfc'; name = 'RFC'; type = 'document'; description = $null; content = $null; lastAppliedAt = $null; team = $null }
            )
        }
    }

    if ($query -match 'query ListCycles') {
        $filter = if ($variables.ContainsKey('filter')) { $variables.filter } else { @{} }
        $cycles = @(
            # Deliberately not sorted, so sorting is tested.
            @{ id = 'cycle-ops-3'; number = 3; team = 'team-ops'; flags = @('isActive') }
            @{ id = 'cycle-eng-12'; number = 12; team = 'team-eng'; flags = @('isActive') }
            @{ id = 'cycle-eng-10'; number = 10; team = 'team-eng'; flags = @('isPast') }
            @{ id = 'cycle-eng-13'; number = 13; team = 'team-eng'; flags = @('isNext', 'isFuture'); name = 'Release sprint' }
            @{ id = 'cycle-eng-11'; number = 11; team = 'team-eng'; flags = @('isPrevious', 'isPast') }
        )
        $nodes = foreach ($cycle in $cycles) {
            if ($filter.ContainsKey('team') -and $filter.team.id.eq -ne $cycle.team) { continue }
            if ($filter.ContainsKey('number') -and $cycle.number -notin $filter.number.in) { continue }
            if ($filter.ContainsKey('or') -and -not @($filter.or | Where-Object { @($_.Keys)[0] -in $cycle.flags }).Count) { continue }
            $node = [ordered]@{
                id          = $cycle.id
                number      = $cycle.number
                name        = if ($cycle.ContainsKey('name')) { $cycle.name } else { $null }
                startsAt    = '2026-10-12T00:00:00.000Z'
                endsAt      = '2026-10-26T00:00:00.000Z'
                completedAt = $null
                progress    = 0.25
                team        = @{ id = $cycle.team; key = $(if ($cycle.team -eq 'team-ops') { 'OPS' } else { 'ENG' }) }
            }
            foreach ($flag in 'isActive', 'isNext', 'isPrevious', 'isPast', 'isFuture') { $node[$flag] = $flag -in $cycle.flags }
            $node
        }
        return New-LinearTestResponse -Data @{ cycles = New-LinearTestConnection -Nodes @($nodes) }
    }

    $null
}

function New-LinearTestUserNode {
    param(
        [string] $Id = 'user-ada',
        [string] $Name = 'Ada Lovelace',
        [string] $DisplayName = 'ada',
        [string] $Email = 'ada@example.com'
    )
    [ordered]@{
        id          = $Id
        name        = $Name
        displayName = $DisplayName
        email       = $Email
        admin       = $false
        active      = $true
    }
}

function Get-RequestVariable {
    # Returns a request variable by dot path ('input.issueId'), or $null when any part is missing.
    # Safe under Set-StrictMode, which build.ps1 turns on and Pester inherits: there, reading a
    # missing key of a parsed request with dot notation throws.
    param([Parameter(Mandatory)][string] $Body, [Parameter(Mandatory)][string] $Path)
    $current = (Get-RequestBody -Body $Body)['variables']
    foreach ($segment in $Path.Split('.')) {
        if ($current -isnot [System.Collections.IDictionary] -or -not $current.Contains($segment)) { return $null }
        $current = $current[$segment]
    }
    $current
}

function Get-RequestOperation {
    # Returns the operation name of the GraphQL document passed to Send-LinearHttpRequest, such as 'CreateIssue'.
    param([Parameter(Mandatory)][string] $Body)
    $query = (Get-RequestBody -Body $Body).query
    if ($query -match '^\s*(query|mutation)\s+([_A-Za-z]\w*)') { return $Matches[2] }
    $null
}

function New-LinearTestCommentNode {
    param(
        [string] $Id = 'comment-1',
        [string] $Body = 'A comment',
        [string] $Author = 'Ada Lovelace',
        [string] $Bot,
        [string] $ParentId,
        [string] $Issue = 'ENG-1',
        [string] $ProjectId,
        [string] $CreatedAt = '2026-10-10T10:00:00.000Z',
        [string] $ResolvedAt
    )
    [ordered]@{
        id            = $Id
        body          = $Body
        url           = "https://linear.app/acme/comment/$Id"
        createdAt     = $CreatedAt
        updatedAt     = $CreatedAt
        editedAt      = $null
        resolvedAt    = if ($ResolvedAt) { $ResolvedAt } else { $null }
        quotedText    = $null
        parentId      = if ($ParentId) { $ParentId } else { $null }
        user          = if ($Bot) { $null } else { @{ id = 'user-' + $Author.Split(' ')[0].ToLowerInvariant(); name = $Author } }
        botActor      = if ($Bot) { @{ name = $Bot; type = 'github' } } else { $null }
        externalUser  = $null
        resolvingUser = if ($ResolvedAt) { @{ id = 'user-ada'; name = 'Ada Lovelace' } } else { $null }
        issue         = if ($ProjectId) { $null } else { @{ id = "issue-$Issue"; identifier = $Issue } }
        project       = if ($ProjectId) { @{ id = $ProjectId; name = 'Website' } } else { $null }
    }
}

function Get-LinearTestCommentResponse {
    # Serves the comment operations from a fixed set, or returns $null for any other request.
    #
    # ENG-1:   comment-3 (GitHub integration, resolved), comment-1 (Ada, open thread),
    #          comment-4 (Ada, written after comment-1) and comment-2 (Grace, a reply to comment-1
    #          written after comment-4); returned out of order
    # Website: comment-p1 (Ada)
    # ENG-404 and the comment id 'missing' do not exist. CreateComment rejects the body 'reject'.
    param([Parameter(Mandatory)][hashtable] $Request)

    $query = $Request.query
    $variables = if ($Request.ContainsKey('variables')) { $Request.variables } else { @{} }
    $comments = @{
        'comment-1'  = New-LinearTestCommentNode -Id 'comment-1' -Body "First comment`nSecond line" -CreatedAt '2026-10-10T10:00:00.000Z'
        'comment-2'  = New-LinearTestCommentNode -Id 'comment-2' -Body 'A reply' -Author 'Grace Hopper' -ParentId 'comment-1' -CreatedAt '2026-10-10T11:00:00.000Z'
        'comment-3'  = New-LinearTestCommentNode -Id 'comment-3' -Body 'Linked a pull request' -Bot 'GitHub' -CreatedAt '2026-10-09T09:00:00.000Z' -ResolvedAt '2026-10-09T12:00:00.000Z'
        'comment-4'  = New-LinearTestCommentNode -Id 'comment-4' -Body 'Another thread' -CreatedAt '2026-10-10T10:30:00.000Z'
        'comment-p1' = New-LinearTestCommentNode -Id 'comment-p1' -Body 'Project kickoff' -ProjectId 'project-web'
    }
    $notFound = New-LinearTestError -Message 'Entity not found: Comment' -Code 'INPUT_ERROR'

    if ($query -match 'query ListIssueComments') {
        if ($variables.id -eq 'ENG-404') {
            return New-LinearTestResponse -Data $null -Errors @(New-LinearTestError -Message 'Entity not found: Issue' -Code 'INPUT_ERROR' -Path 'issue')
        }
        $nodes = if ($variables.id -in 'ENG-1', 'issue-ENG-1') { @($comments['comment-2'], $comments['comment-4'], $comments['comment-1'], $comments['comment-3']) } else { @() }
        return New-LinearTestResponse -Data @{ issue = @{ comments = New-LinearTestConnection -Nodes $nodes } }
    }
    if ($query -match 'query ListComments') {
        $nodes = if ($variables.filter.project.id.eq -eq 'project-web') { @($comments['comment-p1']) } else { @() }
        return New-LinearTestResponse -Data @{ comments = New-LinearTestConnection -Nodes $nodes }
    }
    if ($query -match 'query GetComment') {
        if (-not $comments.ContainsKey($variables.id)) { return New-LinearTestResponse -Data $null -Errors @($notFound) }
        return New-LinearTestResponse -Data @{ comment = $comments[$variables.id] }
    }
    if ($query -match 'mutation CreateComment') {
        $commentInput = $variables.input
        if ($commentInput['body'] -eq 'reject') {
            return New-LinearTestResponse -Data @{ commentCreate = $null } -Errors @(New-LinearTestError -Message 'Argument Validation Error' -Code 'INPUT_ERROR')
        }
        $issueValue = if ($commentInput['issueId']) { $commentInput['issueId'] -replace '^issue-', '' } else { 'ENG-1' }
        $node = New-LinearTestCommentNode -Id 'comment-new' -Body $commentInput['body'] -ParentId $commentInput['parentId'] -Issue $issueValue -ProjectId $commentInput['projectId']
        return New-LinearTestResponse -Data @{ commentCreate = @{ success = $true; comment = $node } }
    }
    if ($query -match 'mutation UpdateComment') {
        if (-not $comments.ContainsKey($variables.id)) { return New-LinearTestResponse -Data @{ commentUpdate = $null } -Errors @($notFound) }
        $node = $comments[$variables.id]
        $node['body'] = $variables.input.body
        $node['editedAt'] = '2026-10-17T10:00:00.000Z'
        return New-LinearTestResponse -Data @{ commentUpdate = @{ success = $true; comment = $node } }
    }
    if ($query -match 'mutation (Resolve|Unresolve)Comment') {
        $field = if ($query -match 'mutation ResolveComment') { 'commentResolve' } else { 'commentUnresolve' }
        if (-not $comments.ContainsKey($variables.id)) { return New-LinearTestResponse -Data @{ $field = $null } -Errors @($notFound) }
        $node = $comments[$variables.id]
        $node['resolvedAt'] = if ($field -eq 'commentResolve') { '2026-10-17T10:00:00.000Z' } else { $null }
        return New-LinearTestResponse -Data @{ $field = @{ success = $true; comment = $node } }
    }
    if ($query -match 'mutation DeleteComment') {
        if (-not $comments.ContainsKey($variables.id)) { return New-LinearTestResponse -Data @{ commentDelete = $null } -Errors @($notFound) }
        return New-LinearTestResponse -Data @{ commentDelete = @{ success = $true; entityId = $variables.id } }
    }
    $null
}

function New-LinearTestAttachmentNode {
    param(
        [string] $Id = 'attachment-1',
        [string] $Title = 'screenshot.png',
        [string] $Subtitle,
        [string] $Url = 'https://uploads.linear.app/asset/screenshot.png',
        [string] $Issue = 'ENG-1',
        [string] $SourceType,
        [string] $CreatedAt = '2026-10-10T10:00:00.000Z',
        [System.Collections.IDictionary] $Metadata = @{}
    )
    [ordered]@{
        id         = $Id
        title      = $Title
        subtitle   = if ($Subtitle) { $Subtitle } else { $null }
        url        = $Url
        sourceType = if ($SourceType) { $SourceType } else { $null }
        metadata   = $Metadata
        createdAt  = $CreatedAt
        updatedAt  = $CreatedAt
        creator    = @{ id = 'user-ada'; name = 'Ada Lovelace' }
        issue      = @{ id = "issue-uuid-$Issue"; identifier = $Issue }
    }
}

function Get-LinearTestAttachmentResponse {
    # Serves the upload and attachment operations from a fixed set, or returns $null for any other request.
    #
    # Issues:      every identifier exists (UUID issue-uuid-<identifier>) except ENG-404.
    # ENG-1:       attachment-2 (GitHub link) and the older attachment-1 (upload); returned out of order.
    # Uploads:     the signed URL is https://storage.example/put/<file name>, the asset URL
    #              https://uploads.linear.app/asset/<file name>. Linear returns two signed headers
    #              (one value with a trailing space); for override.bin it also returns a content-type.
    #              noupload.png gets no upload URL.
    # Attachments: the title 'reject' is rejected; the attachment id 'missing' does not exist.
    param([Parameter(Mandatory)][hashtable] $Request)

    $query = $Request.query
    $variables = if ($Request.ContainsKey('variables')) { $Request.variables } else { @{} }
    $notFound = New-LinearTestError -Message 'Entity not found: Attachment' -Code 'INPUT_ERROR'
    $attachments = @{
        'attachment-1' = New-LinearTestAttachmentNode -Id 'attachment-1' -SourceType 'unknown' -CreatedAt '2026-10-09T09:00:00.000Z'
        'attachment-2' = New-LinearTestAttachmentNode -Id 'attachment-2' -Title 'Fix login' -Url 'https://github.com/acme/app/pull/42' -SourceType 'github' -Subtitle 'PR #42' -Metadata ([ordered]@{ status = 'merged'; reviews = @{ approved = 2 } })
    }

    if ($query -match 'query GetIssueTeam') {
        if ($variables.id -eq 'ENG-404') {
            return New-LinearTestResponse -Data @{ issue = $null } -Errors @(New-LinearTestError -Message 'Entity not found: Issue' -Code 'INPUT_ERROR')
        }
        return New-LinearTestResponse -Data @{ issue = @{ id = "issue-uuid-$($variables.id)"; identifier = $variables.id; team = @{ id = 'team-eng'; key = 'ENG' } } }
    }
    if ($query -match 'mutation RequestFileUpload') {
        if ($variables.filename -eq 'noupload.png') {
            return New-LinearTestResponse -Data @{ fileUpload = @{ success = $false; uploadFile = $null } }
        }
        $headers = @(
            @{ key = 'x-goog-content-length-range'; value = "0,$($variables.size)" }
            @{ key = 'Cache-Control'; value = 'public, max-age=31536000 ' }
        )
        if ($variables.filename -eq 'override.bin') { $headers += @{ key = 'content-type'; value = 'application/x-custom' } }
        return New-LinearTestResponse -Data @{
            fileUpload = @{
                success    = $true
                uploadFile = @{
                    uploadUrl = "https://storage.example/put/$($variables.filename)"
                    assetUrl  = "https://uploads.linear.app/asset/$($variables.filename)"
                    headers   = $headers
                }
            }
        }
    }
    if ($query -match 'mutation CreateAttachment') {
        $attachmentInput = $variables.input
        if ($attachmentInput['title'] -eq 'reject') {
            return New-LinearTestResponse -Data @{ attachmentCreate = $null } -Errors @(New-LinearTestError -Message 'Argument Validation Error' -Code 'INPUT_ERROR')
        }
        $issue = $attachmentInput['issueId'] -replace '^issue-uuid-', ''
        $metadata = if ($attachmentInput.Contains('metadata')) { $attachmentInput['metadata'] } else { @{} }
        $node = New-LinearTestAttachmentNode -Id 'attachment-new' -Title $attachmentInput['title'] -Subtitle $attachmentInput['subtitle'] -Url $attachmentInput['url'] -Issue $issue -Metadata $metadata
        return New-LinearTestResponse -Data @{ attachmentCreate = @{ success = $true; attachment = $node } }
    }
    if ($query -match 'mutation LinkAttachmentUrl') {
        if ($variables.issueId -eq 'ENG-404') {
            return New-LinearTestResponse -Data @{ attachmentLinkURL = $null } -Errors @(New-LinearTestError -Message 'Entity not found: Issue' -Code 'INPUT_ERROR')
        }
        $title = if ($variables.ContainsKey('title')) { $variables.title } else { 'Title from Linear' }
        $source = if ($variables.url -match 'github\.com') { 'github' } else { $null }
        $node = New-LinearTestAttachmentNode -Id 'attachment-link' -Title $title -Url $variables.url -Issue $variables.issueId -SourceType $source
        return New-LinearTestResponse -Data @{ attachmentLinkURL = @{ success = $true; attachment = $node } }
    }
    if ($query -match 'query ListIssueAttachments') {
        if ($variables.id -eq 'ENG-404') {
            return New-LinearTestResponse -Data $null -Errors @(New-LinearTestError -Message 'Entity not found: Issue' -Code 'INPUT_ERROR' -Path 'issue')
        }
        $nodes = if ($variables.id -in 'ENG-1', 'issue-uuid-ENG-1') { @($attachments['attachment-2'], $attachments['attachment-1']) } else { @() }
        return New-LinearTestResponse -Data @{ issue = @{ attachments = New-LinearTestConnection -Nodes $nodes } }
    }
    if ($query -match 'query GetAttachment') {
        if (-not $attachments.ContainsKey($variables.id)) { return New-LinearTestResponse -Data $null -Errors @($notFound) }
        return New-LinearTestResponse -Data @{ attachment = $attachments[$variables.id] }
    }
    if ($query -match 'mutation UpdateAttachment') {
        if ($variables.id -eq 'attachment-link') {
            $node = New-LinearTestAttachmentNode -Id 'attachment-link' -Title $variables.input['title'] -Url 'https://example.com/doc' -Metadata $variables.input['metadata']
            return New-LinearTestResponse -Data @{ attachmentUpdate = @{ success = $true; attachment = $node } }
        }
        if (-not $attachments.ContainsKey($variables.id)) { return New-LinearTestResponse -Data @{ attachmentUpdate = $null } -Errors @($notFound) }
        $node = $attachments[$variables.id]
        $node['title'] = $variables.input['title']
        if ($variables.input.Contains('subtitle')) { $node['subtitle'] = $variables.input['subtitle'] }
        if ($variables.input.Contains('metadata')) { $node['metadata'] = $variables.input['metadata'] }
        return New-LinearTestResponse -Data @{ attachmentUpdate = @{ success = $true; attachment = $node } }
    }
    if ($query -match 'mutation DeleteAttachment') {
        if (-not $attachments.ContainsKey($variables.id)) { return New-LinearTestResponse -Data @{ attachmentDelete = $null } -Errors @($notFound) }
        return New-LinearTestResponse -Data @{ attachmentDelete = @{ success = $true; entityId = $variables.id } }
    }
    $null
}

function Get-LinearTestRelationResponse {
    # Serves the issue relation operations, or returns $null for any other request.
    #
    # ENG-1 blocks ENG-2 (relation-1, older) and is related to ENG-3 (relation-2); ENG-4 is a
    # duplicate of ENG-1 (relation-3). ENG-404 and the relation id 'missing' do not exist.
    # Creating a relation to ENG-404 fails.
    param([Parameter(Mandatory)][hashtable] $Request)

    $query = $Request.query
    $variables = if ($Request.ContainsKey('variables')) { $Request.variables } else { @{} }
    function New-TestIssueRef([string] $Identifier, [string] $State = 'Todo') {
        @{ id = "issue-uuid-$Identifier"; identifier = $Identifier; title = "Issue $Identifier"; state = @{ name = $State } }
    }
    function New-TestRelation([string] $Id, [string] $Type, [string] $From, [string] $To, [string] $CreatedAt) {
        @{ id = $Id; type = $Type; createdAt = $CreatedAt; issue = (New-TestIssueRef $From); relatedIssue = (New-TestIssueRef $To 'In Progress') }
    }
    $notFound = New-LinearTestError -Message 'Entity not found: Issue' -Code 'INPUT_ERROR' -Path 'issue'

    if ($query -match 'query ListIssue(Inverse)?Relations') {
        $inverse = $query -match 'ListIssueInverseRelations'
        if ($variables.id -eq 'ENG-404') { return New-LinearTestResponse -Data $null -Errors @($notFound) }
        $isEng1 = $variables.id -in 'ENG-1', 'issue-uuid-ENG-1'
        $nodes = if (-not $isEng1) { @() }
        elseif ($inverse) { @(New-TestRelation 'relation-3' 'duplicate' 'ENG-4' 'ENG-1' '2026-10-12T00:00:00.000Z') }
        else {
            @(
                (New-TestRelation 'relation-2' 'related' 'ENG-1' 'ENG-3' '2026-10-11T00:00:00.000Z'),
                (New-TestRelation 'relation-1' 'blocks' 'ENG-1' 'ENG-2' '2026-10-10T00:00:00.000Z')
            )
        }
        $field = if ($inverse) { 'inverseRelations' } else { 'relations' }
        return New-LinearTestResponse -Data @{ issue = @{ $field = New-LinearTestConnection -Nodes $nodes } }
    }
    if ($query -match 'mutation CreateIssueRelation') {
        $relationInput = $variables.input
        if ('ENG-404' -in $relationInput['issueId'], $relationInput['relatedIssueId']) {
            return New-LinearTestResponse -Data @{ issueRelationCreate = $null } -Errors @($notFound)
        }
        $node = New-TestRelation 'relation-new' $relationInput['type'] $relationInput['issueId'] $relationInput['relatedIssueId'] '2026-10-17T00:00:00.000Z'
        return New-LinearTestResponse -Data @{ issueRelationCreate = @{ success = $true; issueRelation = $node } }
    }
    if ($query -match 'mutation DeleteIssueRelation') {
        if ($variables.id -eq 'missing') {
            return New-LinearTestResponse -Data @{ issueRelationDelete = $null } -Errors @(New-LinearTestError -Message 'Entity not found: IssueRelation' -Code 'INPUT_ERROR')
        }
        return New-LinearTestResponse -Data @{ issueRelationDelete = @{ success = $true; entityId = $variables.id } }
    }
    $null
}
