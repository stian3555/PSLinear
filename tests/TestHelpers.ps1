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
    # Projects: Website (ENG, In Progress, lead Grace, label Customer), Mobile App (ENG and OPS,
    #           Planned), and the archived Legacy (only with includeArchived)
    # Project statuses: Backlog, Planned, In Progress and Beta testing (both started), Paused,
    #           Completed, Canceled
    # Project labels: Customer, Infrastructure, group Theme with Growth, a second Growth (ENG),
    #           retired Old
    # Initiatives: Q1 growth (Active, owner Ada, lead team ENG, project Website, label Strategic),
    #           Platform reliability (Planned, project Mobile App), and the archived Old goals
    #           (only with includeArchived)
    # Initiative labels: Strategic, Bets, group Horizon with Now, retired Legacy
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

    if ($query -match 'query ListProjectStatuses') {
        # Deliberately not in workflow order, so sorting is tested.
        return New-LinearTestResponse -Data @{
            projectStatuses = New-LinearTestConnection -Nodes @(
                @{ id = 'pstatus-completed'; name = 'Completed'; type = 'completed'; position = 5 }
                @{ id = 'pstatus-beta'; name = 'Beta testing'; type = 'started'; position = 3 }
                @{ id = 'pstatus-backlog'; name = 'Backlog'; type = 'backlog'; position = 0 }
                @{ id = 'pstatus-progress'; name = 'In Progress'; type = 'started'; position = 2 }
                @{ id = 'pstatus-canceled'; name = 'Canceled'; type = 'canceled'; position = 6 }
                @{ id = 'pstatus-planned'; name = 'Planned'; type = 'planned'; position = 1 }
                @{ id = 'pstatus-paused'; name = 'Paused'; type = 'paused'; position = 4 }
            )
        }
    }

    if ($query -match 'query ListProjectLabels') {
        $themeGroup = @{ name = 'Theme' }
        return New-LinearTestResponse -Data @{
            projectLabels = New-LinearTestConnection -Nodes @(
                @{ id = 'plabel-infra'; name = 'Infrastructure'; isGroup = $false; retiredAt = $null; parent = $null; team = $null }
                @{ id = 'plabel-customer'; name = 'Customer'; isGroup = $false; retiredAt = $null; parent = $null; team = $null }
                @{ id = 'plabel-theme'; name = 'Theme'; isGroup = $true; retiredAt = $null; parent = $null; team = $null }
                @{ id = 'plabel-growth'; name = 'Growth'; isGroup = $false; retiredAt = $null; parent = $themeGroup; team = $null }
                @{ id = 'plabel-eng-growth'; name = 'Growth'; isGroup = $false; retiredAt = $null; parent = $null; team = @{ id = 'team-eng'; key = 'ENG' } }
                @{ id = 'plabel-old'; name = 'Old'; isGroup = $false; retiredAt = '2026-01-01T00:00:00.000Z'; parent = $null; team = $null }
            )
        }
    }

    if ($query -match 'query ListInitiatives') {
        $initiatives = @((New-LinearTestInitiativeNode -Id 'initiative-growth'), (New-LinearTestInitiativeNode -Id 'initiative-reliability'))
        if ($variables.includeArchived -eq $true) { $initiatives += New-LinearTestInitiativeNode -Id 'initiative-old' }
        return New-LinearTestResponse -Data @{ initiatives = New-LinearTestConnection -Nodes $initiatives }
    }

    if ($query -match 'query ListInitiativeLabels') {
        return New-LinearTestResponse -Data @{
            initiativeLabels = New-LinearTestConnection -Nodes @(
                @{ id = 'ilabel-strategic'; name = 'Strategic'; isGroup = $false; retiredAt = $null; parent = $null }
                @{ id = 'ilabel-bets'; name = 'Bets'; isGroup = $false; retiredAt = $null; parent = $null }
                @{ id = 'ilabel-horizon'; name = 'Horizon'; isGroup = $true; retiredAt = $null; parent = $null }
                @{ id = 'ilabel-now'; name = 'Now'; isGroup = $false; retiredAt = $null; parent = @{ name = 'Horizon' } }
                @{ id = 'ilabel-legacy'; name = 'Legacy'; isGroup = $false; retiredAt = '2026-01-01T00:00:00.000Z'; parent = $null }
            )
        }
    }

    if ($query -match 'query ListProjects\b') {
        $projects = @((New-LinearTestProjectNode -Id 'project-web'), (New-LinearTestProjectNode -Id 'project-mobile'))
        if ($variables.includeArchived -eq $true) { $projects += New-LinearTestProjectNode -Id 'project-legacy' }
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
        [string] $InitiativeId,
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
        issue         = if ($ProjectId -or $InitiativeId) { $null } else { @{ id = "issue-$Issue"; identifier = $Issue } }
        project       = if ($ProjectId) { @{ id = $ProjectId; name = 'Website' } } else { $null }
        initiative    = if ($InitiativeId) { @{ id = $InitiativeId; name = 'Q1 growth' } } else { $null }
    }
}

