function Get-LinearCycleCache {
    <#
    .SYNOPSIS
        Returns the cycles of one team, sorted by number, cached for a few minutes.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Cycle')]
    param(
        [Parameter(Mandatory)]
        [string] $TeamId,

        [switch] $Refresh
    )

    $entry = $script:LinearCycleCache[$TeamId]
    if ($Refresh -or $null -eq $entry -or [datetime]::UtcNow -ge $entry.Expires) {
        $variables = @{ filter = @{ team = @{ id = @{ eq = $TeamId } } } }
        $cycles = @(Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListCycles') -ConnectionPath 'cycles' -Limit 0 -Variables $variables |
                ConvertTo-LinearCycle |
                Sort-Object -Property Number)
        $entry = @{ Items = $cycles; Expires = [datetime]::UtcNow.Add($script:CacheLifetime) }
        $script:LinearCycleCache[$TeamId] = $entry
    }
    $entry.Items
}

function Resolve-LinearCycleId {
    <#
    .SYNOPSIS
        Resolves a cycle reference to a cycle id within one team.
    .DESCRIPTION
        Accepts active (or current), next, previous, an offset from the active cycle (+1, -1),
        a cycle number, a cycle name, or an id.
    .NOTES
        Throws an ErrorRecord (PSLinear.CycleNotFound) that callers rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $TeamId,

        [Parameter(Mandatory)]
        [string] $Cycle
    )

    if (Test-LinearGuid -Value $Cycle) { return $Cycle }

    $cycles = @()
    foreach ($refresh in $false, $true) {
        $cycles = @(Get-LinearCycleCache -TeamId $TeamId -Refresh:$refresh | Where-Object { $null -ne $_ })
        $active = $cycles | Where-Object Status -EQ 'Active' | Select-Object -First 1
        $match = @(switch -Regex ($Cycle) {
                '^(active|current)$' { $active }
                '^next$' { $cycles | Where-Object Status -EQ 'Next' }
                '^previous$' { $cycles | Where-Object Status -EQ 'Previous' }
                '^[+-]\d+$' { if ($null -ne $active) { $number = $active.Number + [int]$Cycle; $cycles | Where-Object Number -EQ $number } }
                '^\d+$' { $cycles | Where-Object Number -EQ ([int]$Cycle) }
                default { $cycles | Where-Object Name -EQ $Cycle }
            })
        $match = @($match | Where-Object { $null -ne $_ })
        if ($match.Count -gt 0) { return $match[0].Id }
    }

    $teamKey = Get-LinearTeamKey -TeamId $TeamId
    if ($cycles.Count -eq 0) {
        throw (New-LinearErrorRecord -Message "Team $teamKey has no cycles. Turn on cycles in the team's settings to use -Cycle." `
                -ErrorId 'PSLinear.CycleNotFound' -Category ObjectNotFound -TargetObject $Cycle)
    }
    $numbers = '{0} to {1}' -f $cycles[0].Number, $cycles[-1].Number
    $names = Format-LinearValueList -Value ($cycles | ForEach-Object Name | Where-Object { $_ })
    throw (New-LinearErrorRecord -Message "Cycle '$Cycle' was not found in team $teamKey. Use active, next, previous, +1 or -1, a number ($numbers) or a name ($names)." `
            -ErrorId 'PSLinear.CycleNotFound' -Category ObjectNotFound -TargetObject $Cycle)
}
