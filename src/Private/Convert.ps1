function ConvertTo-LinearIssue {
    <#
    .SYNOPSIS
        Flattens an Issue node (IssueFields fragment) into a PSLinear.Issue object.
    .NOTES
        Names are flattened for filtering and display (State, Assignee, Team), while the
        matching ids (StateId, AssigneeId, TeamId) are kept for piping into other commands.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Issue')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        $node = $InputObject

        [pscustomobject]@{
            PSTypeName    = 'PSLinear.Issue'
            Id            = $node.id
            Identifier    = $node.identifier
            Number        = $node.number
            Title         = $node.title
            State         = Get-LinearNestedValue -InputObject $node.state -Name 'name'
            StateType     = Get-LinearNestedValue -InputObject $node.state -Name 'type'
            Priority      = $node.priority
            PriorityLabel = $node.priorityLabel
            Estimate      = $node.estimate
            Assignee      = Get-LinearNestedValue -InputObject $node.assignee -Name 'name'
            AssigneeEmail = Get-LinearNestedValue -InputObject $node.assignee -Name 'email'
            Team          = Get-LinearNestedValue -InputObject $node.team -Name 'key'
            Project       = Get-LinearNestedValue -InputObject $node.project -Name 'name'
            Cycle         = Get-LinearNestedValue -InputObject $node.cycle -Name 'number'
            Labels        = [string[]]@(foreach ($label in @(Get-LinearNestedValue -InputObject $node -Name 'labels.nodes')) { Get-LinearNestedValue -InputObject $label -Name 'name' })
            Parent        = Get-LinearNestedValue -InputObject $node.parent -Name 'identifier'
            Creator       = Get-LinearNestedValue -InputObject $node.creator -Name 'name'
            DueDate       = $node.dueDate
            Url           = $node.url
            BranchName    = $node.branchName
            Description   = $node.description
            CreatedAt     = $node.createdAt
            UpdatedAt     = $node.updatedAt
            StartedAt     = $node.startedAt
            CompletedAt   = $node.completedAt
            CanceledAt    = $node.canceledAt
            ArchivedAt    = $node.archivedAt
            StateId       = Get-LinearNestedValue -InputObject $node.state -Name 'id'
            AssigneeId    = Get-LinearNestedValue -InputObject $node.assignee -Name 'id'
            TeamId        = Get-LinearNestedValue -InputObject $node.team -Name 'id'
            ProjectId     = Get-LinearNestedValue -InputObject $node.project -Name 'id'
            CycleId       = Get-LinearNestedValue -InputObject $node.cycle -Name 'id'
        }
    }
}

function ConvertTo-LinearTeam {
    [CmdletBinding()]
    [OutputType('PSLinear.Team')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        [pscustomobject]@{
            PSTypeName  = 'PSLinear.Team'
            Id          = $InputObject.id
            Key         = $InputObject.key
            Name        = $InputObject.name
            Description = $InputObject.description
            Visibility  = $InputObject.visibility
            CreatedAt   = $InputObject.createdAt
            ArchivedAt  = $InputObject.archivedAt
        }
    }
}

function ConvertTo-LinearUser {
    [CmdletBinding()]
    [OutputType('PSLinear.User')]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject,

        [AllowNull()]
        [object] $Organization
    )

    if ($null -eq $InputObject) { return }
    [pscustomobject]@{
        PSTypeName   = 'PSLinear.User'
        Id           = $InputObject.id
        Name         = $InputObject.name
        DisplayName  = $InputObject.displayName
        Email        = $InputObject.email
        Admin        = $InputObject.admin
        Active       = $InputObject.active
        Organization = Get-LinearNestedValue -InputObject $Organization -Name 'name'
    }
}

function ConvertTo-LinearWorkflowState {
    [CmdletBinding()]
    [OutputType('PSLinear.WorkflowState')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        [pscustomobject]@{
            PSTypeName = 'PSLinear.WorkflowState'
            Id         = $InputObject.id
            Name       = $InputObject.name
            Type       = $InputObject.type
            Position   = $InputObject.position
            Color      = Get-LinearNestedValue -InputObject $InputObject -Name 'color'
            Team       = Get-LinearNestedValue -InputObject $InputObject -Name 'team.key'
            TeamId     = Get-LinearNestedValue -InputObject $InputObject -Name 'team.id'
        }
    }
}

function ConvertTo-LinearLabel {
    <#
    .SYNOPSIS
        Flattens an IssueLabel node into a PSLinear.Label object. Team is $null for workspace labels.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Label')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        [pscustomobject]@{
            PSTypeName  = 'PSLinear.Label'
            Id          = $InputObject.id
            Name        = $InputObject.name
            Group       = Get-LinearNestedValue -InputObject $InputObject -Name 'parent.name'
            Team        = Get-LinearNestedValue -InputObject $InputObject -Name 'team.key'
            Color       = Get-LinearNestedValue -InputObject $InputObject -Name 'color'
            Description = Get-LinearNestedValue -InputObject $InputObject -Name 'description'
            IsGroup     = [bool](Get-LinearNestedValue -InputObject $InputObject -Name 'isGroup')
            RetiredAt   = Get-LinearNestedValue -InputObject $InputObject -Name 'retiredAt'
            TeamId      = Get-LinearNestedValue -InputObject $InputObject -Name 'team.id'
        }
    }
}

function ConvertTo-LinearProject {
    [CmdletBinding()]
    [OutputType('PSLinear.Project')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        [pscustomobject]@{
            PSTypeName = 'PSLinear.Project'
            Id         = $InputObject.id
            Name       = $InputObject.name
            Status     = Get-LinearNestedValue -InputObject $InputObject -Name 'status.name'
            Url        = Get-LinearNestedValue -InputObject $InputObject -Name 'url'
        }
    }
}

function Test-LinearGuid {
    <#
    .SYNOPSIS
        Returns $true when the value is a UUID, which Linear accepts as an id everywhere.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [string] $Value
    )

    $parsedGuid = [guid]::Empty
    [guid]::TryParse($Value, [ref]$parsedGuid)
}

function Get-LinearNestedValue {
    <#
    .SYNOPSIS
        Strict-mode-safe property read. Name may be a dot-separated path ('organization.name');
        returns $null as soon as any step is missing or $null.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $current = $InputObject
    foreach ($segment in $Name.Split('.')) {
        if ($null -eq $current) { return $null }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $null }
        $current = $property.Value
    }
    $current
}
