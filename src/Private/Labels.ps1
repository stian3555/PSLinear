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
        groups and retired labels are left out.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Label')]
    param(
        [string] $TeamId
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
            Where-Object { $null -ne $_ -and -not $_.IsGroup -and $null -eq $_.RetiredAt })
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
