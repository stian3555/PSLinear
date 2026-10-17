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
        [string] $Id = 'team-eng'
    )
    [ordered]@{
        id          = $Id
        key         = $Key
        name        = $Name
        description = $null
        visibility  = 'public'
        createdAt   = '2025-01-01T00:00:00.000Z'
        archivedAt  = $null
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
    # Teams:    ENG (team-eng), OPS (team-ops)
    # States:   ENG Backlog, Todo, In Progress, Done, Canceled; OPS Todo, Doing, Done
    # Labels:   workspace Bug, Feature, group Area with Frontend, retired Old;
    #           ENG Backend; OPS Incident and a second Frontend
    # Users:    Ada Lovelace (the viewer), Grace Hopper, and two users named Alex Smith
    # Projects: Website, Mobile App
    param([Parameter(Mandatory)][hashtable] $Request)

    $query = $Request.query
    $variables = if ($Request.ContainsKey('variables')) { $Request.variables } else { @{} }

    if ($query -match 'query ListTeams') {
        return New-LinearTestResponse -Data @{
            teams = New-LinearTestConnection -Nodes @(
                (New-LinearTestTeamNode -Key 'ENG' -Name 'Engineering' -Id 'team-eng'),
                (New-LinearTestTeamNode -Key 'OPS' -Name 'Operations' -Id 'team-ops')
            )
        }
    }

    if ($query -match 'query ListWorkflowStates') {
        $teamId = $variables.filter.team.id.eq
        # Deliberately not in workflow order, so sorting is tested.
        $states = switch ($teamId) {
            'team-eng' {
                @(
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
        $teamId = $variables.filter.or[1].team.id.eq
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
            if ($null -ne $label.team -and $label.team.id -ne $teamId) { continue }
            $label['color'] = '#000000'
            $label['description'] = $null
            $label
        }
        return New-LinearTestResponse -Data @{ issueLabels = New-LinearTestConnection -Nodes @($nodes) }
    }

    if ($query -match 'query ListUsers') {
        return New-LinearTestResponse -Data @{
            users = New-LinearTestConnection -Nodes @(
                (New-LinearTestUserNode -Id 'user-ada' -Name 'Ada Lovelace' -DisplayName 'ada' -Email 'ada@example.com'),
                (New-LinearTestUserNode -Id 'user-grace' -Name 'Grace Hopper' -DisplayName 'grace' -Email 'grace@example.com'),
                (New-LinearTestUserNode -Id 'user-alex-1' -Name 'Alex Smith' -DisplayName 'alex1' -Email 'alex.one@example.com'),
                (New-LinearTestUserNode -Id 'user-alex-2' -Name 'Alex Smith' -DisplayName 'alex2' -Email 'alex.two@example.com')
            )
        }
    }

    if ($query -match 'query Viewer') {
        return New-LinearTestResponse -Data @{
            viewer       = New-LinearTestUserNode -Id 'user-ada' -Name 'Ada Lovelace' -DisplayName 'ada' -Email 'ada@example.com'
            organization = @{ id = 'org-acme'; name = 'Acme'; urlKey = 'acme' }
        }
    }

    if ($query -match 'query ListProjects') {
        return New-LinearTestResponse -Data @{
            projects = New-LinearTestConnection -Nodes @(
                @{ id = 'project-web'; name = 'Website'; url = 'https://linear.app/acme/project/website'; status = @{ name = 'In Progress' } }
                @{ id = 'project-mobile'; name = 'Mobile App'; url = 'https://linear.app/acme/project/mobile-app'; status = @{ name = 'Planned' } }
            )
        }
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

function Get-RequestOperation {
    # Returns the operation name of the GraphQL document passed to Send-LinearHttpRequest, such as 'CreateIssue'.
    param([Parameter(Mandatory)][string] $Body)
    $query = (Get-RequestBody -Body $Body).query
    if ($query -match '^\s*(query|mutation)\s+([_A-Za-z]\w*)') { return $Matches[2] }
    $null
}
