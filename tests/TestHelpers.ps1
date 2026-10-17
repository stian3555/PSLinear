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
        [int] $Priority = 2
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
    # Cycles:   ENG 10 (past), 11 (previous), 12 (active), 13 (next); OPS 3 (active)
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

    if ($query -match 'query ListCycles') {
        $filter = if ($variables.ContainsKey('filter')) { $variables.filter } else { @{} }
        $cycles = @(
            # Deliberately not sorted, so sorting is tested.
            @{ id = 'cycle-ops-3'; number = 3; team = 'team-ops'; flags = @('isActive') }
            @{ id = 'cycle-eng-12'; number = 12; team = 'team-eng'; flags = @('isActive') }
            @{ id = 'cycle-eng-10'; number = 10; team = 'team-eng'; flags = @('isPast') }
            @{ id = 'cycle-eng-13'; number = 13; team = 'team-eng'; flags = @('isNext', 'isFuture') }
            @{ id = 'cycle-eng-11'; number = 11; team = 'team-eng'; flags = @('isPrevious', 'isPast') }
        )
        $nodes = foreach ($cycle in $cycles) {
            if ($filter.ContainsKey('team') -and $filter.team.id.eq -ne $cycle.team) { continue }
            if ($filter.ContainsKey('number') -and $cycle.number -notin $filter.number.in) { continue }
            if ($filter.ContainsKey('or') -and -not @($filter.or | Where-Object { @($_.Keys)[0] -in $cycle.flags }).Count) { continue }
            $node = [ordered]@{
                id          = $cycle.id
                number      = $cycle.number
                name        = $null
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
