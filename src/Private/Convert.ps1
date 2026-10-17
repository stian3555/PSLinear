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
            Milestone     = Get-LinearNestedValue -InputObject $node -Name 'projectMilestone.name'
            Delegate      = Get-LinearNestedValue -InputObject $node -Name 'delegate.name'
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
            MilestoneId   = Get-LinearNestedValue -InputObject $node -Name 'projectMilestone.id'
            DelegateId    = Get-LinearNestedValue -InputObject $node -Name 'delegate.id'
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
            PSTypeName        = 'PSLinear.Team'
            Id                = $InputObject.id
            Key               = $InputObject.key
            Name              = $InputObject.name
            Description       = $InputObject.description
            Visibility        = $InputObject.visibility
            Parent            = Get-LinearNestedValue -InputObject $InputObject -Name 'parent.key'
            EstimationType    = Get-LinearNestedValue -InputObject $InputObject -Name 'issueEstimationType'
            InheritEstimation = [bool](Get-LinearNestedValue -InputObject $InputObject -Name 'inheritIssueEstimation')
            CreatedAt         = $InputObject.createdAt
            ArchivedAt        = $InputObject.archivedAt
            ParentId          = Get-LinearNestedValue -InputObject $InputObject -Name 'parent.id'
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
            PSTypeName      = 'PSLinear.Label'
            Id              = $InputObject.id
            Name            = $InputObject.name
            Group           = Get-LinearNestedValue -InputObject $InputObject -Name 'parent.name'
            Team            = Get-LinearNestedValue -InputObject $InputObject -Name 'team.key'
            Color           = Get-LinearNestedValue -InputObject $InputObject -Name 'color'
            Description     = Get-LinearNestedValue -InputObject $InputObject -Name 'description'
            IsGroup         = [bool](Get-LinearNestedValue -InputObject $InputObject -Name 'isGroup')
            RetiredAt       = Get-LinearNestedValue -InputObject $InputObject -Name 'retiredAt'
            TeamId          = Get-LinearNestedValue -InputObject $InputObject -Name 'team.id'
            InheritedFromId = Get-LinearNestedValue -InputObject $InputObject -Name 'inheritedFrom.id'
        }
    }
}

