function Get-LinearProjectCache {
    <#
    .SYNOPSIS
        Returns all non-archived projects, cached for a few minutes. Used for name resolution.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Project')]
    param(
        [switch] $Refresh
    )

    if ($Refresh -or $null -eq $script:LinearProjectCache -or [datetime]::UtcNow -ge $script:LinearProjectCacheExpires) {
        $script:LinearProjectCache = @(Get-LinearProjectList)
        $script:LinearProjectCacheExpires = [datetime]::UtcNow.Add($script:CacheLifetime)
    }
    $script:LinearProjectCache
}

function Get-LinearProjectList {
    <#
    .SYNOPSIS
        Fetches the workspace's projects, sorted by name. Archived projects are included only with -IncludeArchived.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Project')]
    param(
        [switch] $IncludeArchived
    )

    Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListProjects') -ConnectionPath 'projects' -Limit 0 `
        -Variables @{ includeArchived = [bool]$IncludeArchived } |
        ConvertTo-LinearProject |
        Sort-Object -Property Name
}

function Resolve-LinearProjectId {
    <#
    .SYNOPSIS
        Resolves a project id, URL, slug id (the hex suffix of its URL) or name to the project's id.
    .NOTES
        Throws an ErrorRecord (PSLinear.ProjectNotFound or PSLinear.AmbiguousProject) that callers
        rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Project
    )

    if (Test-LinearGuid -Value $Project) { return $Project }

    $slugId = ConvertFrom-LinearProjectUrl -Value $Project

    $match = @()
    foreach ($refresh in $false, $true) {
        $projects = @(Get-LinearProjectCache -Refresh:$refresh | Where-Object { $null -ne $_ })
        $match = @($projects | Where-Object { $_.SlugId -eq $slugId })
        if ($match.Count -eq 0) { $match = @($projects | Where-Object { $_.Name -eq $Project }) }
        if ($match.Count -gt 0) { break }
    }

    if ($match.Count -eq 1) { return $match[0].Id }
    if ($match.Count -gt 1) {
        $matchList = ($match | ForEach-Object { "$($_.Name) ($($_.Id))" }) -join ', '
        throw (New-LinearErrorRecord -Message "Project '$Project' is ambiguous. Use the project id instead. Matches: $matchList." `
                -ErrorId 'PSLinear.AmbiguousProject' -Category InvalidArgument -TargetObject $Project)
    }

    $available = Format-LinearValueList -Value (Get-LinearProjectCache | Where-Object { $null -ne $_ } | ForEach-Object Name)
    throw (New-LinearErrorRecord -Message "Project '$Project' was not found. Valid projects: $available." `
            -ErrorId 'PSLinear.ProjectNotFound' -Category ObjectNotFound -TargetObject $Project)
}

function Get-LinearProjectStatusCache {
    <#
    .SYNOPSIS
        Returns the workspace's project statuses in workflow order, cached for a few minutes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $Refresh
    )

    if ($Refresh -or $null -eq $script:LinearProjectStatusCache -or [datetime]::UtcNow -ge $script:LinearProjectStatusCacheExpires) {
        $script:LinearProjectStatusCache = @(Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListProjectStatuses') -ConnectionPath 'projectStatuses' -Limit 0 |
                ForEach-Object { [pscustomobject]@{ PSTypeName = 'PSLinear.ProjectStatus'; Id = $_.id; Name = $_.name; Type = [string]$_.type; Position = $_.position } } |
                Sort-Object -Property { $script:ProjectStatusTypeOrder[$_.Type] }, Position)
        $script:LinearProjectStatusCacheExpires = [datetime]::UtcNow.Add($script:CacheLifetime)
    }
    $script:LinearProjectStatusCache
}

function Resolve-LinearProjectStatusId {
    <#
    .SYNOPSIS
        Resolves a project status name (In Progress), type (started) or id to a status id.
    .NOTES
        A name match wins; a type picks the first status of that type. Throws an ErrorRecord
        (PSLinear.ProjectStatusNotFound) that callers rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Status
    )

    if (Test-LinearGuid -Value $Status) { return $Status }
    @(Find-LinearProjectStatus -Status $Status)[0].Id
}