function Get-LinearTestCommentResponse {
    # Serves the comment operations from a fixed set, or returns $null for any other request.
    #
    # ENG-1:   comment-3 (GitHub integration, resolved), comment-1 (Ada, open thread),
    #          comment-4 (Ada, written after comment-1) and comment-2 (Grace, a reply to comment-1
    #          written after comment-4); returned out of order
    # Website: comment-p1 (Ada)
    # Q1 growth (initiative-growth): comment-i1 (Ada)
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
        'comment-i1' = New-LinearTestCommentNode -Id 'comment-i1' -Body 'Initiative kickoff' -InitiativeId 'initiative-growth'
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
        $nodes = if ((Get-LinearNestedTestValue -InputObject $variables -Path 'filter.project.id.eq') -eq 'project-web') {
            @($comments['comment-p1'])
        }
        elseif ((Get-LinearNestedTestValue -InputObject $variables -Path 'filter.initiative.id.eq') -eq 'initiative-growth') {
            @($comments['comment-i1'])
        }
        else { @() }
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
        $node = New-LinearTestCommentNode -Id 'comment-new' -Body $commentInput['body'] -ParentId $commentInput['parentId'] -Issue $issueValue `
            -ProjectId $commentInput['projectId'] -InitiativeId $commentInput['initiativeId']
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

function New-LinearTestProjectNode {
    # Returns one of the fixture projects (project-web, project-mobile, project-legacy) as Linear
    # sends it. -Detail adds the fields of GetProject: content, every team and label, members and
    # initiatives. -Change applies a ProjectCreateInput or ProjectUpdateInput hashtable to it.
    param(
        [Parameter(Mandatory)][string] $Id,
        [switch] $Detail,
        [System.Collections.IDictionary] $Change = @{}
    )
    $teams = @{ 'team-eng' = @{ id = 'team-eng'; key = 'ENG' }; 'team-ops' = @{ id = 'team-ops'; key = 'OPS' } }
    $statuses = @{
        'pstatus-backlog'   = @{ id = 'pstatus-backlog'; name = 'Backlog'; type = 'backlog' }
        'pstatus-planned'   = @{ id = 'pstatus-planned'; name = 'Planned'; type = 'planned' }
        'pstatus-progress'  = @{ id = 'pstatus-progress'; name = 'In Progress'; type = 'started' }
        'pstatus-beta'      = @{ id = 'pstatus-beta'; name = 'Beta testing'; type = 'started' }
        'pstatus-paused'    = @{ id = 'pstatus-paused'; name = 'Paused'; type = 'paused' }
        'pstatus-completed' = @{ id = 'pstatus-completed'; name = 'Completed'; type = 'completed' }
        'pstatus-canceled'  = @{ id = 'pstatus-canceled'; name = 'Canceled'; type = 'canceled' }
    }
    $users = @{ 'user-ada' = @{ id = 'user-ada'; name = 'Ada Lovelace' }; 'user-grace' = @{ id = 'user-grace'; name = 'Grace Hopper' } }
    $labels = @{
        'plabel-customer'   = @{ id = 'plabel-customer'; name = 'Customer' }
        'plabel-infra'      = @{ id = 'plabel-infra'; name = 'Infrastructure' }
        'plabel-growth'     = @{ id = 'plabel-growth'; name = 'Growth' }
        'plabel-eng-growth' = @{ id = 'plabel-eng-growth'; name = 'Growth' }
    }

    $values = switch ($Id) {
        'project-web' {
            @{ name = 'Website'; slugId = 'a1b2c3d4e5f6'; statusId = 'pstatus-progress'; leadId = 'user-grace'; teamIds = @('team-eng'); labelIds = @('plabel-customer')
                memberIds = @('user-ada', 'user-grace'); health = 'onTrack'; priority = 2; progress = 0.5; startDate = '2026-09-01'; targetDate = '2026-12-01'
                description = 'The public site'; content = "# Website`nRelaunch plan"; archivedAt = $null; initiatives = @('Growth')
            }
        }
        'project-mobile' {
            @{ name = 'Mobile App'; slugId = 'f6e5d4c3b2a1'; statusId = 'pstatus-planned'; leadId = $null; teamIds = @('team-eng', 'team-ops'); labelIds = @()
                memberIds = @(); health = $null; priority = 0; progress = 0; startDate = $null; targetDate = $null
                description = ''; content = ''; archivedAt = $null; initiatives = @()
            }
        }
        'project-legacy' {
            @{ name = 'Legacy'; slugId = '0a0b0c0d0e0f'; statusId = 'pstatus-completed'; leadId = $null; teamIds = @('team-eng'); labelIds = @()
                memberIds = @(); health = $null; priority = 0; progress = 1; startDate = $null; targetDate = $null
                description = ''; content = ''; archivedAt = '2026-01-01T00:00:00.000Z'; initiatives = @()
            }
        }
        default {
            @{ name = 'New project'; slugId = '123456abcdef'; statusId = 'pstatus-backlog'; leadId = $null; teamIds = @('team-eng'); labelIds = @()
                memberIds = @(); health = $null; priority = 0; progress = 0; startDate = $null; targetDate = $null
                description = ''; content = ''; archivedAt = $null; initiatives = @()
            }
        }
    }
    foreach ($key in $Change.Keys) { $values[$key] = $Change[$key] }

    $slug = ($values.name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    $teamNodes = @(foreach ($teamId in $values.teamIds) { $teams[$teamId] })
    $labelNodes = @(foreach ($labelId in $values.labelIds) { $labels[$labelId] })
    $node = [ordered]@{
        id            = $Id
        name          = $values.name
        slugId        = $values.slugId
        url           = "https://linear.app/acme/project/$slug-$($values.slugId)"
        description   = $values.description
        priority      = $values.priority
        priorityLabel = @('No priority', 'Urgent', 'High', 'Medium', 'Low')[$values.priority]
        health        = $values.health
        progress      = $values.progress
        startDate     = $values.startDate
        targetDate    = $values.targetDate
        startedAt     = $null
        completedAt   = $null
        canceledAt    = $null
        archivedAt    = $values.archivedAt
        status        = $statuses[$values.statusId]
        lead          = if ($values.leadId) { $users[$values.leadId] } else { $null }
        teams         = @{ nodes = $teamNodes }
        labels        = @{ nodes = $labelNodes }
    }
    if ($Detail) {
        $node['content'] = $values.content
        $node['allTeams'] = @{ nodes = $teamNodes }
        $node['allLabels'] = @{ nodes = $labelNodes }
        $node['members'] = @{ nodes = @(foreach ($userId in $values.memberIds) { $users[$userId] }) }
        $node['initiatives'] = @{ nodes = @(foreach ($initiative in $values.initiatives) { @{ id = "initiative-$($initiative.ToLowerInvariant())"; name = $initiative } }) }
    }
    $node
}