function ConvertTo-LinearProject {
    <#
    .SYNOPSIS
        Flattens a Project node (ProjectFields fragment) into a PSLinear.Project object.
    .NOTES
        Teams and Labels hold team keys and label names, with the ids in TeamIds and LabelIds.
        Content, Members and Initiatives are only filled for a single project fetched with
        GetProject; they are $null in lists.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Project')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        $node = $InputObject
        # GetProject fetches up to 100 teams and labels under these aliases.
        $teams = @(Get-LinearNestedValue -InputObject $node -Name 'allTeams.nodes')
        if ($null -eq (Get-LinearNestedValue -InputObject $node -Name 'allTeams')) { $teams = @(Get-LinearNestedValue -InputObject $node -Name 'teams.nodes') }
        $labels = @(Get-LinearNestedValue -InputObject $node -Name 'allLabels.nodes')
        if ($null -eq (Get-LinearNestedValue -InputObject $node -Name 'allLabels')) { $labels = @(Get-LinearNestedValue -InputObject $node -Name 'labels.nodes') }
        $teams = @($teams | Where-Object { $null -ne $_ })
        $labels = @($labels | Where-Object { $null -ne $_ })
        $health = [string](Get-LinearNestedValue -InputObject $node -Name 'health')
        # Assigned directly rather than through an if expression, which would unroll an empty
        # list to $null and a single name to a string.
        $memberNames = $null
        $memberIds = $null
        $initiativeNames = $null
        $members = Get-LinearNestedValue -InputObject $node -Name 'members'
        if ($null -ne $members) {
            $memberNodes = @(Get-LinearNestedValue -InputObject $members -Name 'nodes' | Where-Object { $null -ne $_ })
            $memberNames = [string[]]@($memberNodes | ForEach-Object { $_.name })
            $memberIds = [string[]]@($memberNodes | ForEach-Object { $_.id })
        }
        $initiatives = Get-LinearNestedValue -InputObject $node -Name 'initiatives'
        if ($null -ne $initiatives) {
            $initiativeNames = [string[]]@(Get-LinearNestedValue -InputObject $initiatives -Name 'nodes' | Where-Object { $null -ne $_ } | ForEach-Object { $_.name })
        }

        [pscustomobject]@{
            PSTypeName    = 'PSLinear.Project'
            Id            = $node.id
            Name          = $node.name
            Status        = Get-LinearNestedValue -InputObject $node -Name 'status.name'
            StatusType    = Get-LinearNestedValue -InputObject $node -Name 'status.type'
            Health        = if ($health) { $health.Substring(0, 1).ToUpperInvariant() + $health.Substring(1) } else { $null }
            Priority      = Get-LinearNestedValue -InputObject $node -Name 'priority'
            PriorityLabel = Get-LinearNestedValue -InputObject $node -Name 'priorityLabel'
            Lead          = Get-LinearNestedValue -InputObject $node -Name 'lead.name'
            Teams         = [string[]]@($teams | ForEach-Object { Get-LinearNestedValue -InputObject $_ -Name 'key' })
            Labels        = [string[]]@($labels | ForEach-Object { Get-LinearNestedValue -InputObject $_ -Name 'name' })
            Progress      = Get-LinearNestedValue -InputObject $node -Name 'progress'
            StartDate     = Get-LinearNestedValue -InputObject $node -Name 'startDate'
            TargetDate    = Get-LinearNestedValue -InputObject $node -Name 'targetDate'
            StartedAt     = Get-LinearNestedValue -InputObject $node -Name 'startedAt'
            CompletedAt   = Get-LinearNestedValue -InputObject $node -Name 'completedAt'
            CanceledAt    = Get-LinearNestedValue -InputObject $node -Name 'canceledAt'
            Description   = Get-LinearNestedValue -InputObject $node -Name 'description'
            Content       = Get-LinearNestedValue -InputObject $node -Name 'content'
            Members       = $memberNames
            Initiatives   = $initiativeNames
            Url           = Get-LinearNestedValue -InputObject $node -Name 'url'
            ArchivedAt    = Get-LinearNestedValue -InputObject $node -Name 'archivedAt'
            SlugId        = Get-LinearNestedValue -InputObject $node -Name 'slugId'
            LeadId        = Get-LinearNestedValue -InputObject $node -Name 'lead.id'
            StatusId      = Get-LinearNestedValue -InputObject $node -Name 'status.id'
            TeamIds       = [string[]]@($teams | ForEach-Object { Get-LinearNestedValue -InputObject $_ -Name 'id' })
            LabelIds      = [string[]]@($labels | ForEach-Object { Get-LinearNestedValue -InputObject $_ -Name 'id' })
            MemberIds     = $memberIds
        }
    }
}

function ConvertTo-LinearProjectUpdate {
    <#
    .SYNOPSIS
        Flattens a ProjectUpdate node into a PSLinear.ProjectUpdate object. Health is OnTrack, AtRisk or OffTrack.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.ProjectUpdate')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        $health = [string](Get-LinearNestedValue -InputObject $InputObject -Name 'health')
        [pscustomobject]@{
            PSTypeName = 'PSLinear.ProjectUpdate'
            Id         = $InputObject.id
            Project    = Get-LinearNestedValue -InputObject $InputObject -Name 'project.name'
            Health     = if ($health) { $health.Substring(0, 1).ToUpperInvariant() + $health.Substring(1) } else { $null }
            Author     = Get-LinearNestedValue -InputObject $InputObject -Name 'user.name'
            Body       = Get-LinearNestedValue -InputObject $InputObject -Name 'body'
            CreatedAt  = Get-LinearNestedValue -InputObject $InputObject -Name 'createdAt'
            EditedAt   = Get-LinearNestedValue -InputObject $InputObject -Name 'editedAt'
            Url        = Get-LinearNestedValue -InputObject $InputObject -Name 'url'
            ProjectId  = Get-LinearNestedValue -InputObject $InputObject -Name 'project.id'
            AuthorId   = Get-LinearNestedValue -InputObject $InputObject -Name 'user.id'
        }
    }
}

