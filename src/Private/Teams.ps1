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
        $script:LinearTeamCacheExpires = [datetime]::UtcNow.Add($script:TeamCacheLifetime)
    }
    $script:LinearTeamCache
}

function Resolve-LinearTeamId {
    <#
    .SYNOPSIS
        Resolves a team id, key (ENG) or name (Engineering) to the team's id.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Team
    )

    $parsedGuid = [guid]::Empty
    if ([guid]::TryParse($Team, [ref]$parsedGuid)) { return $Team }

    foreach ($refresh in $false, $true) {
        $match = @(Get-LinearTeamCache -Refresh:$refresh | Where-Object { $null -ne $_ -and ($_.Key -eq $Team -or $_.Name -eq $Team) })
        if ($match.Count -eq 1) { return $match[0].Id }
        if ($match.Count -gt 1) {
            throw "Team '$Team' is ambiguous. Use the team key or id instead. Matches: $(($match | ForEach-Object { "$($_.Key) ($($_.Name))" }) -join ', ')."
        }
    }

    $available = (Get-LinearTeamCache | Where-Object { $null -ne $_ } | ForEach-Object Key) -join ', '
    throw "Team '$Team' was not found. Available team keys: $available."
}
