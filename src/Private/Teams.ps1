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

    $match = @(Get-LinearTeamCache | Where-Object { $null -ne $_ -and $_.Id -eq $TeamId })
    if ($match.Count -gt 0) { return $match[0].Key }
    $TeamId
}