function ConvertTo-LinearComment {
    <#
    .SYNOPSIS
        Flattens a Comment node (CommentFields fragment) into a PSLinear.Comment object.
    .NOTES
        Author is the user, or the integration (bot) or external user that wrote the comment.
        Target names what the comment is on: an issue identifier or a project name. ThreadId is
        the id of the first comment in the thread (the comment itself when it is not a reply).
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Comment')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        $node = $InputObject
        $author = @(
            (Get-LinearNestedValue -InputObject $node -Name 'user.name'),
            (Get-LinearNestedValue -InputObject $node -Name 'botActor.name'),
            (Get-LinearNestedValue -InputObject $node -Name 'externalUser.name')
        ) | Where-Object { $_ } | Select-Object -First 1
        $target = @(
            (Get-LinearNestedValue -InputObject $node -Name 'issue.identifier'),
            (Get-LinearNestedValue -InputObject $node -Name 'project.name')
        ) | Where-Object { $_ } | Select-Object -First 1
        $parentId = Get-LinearNestedValue -InputObject $node -Name 'parentId'

        [pscustomobject]@{
            PSTypeName = 'PSLinear.Comment'
            Id         = $node.id
            Target     = $target
            Author     = $author
            Body       = Get-LinearNestedValue -InputObject $node -Name 'body'
            CreatedAt  = Get-LinearNestedValue -InputObject $node -Name 'createdAt'
            EditedAt   = Get-LinearNestedValue -InputObject $node -Name 'editedAt'
            IsReply    = -not [string]::IsNullOrEmpty($parentId)
            ThreadId   = if ($parentId) { $parentId } else { $node.id }
            Resolved   = $null -ne (Get-LinearNestedValue -InputObject $node -Name 'resolvedAt')
            ResolvedAt = Get-LinearNestedValue -InputObject $node -Name 'resolvedAt'
            ResolvedBy = Get-LinearNestedValue -InputObject $node -Name 'resolvingUser.name'
            QuotedText = Get-LinearNestedValue -InputObject $node -Name 'quotedText'
            Url        = Get-LinearNestedValue -InputObject $node -Name 'url'
            ParentId   = $parentId
            AuthorId   = Get-LinearNestedValue -InputObject $node -Name 'user.id'
            IssueId    = Get-LinearNestedValue -InputObject $node -Name 'issue.id'
            ProjectId  = Get-LinearNestedValue -InputObject $node -Name 'project.id'
        }
    }
}

function ConvertTo-LinearAttachment {
    <#
    .SYNOPSIS
        Flattens an Attachment node (AttachmentFields fragment) into a PSLinear.Attachment object.
    .NOTES
        Source is the integration that created a link (github, slack, ...), or null for uploads
        and plain links. Metadata is an ordered hashtable: values you set, or what an integration
        stores (which can be nested).
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Attachment')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        # Linear reports uploads and plain links as source 'unknown'.
        $source = Get-LinearNestedValue -InputObject $InputObject -Name 'sourceType'
        if ($source -eq 'unknown') { $source = $null }
        $metadata = [ordered]@{}
        $rawMetadata = Get-LinearNestedValue -InputObject $InputObject -Name 'metadata'
        if ($null -ne $rawMetadata) {
            foreach ($property in $rawMetadata.PSObject.Properties) { $metadata[$property.Name] = $property.Value }
        }
        [pscustomobject]@{
            PSTypeName = 'PSLinear.Attachment'
            Id         = $InputObject.id
            Issue      = Get-LinearNestedValue -InputObject $InputObject -Name 'issue.identifier'
            Title      = Get-LinearNestedValue -InputObject $InputObject -Name 'title'
            Subtitle   = Get-LinearNestedValue -InputObject $InputObject -Name 'subtitle'
            Url        = Get-LinearNestedValue -InputObject $InputObject -Name 'url'
            Source     = $source
            Metadata   = $metadata
            Creator    = Get-LinearNestedValue -InputObject $InputObject -Name 'creator.name'
            CreatedAt  = Get-LinearNestedValue -InputObject $InputObject -Name 'createdAt'
            UpdatedAt  = Get-LinearNestedValue -InputObject $InputObject -Name 'updatedAt'
            IssueId    = Get-LinearNestedValue -InputObject $InputObject -Name 'issue.id'
            CreatorId  = Get-LinearNestedValue -InputObject $InputObject -Name 'creator.id'
        }
    }
}