function New-LinearTestProjectUpdateNode {
    param(
        [string] $Id = 'update-1',
        [string] $Body = 'All good',
        [string] $Health = 'onTrack',
        [string] $ProjectId = 'project-web',
        [string] $CreatedAt = '2026-10-01T09:00:00.000Z'
    )
    [ordered]@{
        id        = $Id
        body      = $Body
        health    = if ($Health) { $Health } else { $null }
        url       = "https://linear.app/acme/project/website-a1b2c3d4e5f6/updates#$Id"
        createdAt = $CreatedAt
        editedAt  = $null
        user      = @{ id = 'user-ada'; name = 'Ada Lovelace' }
        project   = @{ id = $ProjectId; name = $(if ($ProjectId -eq 'project-mobile') { 'Mobile App' } else { 'Website' }) }
    }
}

function Get-LinearTestProjectResponse {
    # Serves the project and project update operations, or returns $null for any other request.
    #
    # GetProject:    project-web, project-mobile and project-legacy, by id or slug id; anything
    #                else does not exist.
    # Create/Update: the name 'reject' is rejected; updating or deleting 'project-missing' fails.
    # Updates:       Website has update-2 (AtRisk, newest) and update-1 (OnTrack); Mobile App has
    #                update-m1 (no health). The update id 'missing' does not exist, and the body
    #                'reject' is rejected.
    param([Parameter(Mandatory)][hashtable] $Request)

    $query = $Request.query
    $variables = if ($Request.ContainsKey('variables')) { $Request.variables } else { @{} }
    $slugs = @{ 'a1b2c3d4e5f6' = 'project-web'; 'f6e5d4c3b2a1' = 'project-mobile'; '0a0b0c0d0e0f' = 'project-legacy' }
    $known = @('project-web', 'project-mobile', 'project-legacy')
    $updates = [ordered]@{
        'update-2'  = New-LinearTestProjectUpdateNode -Id 'update-2' -Body "Slipping`nWaiting on design" -Health 'atRisk' -CreatedAt '2026-10-08T09:00:00.000Z'
        'update-1'  = New-LinearTestProjectUpdateNode -Id 'update-1' -Body 'All good' -Health 'onTrack' -CreatedAt '2026-10-01T09:00:00.000Z'
        'update-m1' = New-LinearTestProjectUpdateNode -Id 'update-m1' -Body 'Kickoff' -Health '' -ProjectId 'project-mobile' -CreatedAt '2026-09-20T09:00:00.000Z'
    }
    $rejected = New-LinearTestError -Message 'Argument Validation Error' -Code 'INPUT_ERROR'

    if ($query -match 'query GetProject\b') {
        $projectId = if ($slugs.ContainsKey($variables.id)) { $slugs[$variables.id] } else { $variables.id }
        if ($projectId -notin $known) {
            return New-LinearTestResponse -Data $null -Errors @(New-LinearTestError -Message 'Entity not found: Project' -Code 'INPUT_ERROR' -Path 'project')
        }
        return New-LinearTestResponse -Data @{ project = New-LinearTestProjectNode -Id $projectId -Detail }
    }
    if ($query -match 'mutation CreateProject\b') {
        $projectInput = $variables.input
        if ($projectInput['name'] -eq 'reject') { return New-LinearTestResponse -Data @{ projectCreate = $null } -Errors @($rejected) }
        return New-LinearTestResponse -Data @{ projectCreate = @{ success = $true; project = New-LinearTestProjectNode -Id 'project-new' -Change $projectInput } }
    }
    if ($query -match 'mutation UpdateProject\b') {
        $projectInput = $variables.input
        if ($variables.id -notin $known -or $projectInput['name'] -eq 'reject') {
            return New-LinearTestResponse -Data @{ projectUpdate = $null } -Errors @($rejected)
        }
        return New-LinearTestResponse -Data @{ projectUpdate = @{ success = $true; project = New-LinearTestProjectNode -Id $variables.id -Change $projectInput } }
    }
    if ($query -match 'mutation DeleteProject\b') {
        if ($variables.id -notin $known) { return New-LinearTestResponse -Data @{ projectDelete = $null } -Errors @($rejected) }
        return New-LinearTestResponse -Data @{ projectDelete = @{ success = $true } }
    }

    if ($query -match 'query ListProjectUpdates') {
        $projectId = Get-LinearNestedTestValue -InputObject $variables -Path 'filter.project.id.eq'
        $nodes = @($updates.Values | Where-Object { -not $projectId -or $_.project.id -eq $projectId })
        return New-LinearTestResponse -Data @{ projectUpdates = New-LinearTestConnection -Nodes $nodes }
    }
    if ($query -match 'query GetProjectUpdate') {
        if (-not $updates.Contains($variables.id)) {
            return New-LinearTestResponse -Data $null -Errors @(New-LinearTestError -Message 'Entity not found: ProjectUpdate' -Code 'INPUT_ERROR')
        }
        return New-LinearTestResponse -Data @{ projectUpdate = $updates[$variables.id] }
    }
    if ($query -match 'mutation CreateProjectUpdate') {
        $updateInput = $variables.input
        if ($updateInput['body'] -eq 'reject') { return New-LinearTestResponse -Data @{ projectUpdateCreate = $null } -Errors @($rejected) }
        $node = New-LinearTestProjectUpdateNode -Id 'update-new' -Body $updateInput['body'] -Health $updateInput['health'] -ProjectId $updateInput['projectId'] -CreatedAt '2026-10-17T09:00:00.000Z'
        return New-LinearTestResponse -Data @{ projectUpdateCreate = @{ success = $true; projectUpdate = $node } }
    }
    if ($query -match 'mutation UpdateProjectUpdate') {
        if (-not $updates.Contains($variables.id)) { return New-LinearTestResponse -Data @{ projectUpdateUpdate = $null } -Errors @($rejected) }
        $node = $updates[$variables.id]
        foreach ($key in $variables.input.Keys) { $node[$key] = $variables.input[$key] }
        $node['editedAt'] = '2026-10-17T10:00:00.000Z'
        return New-LinearTestResponse -Data @{ projectUpdateUpdate = @{ success = $true; projectUpdate = $node } }
    }
    if ($query -match 'mutation ArchiveProjectUpdate') {
        if (-not $updates.Contains($variables.id)) { return New-LinearTestResponse -Data @{ projectUpdateArchive = $null } -Errors @($rejected) }
        return New-LinearTestResponse -Data @{ projectUpdateArchive = @{ success = $true } }
    }
    $null
}