function Find-LinearProjectStatus {
    <#
    .SYNOPSIS
        Returns the project statuses a value names: the status with that name, or else every
        status of that type (backlog, planned, started, paused, completed, canceled), in order.
    .NOTES
        Throws an ErrorRecord (PSLinear.ProjectStatusNotFound) that lists the valid values.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Status
    )

    $statuses = @()
    foreach ($refresh in $false, $true) {
        $statuses = @(Get-LinearProjectStatusCache -Refresh:$refresh | Where-Object { $null -ne $_ })
        $match = @($statuses | Where-Object Name -EQ $Status)
        if ($match.Count -eq 0) { $match = @($statuses | Where-Object Type -EQ $Status) }
        if ($match.Count -gt 0) {
            foreach ($item in $match) { $item }
            return
        }
    }

    $names = Format-LinearValueList -Value ($statuses | ForEach-Object Name)
    $types = ($statuses | ForEach-Object Type | Select-Object -Unique) -join ', '
    throw (New-LinearErrorRecord -Message "Project status '$Status' was not found. Valid statuses: $names; status types: $types." `
            -ErrorId 'PSLinear.ProjectStatusNotFound' -Category ObjectNotFound -TargetObject $Status)
}

function Get-LinearProjectLabelCache {
    <#
    .SYNOPSIS
        Returns the project labels that can be applied (no groups, no retired labels), cached for a few minutes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $Refresh
    )

    if ($Refresh -or $null -eq $script:LinearProjectLabelCache -or [datetime]::UtcNow -ge $script:LinearProjectLabelCacheExpires) {
        $script:LinearProjectLabelCache = @(Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListProjectLabels') -ConnectionPath 'projectLabels' -Limit 0 |
                Where-Object { $null -ne $_ -and -not $_.isGroup -and $null -eq (Get-LinearNestedValue -InputObject $_ -Name 'retiredAt') } |
                ForEach-Object {
                    [pscustomobject]@{
                        PSTypeName = 'PSLinear.ProjectLabel'
                        Id         = $_.id
                        Name       = $_.name
                        Group      = Get-LinearNestedValue -InputObject $_ -Name 'parent.name'
                        Team       = Get-LinearNestedValue -InputObject $_ -Name 'team.key'
                    }
                } |
                Sort-Object -Property Name, Id)
        $script:LinearProjectLabelCacheExpires = [datetime]::UtcNow.Add($script:CacheLifetime)
    }
    $script:LinearProjectLabelCache
}

function Resolve-LinearProjectLabelId {
    <#
    .SYNOPSIS
        Resolves project label names or ids to label ids.
    .NOTES
        Throws an ErrorRecord (PSLinear.LabelNotFound or PSLinear.AmbiguousLabel) that callers
        rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Label
    )

    Resolve-LinearListedLabelId -Label $Label -CacheCommand 'Get-LinearProjectLabelCache' -Noun 'Project label'
}

function Reset-LinearProjectCache {
    <#
    .SYNOPSIS
        Forgets the cached projects, so name lookups see a project that was just created, renamed or removed.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Clears an in-memory cache only.')]
    [CmdletBinding()]
    param()

    $script:LinearProjectCache = $null
    $script:LinearProjectCacheExpires = [datetime]::MinValue
}

function ConvertFrom-LinearProjectUrl {
    <#
    .SYNOPSIS
        Returns the slug id of a project URL, or the value unchanged when it is not a project URL.
    .EXAMPLE
        ConvertFrom-LinearProjectUrl -Value 'https://linear.app/acme/project/mobile-launch-272f50ef9250'
        # 272f50ef9250
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    if ($Value -match '^https?://linear\.app/[^/]+/project/(?:[^/?#]*-)?([0-9a-f]+)(?:[/?#]|$)') { return $Matches[1] }
    $Value
}

function Get-LinearProjectTarget {
    <#
    .SYNOPSIS
        Describes the projects a write command acts on, without sending a request.
    .DESCRIPTION
        Returns [pscustomobject]@{ Id; Reference; Name } per project. Id is set for piped
        PSLinear.Project objects; a project given as text keeps it in Reference until the
        caller resolves it with Resolve-LinearProjectId after ShouldProcess. Name is for messages.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $Project,

        [object[]] $InputObject
    )

    foreach ($value in $Project) {
        [pscustomobject]@{ Id = $null; Reference = $value; Name = "project '$value'" }
    }
    foreach ($object in $InputObject) {
        if ($null -eq $object) { continue }
        $projectName = Get-LinearNestedValue -InputObject $object -Name 'Name'
        [pscustomobject]@{ Id = $object.Id; Reference = $object.Id; Name = "project '$(if ($projectName) { $projectName } else { $object.Id })'" }
    }
}

function Get-LinearProjectDetail {
    <#
    .SYNOPSIS
        Fetches one project with its content, every team, label and member, and its initiatives.
    .DESCRIPTION
        Returns [pscustomobject]@{ Project; Errors }: the raw project node, or $null with the
        GraphQL errors when the project does not exist. Accepts an id or a slug id.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Id
    )

    $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'GetProject') -Variables @{ id = $Id } -IncludeErrors
    [pscustomobject]@{
        Project = Get-LinearNestedValue -InputObject $result.Data -Name 'project'
        Errors  = $result.Errors
    }
}