function ConvertTo-LinearIssueRelation {
    <#
    .SYNOPSIS
        Flattens an IssueRelation node into a PSLinear.IssueRelation object, seen from one of its issues.
    .DESCRIPTION
        Linear stores a relation from 'issue' to 'relatedIssue'. Without -Inverse the object is
        seen from 'issue'; with -Inverse it is seen from 'relatedIssue', so the type reads the
        other way: blocks becomes BlockedBy and duplicate becomes DuplicatedBy.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.IssueRelation')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject,

        [switch] $Inverse
    )

    process {
        if ($null -eq $InputObject) { return }
        $apiType = [string]$InputObject.type
        $ownPath, $otherPath = if ($Inverse) { 'relatedIssue', 'issue' } else { 'issue', 'relatedIssue' }
        $type = switch ($apiType) {
            'blocks' { if ($Inverse) { 'BlockedBy' } else { 'Blocks' } }
            'duplicate' { if ($Inverse) { 'DuplicatedBy' } else { 'DuplicateOf' } }
            'related' { 'Related' }
            'similar' { 'Similar' }
            default { $apiType }
        }

        [pscustomobject]@{
            PSTypeName     = 'PSLinear.IssueRelation'
            Id             = $InputObject.id
            Issue          = Get-LinearNestedValue -InputObject $InputObject -Name "$ownPath.identifier"
            Type           = $type
            RelatedIssue   = Get-LinearNestedValue -InputObject $InputObject -Name "$otherPath.identifier"
            RelatedTitle   = Get-LinearNestedValue -InputObject $InputObject -Name "$otherPath.title"
            RelatedState   = Get-LinearNestedValue -InputObject $InputObject -Name "$otherPath.state.name"
            CreatedAt      = Get-LinearNestedValue -InputObject $InputObject -Name 'createdAt'
            ApiType        = $apiType
            IssueId        = Get-LinearNestedValue -InputObject $InputObject -Name "$ownPath.id"
            RelatedIssueId = Get-LinearNestedValue -InputObject $InputObject -Name "$otherPath.id"
        }
    }
}

function ConvertTo-LinearMilestone {
    <#
    .SYNOPSIS
        Flattens a ProjectMilestone node into a PSLinear.Milestone object. Status is Unstarted, Next, Overdue or Done.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Milestone')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        $status = [string](Get-LinearNestedValue -InputObject $InputObject -Name 'status')
        [pscustomobject]@{
            PSTypeName  = 'PSLinear.Milestone'
            Id          = $InputObject.id
            Project     = Get-LinearNestedValue -InputObject $InputObject -Name 'project.name'
            Name        = $InputObject.name
            Status      = if ($status) { $status.Substring(0, 1).ToUpperInvariant() + $status.Substring(1) } else { $null }
            TargetDate  = Get-LinearNestedValue -InputObject $InputObject -Name 'targetDate'
            Progress    = Get-LinearNestedValue -InputObject $InputObject -Name 'progress'
            Description = Get-LinearNestedValue -InputObject $InputObject -Name 'description'
            SortOrder   = Get-LinearNestedValue -InputObject $InputObject -Name 'sortOrder'
            ProjectId   = Get-LinearNestedValue -InputObject $InputObject -Name 'project.id'
        }
    }
}