function Get-LinearNestedTestValue {
    # Reads a dot path from nested hashtables, or returns $null when any part is missing (strict-mode safe).
    param([AllowNull()][object] $InputObject, [Parameter(Mandatory)][string] $Path)
    $current = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($current -isnot [System.Collections.IDictionary] -or -not $current.Contains($segment)) { return $null }
        $current = $current[$segment]
    }
    $current
}

function New-LinearTestInitiativeNode {
    # Returns one of the fixture initiatives (initiative-growth, initiative-reliability,
    # initiative-old) as Linear sends it. -Detail adds the fields of GetInitiative. -Change applies
    # an InitiativeCreateInput or InitiativeUpdateInput hashtable to it.
    param(
        [Parameter(Mandatory)][string] $Id,
        [switch] $Detail,
        [System.Collections.IDictionary] $Change = @{}
    )
    $users = @{ 'user-ada' = @{ id = 'user-ada'; name = 'Ada Lovelace' }; 'user-grace' = @{ id = 'user-grace'; name = 'Grace Hopper' } }
    $teams = @{ 'team-eng' = @{ id = 'team-eng'; key = 'ENG' }; 'team-ops' = @{ id = 'team-ops'; key = 'OPS' } }
    $labels = @{
        'ilabel-strategic' = @{ id = 'ilabel-strategic'; name = 'Strategic' }
        'ilabel-bets'      = @{ id = 'ilabel-bets'; name = 'Bets' }
        'ilabel-now'       = @{ id = 'ilabel-now'; name = 'Now' }
    }
    $projects = @{ 'project-web' = @{ id = 'project-web'; name = 'Website' }; 'project-mobile' = @{ id = 'project-mobile'; name = 'Mobile App' } }

    $values = switch ($Id) {
        'initiative-growth' {
            @{ name = 'Q1 growth'; slugId = '5f2c9a1b7e3d'; status = 'Active'; health = 'onTrack'; priority = 2; ownerId = 'user-ada'; leadTeamId = 'team-eng'
                labelIds = @('ilabel-strategic'); projectIds = @('project-web'); targetDate = '2027-03-31'; description = 'Grow signups'
                content = "# Q1 growth`nPlan"; archivedAt = $null; subInitiatives = @('Growth: EMEA')
            }
        }
        'initiative-reliability' {
            @{ name = 'Platform reliability'; slugId = '7a8b9c0d1e2f'; status = 'Planned'; health = $null; priority = 0; ownerId = $null; leadTeamId = $null
                labelIds = @(); projectIds = @('project-mobile'); targetDate = $null; description = ''; content = ''; archivedAt = $null; subInitiatives = @()
            }
        }
        'initiative-old' {
            @{ name = 'Old goals'; slugId = '0f0e0d0c0b0a'; status = 'Completed'; health = $null; priority = 0; ownerId = $null; leadTeamId = $null
                labelIds = @(); projectIds = @(); targetDate = $null; description = ''; content = ''; archivedAt = '2026-01-01T00:00:00.000Z'; subInitiatives = @()
            }
        }
        default {
            @{ name = 'New initiative'; slugId = 'abcdef123456'; status = 'Planned'; health = $null; priority = 0; ownerId = $null; leadTeamId = $null
                labelIds = @(); projectIds = @(); targetDate = $null; description = ''; content = ''; archivedAt = $null; subInitiatives = @()
            }
        }
    }
    foreach ($key in $Change.Keys) { $values[$key] = $Change[$key] }

    $slug = ($values.name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    $labelNodes = @(foreach ($labelId in $values.labelIds) { $labels[$labelId] })
    $projectNodes = @(foreach ($projectId in $values.projectIds) { $projects[$projectId] })
    $node = [ordered]@{
        id               = $Id
        name             = $values.name
        slugId           = $values.slugId
        url              = "https://linear.app/acme/initiative/$slug-$($values.slugId)"
        description      = $values.description
        status           = $values.status
        health           = $values.health
        healthUpdatedAt  = if ($values.health) { '2026-10-08T09:00:00.000Z' } else { $null }
        priority         = $values.priority
        targetDate       = $values.targetDate
        startedAt        = $null
        completedAt      = $null
        archivedAt       = $values.archivedAt
        owner            = if ($values.ownerId) { $users[$values.ownerId] } else { $null }
        leadTeam         = if ($values.leadTeamId) { $teams[$values.leadTeamId] } else { $null }
        parentInitiative = $null
        labels           = @{ nodes = $labelNodes }
        projects         = @{ nodes = $projectNodes }
    }
    if ($Detail) {
        $node['content'] = $values.content
        $node['allLabels'] = @{ nodes = $labelNodes }
        $node['allProjects'] = @{ nodes = $projectNodes }
        $node['subInitiatives'] = @{ nodes = @(foreach ($sub in $values.subInitiatives) { @{ id = 'initiative-sub'; name = $sub } }) }
    }
    $node
}

function New-LinearTestInitiativeUpdateNode {
    param(
        [string] $Id = 'iupdate-1',
        [string] $Body = 'All good',
        [string] $Health = 'onTrack',
        [string] $InitiativeId = 'initiative-growth',
        [string] $CreatedAt = '2026-10-01T09:00:00.000Z'
    )
    [ordered]@{
        id         = $Id
        body       = $Body
        health     = $Health
        url        = "https://linear.app/acme/initiative/q1-growth-5f2c9a1b7e3d/updates#$Id"
        createdAt  = $CreatedAt
        editedAt   = $null
        user       = @{ id = 'user-ada'; name = 'Ada Lovelace' }
        initiative = @{ id = $InitiativeId; name = $(if ($InitiativeId -eq 'initiative-reliability') { 'Platform reliability' } else { 'Q1 growth' }) }
    }
}

function Get-LinearTestInitiativeResponse {
    # Serves the initiative, initiative-to-project and initiative update operations, or returns
    # $null for any other request.
    #
    # GetInitiative: the three fixture initiatives, by id or slug id; anything else does not exist.
    # Create/Update: the name 'reject' is rejected; unknown ids fail.
    # Links:         Website is in Q1 growth (link-web-growth), Mobile App in Platform
    #                reliability (link-mobile-reliability). Adding a project with an all-zero id
    #                fails.
    # Updates:       Q1 growth has iupdate-2 (AtRisk, newest) and iupdate-1 (OnTrack); Platform
    #                reliability has iupdate-r1. The update id 'missing' does not exist.
    param([Parameter(Mandatory)][hashtable] $Request)

    $query = $Request.query
    $variables = if ($Request.ContainsKey('variables')) { $Request.variables } else { @{} }
    $slugs = @{ '5f2c9a1b7e3d' = 'initiative-growth'; '7a8b9c0d1e2f' = 'initiative-reliability'; '0f0e0d0c0b0a' = 'initiative-old' }
    $known = @('initiative-growth', 'initiative-reliability', 'initiative-old')
    $links = @{
        'project-web'    = @(@{ id = 'link-web-growth'; initiative = @{ id = 'initiative-growth' } })
        'project-mobile' = @(@{ id = 'link-mobile-reliability'; initiative = @{ id = 'initiative-reliability' } })
    }
    $updates = [ordered]@{
        'iupdate-2'  = New-LinearTestInitiativeUpdateNode -Id 'iupdate-2' -Body "Slipping`nHiring delayed" -Health 'atRisk' -CreatedAt '2026-10-08T09:00:00.000Z'
        'iupdate-1'  = New-LinearTestInitiativeUpdateNode -Id 'iupdate-1' -Body 'All good' -Health 'onTrack' -CreatedAt '2026-10-01T09:00:00.000Z'
        'iupdate-r1' = New-LinearTestInitiativeUpdateNode -Id 'iupdate-r1' -Body 'Kickoff' -Health 'onTrack' -InitiativeId 'initiative-reliability' -CreatedAt '2026-09-20T09:00:00.000Z'
    }
    $rejected = New-LinearTestError -Message 'Argument Validation Error' -Code 'INPUT_ERROR'

    if ($query -match 'query GetInitiative\b') {
        $initiativeId = if ($slugs.ContainsKey($variables.id)) { $slugs[$variables.id] } else { $variables.id }
        if ($initiativeId -notin $known) {
            return New-LinearTestResponse -Data $null -Errors @(New-LinearTestError -Message 'Entity not found: Initiative' -Code 'INPUT_ERROR' -Path 'initiative')
        }
        return New-LinearTestResponse -Data @{ initiative = New-LinearTestInitiativeNode -Id $initiativeId -Detail }
    }
    if ($query -match 'mutation CreateInitiative\b') {
        $initiativeInput = $variables.input
        if ($initiativeInput['name'] -eq 'reject') { return New-LinearTestResponse -Data @{ initiativeCreate = $null } -Errors @($rejected) }
        return New-LinearTestResponse -Data @{ initiativeCreate = @{ success = $true; initiative = New-LinearTestInitiativeNode -Id 'initiative-new' -Change $initiativeInput } }
    }
    if ($query -match 'mutation UpdateInitiative\b') {
        $initiativeInput = $variables.input
        if ($variables.id -notin $known -or $initiativeInput['name'] -eq 'reject') {
            return New-LinearTestResponse -Data @{ initiativeUpdate = $null } -Errors @($rejected)
        }
        return New-LinearTestResponse -Data @{ initiativeUpdate = @{ success = $true; initiative = New-LinearTestInitiativeNode -Id $variables.id -Change $initiativeInput } }
    }
    if ($query -match 'mutation (Delete|Archive)Initiative\b') {
        $field = if ($query -match 'mutation DeleteInitiative') { 'initiativeDelete' } else { 'initiativeArchive' }
        if ($variables.id -notin $known) { return New-LinearTestResponse -Data @{ $field = $null } -Errors @($rejected) }
        return New-LinearTestResponse -Data @{ $field = @{ success = $true } }
    }

    if ($query -match 'query ListProjectInitiativeLinks') {
        if (-not $links.ContainsKey($variables.id)) {
            return New-LinearTestResponse -Data $null -Errors @(New-LinearTestError -Message 'Entity not found: Project' -Code 'INPUT_ERROR' -Path 'project')
        }
        return New-LinearTestResponse -Data @{ project = @{ initiativeToProjects = @{ nodes = $links[$variables.id] } } }
    }
    if ($query -match 'mutation CreateInitiativeToProject') {
        if ($variables.input.projectId -eq '00000000-0000-4000-8000-000000000000') {
            return New-LinearTestResponse -Data @{ initiativeToProjectCreate = $null } -Errors @($rejected)
        }
        return New-LinearTestResponse -Data @{ initiativeToProjectCreate = @{ success = $true } }
    }
    if ($query -match 'mutation DeleteInitiativeToProject') {
        if ($variables.id -notlike 'link-*') { return New-LinearTestResponse -Data @{ initiativeToProjectDelete = $null } -Errors @($rejected) }
        return New-LinearTestResponse -Data @{ initiativeToProjectDelete = @{ success = $true; entityId = $variables.id } }
    }

    if ($query -match 'query ListInitiativeUpdates') {
        $initiativeId = Get-LinearNestedTestValue -InputObject $variables -Path 'filter.initiative.id.eq'
        $nodes = @($updates.Values | Where-Object { -not $initiativeId -or $_.initiative.id -eq $initiativeId })
        return New-LinearTestResponse -Data @{ initiativeUpdates = New-LinearTestConnection -Nodes $nodes }
    }
    if ($query -match 'query GetInitiativeUpdate') {
        if (-not $updates.Contains($variables.id)) {
            return New-LinearTestResponse -Data $null -Errors @(New-LinearTestError -Message 'Entity not found: InitiativeUpdate' -Code 'INPUT_ERROR')
        }
        return New-LinearTestResponse -Data @{ initiativeUpdate = $updates[$variables.id] }
    }
    if ($query -match 'mutation CreateInitiativeUpdate') {
        $updateInput = $variables.input
        if ($updateInput['body'] -eq 'reject') { return New-LinearTestResponse -Data @{ initiativeUpdateCreate = $null } -Errors @($rejected) }
        $health = if ($updateInput.Contains('health')) { $updateInput['health'] } else { 'onTrack' }
        $node = New-LinearTestInitiativeUpdateNode -Id 'iupdate-new' -Body $updateInput['body'] -Health $health -InitiativeId $updateInput['initiativeId'] -CreatedAt '2026-10-17T09:00:00.000Z'
        return New-LinearTestResponse -Data @{ initiativeUpdateCreate = @{ success = $true; initiativeUpdate = $node } }
    }
    if ($query -match 'mutation UpdateInitiativeUpdate') {
        if (-not $updates.Contains($variables.id)) { return New-LinearTestResponse -Data @{ initiativeUpdateUpdate = $null } -Errors @($rejected) }
        $node = $updates[$variables.id]
        foreach ($key in $variables.input.Keys) { $node[$key] = $variables.input[$key] }
        $node['editedAt'] = '2026-10-17T10:00:00.000Z'
        return New-LinearTestResponse -Data @{ initiativeUpdateUpdate = @{ success = $true; initiativeUpdate = $node } }
    }
    if ($query -match 'mutation ArchiveInitiativeUpdate') {
        if (-not $updates.Contains($variables.id)) { return New-LinearTestResponse -Data @{ initiativeUpdateArchive = $null } -Errors @($rejected) }
        return New-LinearTestResponse -Data @{ initiativeUpdateArchive = @{ success = $true } }
    }
    $null
}
