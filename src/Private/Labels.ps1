function Get-LinearLabelCache {
    <#
    .SYNOPSIS
        Returns the labels that can be applied to issues in one team, cached for a few minutes.
    .DESCRIPTION
        Includes workspace labels and the team's own labels. Label groups (which cannot be
        applied to an issue) and retired labels are left out.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Label')]
    param(
        [Parameter(Mandatory)]
        [string] $TeamId,

        [switch] $Refresh
    )

    $entry = $script:LinearLabelCache[$TeamId]
    if ($Refresh -or $null -eq $entry -or [datetime]::UtcNow -ge $entry.Expires) {
        $entry = @{ Items = @(Get-LinearLabelList -TeamId $TeamId); Expires = [datetime]::UtcNow.Add($script:CacheLifetime) }
        $script:LinearLabelCache[$TeamId] = $entry
    }
    $entry.Items
}

function Get-LinearLabelList {
    <#
    .SYNOPSIS
        Fetches the labels that can be applied to issues, sorted by name.
    .DESCRIPTION
        With -TeamId, returns workspace labels and the labels of that team and its parent teams;
        a team's inherited copy of a workspace or parent-team label replaces the original, so
        each name appears once. Without -TeamId, returns every label in the workspace. Label
        groups and retired labels are left out unless -IncludeGroups or -IncludeRetired is given.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Label')]
    param(
        [string] $TeamId,

        [switch] $IncludeGroups,

        [switch] $IncludeRetired
    )

    $variables = @{}
    if ($TeamId) {
        $variables['filter'] = @{
            or = @(
                @{ team = @{ null = $true } }
                @{ team = @{ id = @{ in = @(Get-LinearTeamLineage -TeamId $TeamId) } } }
            )
        }
    }
    $labels = @(Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListIssueLabels') -ConnectionPath 'issueLabels' -Limit 0 -Variables $variables |
            ConvertTo-LinearLabel |
            Where-Object { $null -ne $_ -and ($IncludeGroups -or -not $_.IsGroup) -and ($IncludeRetired -or $null -eq $_.RetiredAt) })
    if ($TeamId) {
        $replaced = @($labels | ForEach-Object InheritedFromId | Where-Object { $_ })
        $labels = @($labels | Where-Object { $_.Id -notin $replaced })
    }
    $labels | Sort-Object -Property Name
}

function Resolve-LinearLabelId {
    <#
    .SYNOPSIS
        Resolves label names (Bug) or ids to label ids, using the labels available to one team.
    .NOTES
        Throws an ErrorRecord (PSLinear.LabelNotFound or PSLinear.AmbiguousLabel) that callers
        rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $TeamId,

        [Parameter(Mandatory)]
        [string[]] $Label
    )

    foreach ($name in $Label) {
        if (Test-LinearGuid -Value $name) {
            $name
            continue
        }

        $match = @()
        foreach ($refresh in $false, $true) {
            $match = @(Get-LinearLabelCache -TeamId $TeamId -Refresh:$refresh | Where-Object { $null -ne $_ -and $_.Name -eq $name })
            if ($match.Count -gt 0) { break }
        }

        if ($match.Count -eq 1) {
            $match[0].Id
            continue
        }

        $teamKey = Get-LinearTeamKey -TeamId $TeamId
        if ($match.Count -gt 1) {
            $matchList = ($match | ForEach-Object {
                    $scope = if ($_.Team) { "team $($_.Team)" } else { 'workspace' }
                    $groupPrefix = if ($_.Group) { "$($_.Group)/" } else { '' }
                    "$groupPrefix$($_.Name) ($scope, id $($_.Id))"
                }) -join '; '
            throw (New-LinearErrorRecord -Message "Label '$name' is ambiguous in team $teamKey. Use the label id instead. Matches: $matchList." `
                    -ErrorId 'PSLinear.AmbiguousLabel' -Category InvalidArgument -TargetObject $name)
        }

        $available = Format-LinearValueList -Value (Get-LinearLabelCache -TeamId $TeamId | Where-Object { $null -ne $_ } | ForEach-Object Name | Select-Object -Unique)
        throw (New-LinearErrorRecord -Message "Label '$name' was not found in team $teamKey. Valid labels: $available." `
                -ErrorId 'PSLinear.LabelNotFound' -Category ObjectNotFound -TargetObject $name)
    }
}