function ConvertTo-LinearTemplate {
    <#
    .SYNOPSIS
        Flattens a Template node into a PSLinear.Template object. Team is $null for workspace templates.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Template')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        [pscustomobject]@{
            PSTypeName    = 'PSLinear.Template'
            Id            = $InputObject.id
            Name          = $InputObject.name
            Type          = Get-LinearNestedValue -InputObject $InputObject -Name 'type'
            Team          = Get-LinearNestedValue -InputObject $InputObject -Name 'team.key'
            Description   = Get-LinearNestedValue -InputObject $InputObject -Name 'description'
            Content       = Get-LinearNestedValue -InputObject $InputObject -Name 'content'
            LastAppliedAt = Get-LinearNestedValue -InputObject $InputObject -Name 'lastAppliedAt'
            TeamId        = Get-LinearNestedValue -InputObject $InputObject -Name 'team.id'
        }
    }
}

function ConvertTo-LinearCycle {
    <#
    .SYNOPSIS
        Flattens a Cycle node into a PSLinear.Cycle object. Status is Active, Next, Previous, Past or Future.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Cycle')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        $status = if (Get-LinearNestedValue -InputObject $InputObject -Name 'isActive') { 'Active' }
        elseif (Get-LinearNestedValue -InputObject $InputObject -Name 'isNext') { 'Next' }
        elseif (Get-LinearNestedValue -InputObject $InputObject -Name 'isPrevious') { 'Previous' }
        elseif (Get-LinearNestedValue -InputObject $InputObject -Name 'isPast') { 'Past' }
        elseif (Get-LinearNestedValue -InputObject $InputObject -Name 'isFuture') { 'Future' }

        [pscustomobject]@{
            PSTypeName  = 'PSLinear.Cycle'
            Id          = $InputObject.id
            Team        = Get-LinearNestedValue -InputObject $InputObject -Name 'team.key'
            Number      = [int]$InputObject.number
            Name        = Get-LinearNestedValue -InputObject $InputObject -Name 'name'
            Status      = $status
            StartsAt    = Get-LinearNestedValue -InputObject $InputObject -Name 'startsAt'
            EndsAt      = Get-LinearNestedValue -InputObject $InputObject -Name 'endsAt'
            Progress    = Get-LinearNestedValue -InputObject $InputObject -Name 'progress'
            CompletedAt = Get-LinearNestedValue -InputObject $InputObject -Name 'completedAt'
            TeamId      = Get-LinearNestedValue -InputObject $InputObject -Name 'team.id'
        }
    }
}

function Select-LinearObjectByName {
    <#
    .SYNOPSIS
        Filters objects whose properties match any of the given wildcard patterns.
    .DESCRIPTION
        Returns @{ Selected; Missing }: the matching objects (each once, in pattern order) and
        the patterns without wildcards that matched nothing, so callers can report them.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $InputObject,

        [Parameter(Mandatory)]
        [string[]] $Name,

        [Parameter(Mandatory)]
        [string[]] $Property
    )

    $selected = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($pattern in $Name) {
        $found = @($InputObject | Where-Object {
                $item = $_
                $null -ne $item -and @($Property | Where-Object {
                        $value = Get-LinearNestedValue -InputObject $item -Name $_
                        $null -ne $value -and $value -like $pattern
                    }).Count -gt 0
            })
        if ($found.Count -eq 0 -and -not [WildcardPattern]::ContainsWildcardCharacters($pattern)) {
            $missing.Add($pattern)
        }
        foreach ($item in $found) {
            if (-not $selected.Contains($item)) { $selected.Add($item) }
        }
    }
    [pscustomobject]@{ Selected = $selected.ToArray(); Missing = $missing.ToArray() }
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
