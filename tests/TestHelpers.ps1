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
