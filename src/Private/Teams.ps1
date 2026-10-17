function Get-LinearTeamCache {
    <#
    .SYNOPSIS
        Returns all non-archived teams, cached for a few minutes. Used for name resolution and tab completion.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Team')]
    param(
        [switch] $Refresh
    )

    if ($Refresh -or $null -eq $script:LinearTeamCache -or [datetime]::UtcNow -ge $script:LinearTeamCacheExpires) {
        $query = Get-LinearGraphQLDocument -Name 'ListTeams'
        $script:LinearTeamCache = @(Invoke-LinearPagedRequest -Query $query -ConnectionPath 'teams' -Limit 0 -Variables @{ includeArchived = $false } |
                ConvertTo-LinearTeam)
        $script:LinearTeamCacheExpires = [datetime]::UtcNow.Add($script:CacheLifetime)
    }
    $script:LinearTeamCache
}

function Resolve-LinearTeamId {
    <#
    .SYNOPSIS
        Resolves a team id, key (ENG) or name (Engineering) to the team's id.
    .NOTES
        Throws an ErrorRecord (PSLinear.TeamNotFound or PSLinear.AmbiguousTeam) that callers rethrow
        with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Team
    )

    if (Test-LinearGuid -Value $Team) { return $Team }

    foreach ($refresh in $false, $true) {
        $match = @(Get-LinearTeamCache -Refresh:$refresh | Where-Object { $null -ne $_ -and ($_.Key -eq $Team -or $_.Name -eq $Team) })
        if ($match.Count -eq 1) { return $match[0].Id }
        if ($match.Count -gt 1) {
            $matchList = ($match | ForEach-Object { "$($_.Key) ($($_.Name))" }) -join ', '
            throw (New-LinearErrorRecord -Message "Team '$Team' is ambiguous. Use the team key or id instead. Matches: $matchList." `
                    -ErrorId 'PSLinear.AmbiguousTeam' -Category InvalidArgument -TargetObject $Team)
        }
    }

    $available = Format-LinearValueList -Value (Get-LinearTeamCache | Where-Object { $null -ne $_ } | ForEach-Object Key)
    throw (New-LinearErrorRecord -Message "Team '$Team' was not found. Available team keys: $available." `
            -ErrorId 'PSLinear.TeamNotFound' -Category ObjectNotFound -TargetObject $Team)
}

function Get-LinearTeamKey {
    <#
    .SYNOPSIS
        Returns the key (ENG) of a team id for use in messages, or the id itself when the team is unknown.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $TeamId
    )

    $team = Get-LinearCachedTeam -TeamId $TeamId
    if ($null -ne $team) { return $team.Key }
    $TeamId
}

function Get-LinearCachedTeam {
    <#
    .SYNOPSIS
        Returns the cached team with this id, or nothing when it is not cached (for example an archived team).
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Team')]
    param(
        [Parameter(Mandatory)]
        [string] $TeamId
    )

    Get-LinearTeamCache | Where-Object { $null -ne $_ -and $_.Id -eq $TeamId } | Select-Object -First 1
}

function Get-LinearTeamLineage {
    <#
    .SYNOPSIS
        Returns a team id followed by the ids of its parent teams, nearest first.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $TeamId
    )

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $current = $TeamId
    while (-not [string]::IsNullOrEmpty($current) -and $seen.Add($current)) {
        $current
        $current = Get-LinearNestedValue -InputObject (Get-LinearCachedTeam -TeamId $current) -Name 'ParentId'
    }
}

function Test-LinearTeamUsesEstimate {
    <#
    .SYNOPSIS
        Returns $false when a team has estimates turned off, following sub-teams that inherit
        their estimation settings from a parent. Returns $true when it cannot tell, so callers
        only warn when they are sure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $TeamId
    )

    foreach ($id in Get-LinearTeamLineage -TeamId $TeamId) {
        $team = Get-LinearCachedTeam -TeamId $id
        $estimationType = Get-LinearNestedValue -InputObject $team -Name 'EstimationType'
        if ($null -eq $estimationType) { return $true }
        $inherits = [bool](Get-LinearNestedValue -InputObject $team -Name 'InheritEstimation')
        $parentId = Get-LinearNestedValue -InputObject $team -Name 'ParentId'
        if (-not $inherits -or $null -eq $parentId) { return $estimationType -ne 'notUsed' }
    }
    $true
}

function Reset-LinearTeamCache {
    <#
    .SYNOPSIS
        Forgets the cached teams, so name lookups and tab completion see teams that were just
        created, renamed or removed. With -TeamId, also forgets that team's workflow states,
        labels and cycles.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Clears an in-memory cache only.')]
    [CmdletBinding()]
    param(
        [string] $TeamId
    )

    $script:LinearTeamCache = $null
    $script:LinearTeamCacheExpires = [datetime]::MinValue
    if ($TeamId) {
        $script:LinearWorkflowStateCache.Remove($TeamId)
        $script:LinearLabelCache.Remove($TeamId)
        $script:LinearCycleCache.Remove($TeamId)
    }
}

function Get-LinearTeamMemberList {
    <#
    .SYNOPSIS
        Fetches a team's memberships. Returns [pscustomobject]@{ Members; Errors }, so a missing
        team can be written as one non-terminating error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $TeamId
    )

    $result = Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListTeamMemberships') -ConnectionPath 'team.memberships' `
        -Variables @{ id = $TeamId } -Limit 0 -IncludeErrors
    [pscustomobject]@{
        Members = @($result.Nodes | ConvertTo-LinearTeamMember | Sort-Object -Property Name)
        Errors  = $result.Errors
    }
}