function Resolve-LinearListedLabelId {
    <#
    .SYNOPSIS
        Resolves label names or ids against a cached list of workspace labels, such as project or
        initiative labels.
    .PARAMETER CacheCommand
        The private command that returns the cached labels and takes -Refresh, for example
        Get-LinearProjectLabelCache.
    .PARAMETER Noun
        What the labels are called in messages, for example 'Project label'.
    .NOTES
        Throws an ErrorRecord (PSLinear.LabelNotFound or PSLinear.AmbiguousLabel) that callers
        rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Label,

        [Parameter(Mandatory)]
        [string] $CacheCommand,

        [Parameter(Mandatory)]
        [string] $Noun
    )

    foreach ($name in $Label) {
        if (Test-LinearGuid -Value $name) {
            $name
            continue
        }
        $match = @()
        foreach ($refresh in $false, $true) {
            $match = @(& $CacheCommand -Refresh:$refresh | Where-Object { $null -ne $_ -and $_.Name -eq $name })
            if ($match.Count -gt 0) { break }
        }
        if ($match.Count -eq 1) {
            $match[0].Id
            continue
        }
        if ($match.Count -gt 1) {
            $matchList = ($match | ForEach-Object {
                    $scope = if ($_.Team) { "team $($_.Team)" } else { 'workspace' }
                    "$(if ($_.Group) { "$($_.Group)/" })$($_.Name) ($scope, id $($_.Id))"
                }) -join '; '
            throw (New-LinearErrorRecord -Message "$Noun '$name' is ambiguous. Use the label id instead. Matches: $matchList." `
                    -ErrorId 'PSLinear.AmbiguousLabel' -Category InvalidArgument -TargetObject $name)
        }
        $available = Format-LinearValueList -Value (& $CacheCommand | Where-Object { $null -ne $_ } | ForEach-Object Name | Select-Object -Unique)
        throw (New-LinearErrorRecord -Message "$Noun '$name' was not found. Valid $($Noun.ToLowerInvariant())s: $available." `
                -ErrorId 'PSLinear.LabelNotFound' -Category ObjectNotFound -TargetObject $name)
    }
}

function Get-LinearScopedLabel {
    <#
    .SYNOPSIS
        Fetches the labels that belong to one scope: a team's own labels with -TeamId, or the
        workspace labels without it. Groups and retired labels are included.
    .DESCRIPTION
        Used by the label management commands, which change a label itself rather than apply
        it, so labels inherited from the workspace or parent teams are not part of a team's
        scope. The result is not cached.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Label')]
    param(
        [string] $TeamId
    )

    $filter = if ($TeamId) { @{ team = @{ id = @{ eq = $TeamId } } } } else { @{ team = @{ null = $true } } }
    Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListIssueLabels') -ConnectionPath 'issueLabels' -Limit 0 -Variables @{ filter = $filter } |
        ConvertTo-LinearLabel |
        Sort-Object -Property Name, Id
}

function Resolve-LinearScopedLabelId {
    <#
    .SYNOPSIS
        Resolves a label name or id within one scope (a team's own labels, or the workspace
        labels) to the label's id. A name can include its group: Area/Frontend.
    .PARAMETER GroupOnly
        Only label groups match, for the parent of a new or moved label. Workspace groups are
        then valid for team labels too.
    .NOTES
        Throws an ErrorRecord (PSLinear.LabelNotFound or PSLinear.AmbiguousLabel) that callers
        rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Label,

        [string] $TeamId,

        [switch] $GroupOnly
    )

    if (Test-LinearGuid -Value $Label) { return $Label }

    $candidates = @(Get-LinearScopedLabel -TeamId $TeamId)
    if ($GroupOnly -and $TeamId) { $candidates += @(Get-LinearScopedLabel) }
    $candidates = @($candidates | Where-Object { $null -ne $_ -and (-not $GroupOnly -or $_.IsGroup) })

    $group, $name = if ($Label.Contains('/')) { $Label.Split('/', 2) } else { $null, $Label }
    $match = @($candidates | Where-Object { $_.Name -eq $name -and ($null -eq $group -or $_.Group -eq $group) })
    # A name with a slash in it may be the whole label name rather than Group/Name.
    if ($match.Count -eq 0 -and $null -ne $group) { $match = @($candidates | Where-Object Name -EQ $Label) }

    $scope = if ($TeamId) { "team $(Get-LinearTeamKey -TeamId $TeamId)" } else { 'the workspace' }
    $noun = if ($GroupOnly) { 'Label group' } else { 'Label' }
    if ($match.Count -eq 1) { return $match[0].Id }
    if ($match.Count -gt 1) {
        $matchList = ($match | ForEach-Object { "$(if ($_.Group) { "$($_.Group)/" })$($_.Name) (id $($_.Id))" }) -join '; '
        throw (New-LinearErrorRecord -Message "$noun '$Label' is ambiguous in $scope. Use Group/Name or the label id instead. Matches: $matchList." `
                -ErrorId 'PSLinear.AmbiguousLabel' -Category InvalidArgument -TargetObject $Label)
    }
    $available = Format-LinearValueList -Value ($candidates | ForEach-Object { "$(if ($_.Group) { "$($_.Group)/" })$($_.Name)" } | Select-Object -Unique)
    throw (New-LinearErrorRecord -Message "$noun '$Label' was not found in $scope. Valid $($noun.ToLowerInvariant())s: $available." `
            -ErrorId 'PSLinear.LabelNotFound' -Category ObjectNotFound -TargetObject $Label)
}

function Reset-LinearLabelCache {
    <#
    .SYNOPSIS
        Forgets the cached labels of every team, so name lookups see labels that were just created, changed or deleted.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Clears an in-memory cache only.')]
    [CmdletBinding()]
    param()

    $script:LinearLabelCache = @{}
}

