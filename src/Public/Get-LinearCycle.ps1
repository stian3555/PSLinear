function Get-LinearCycle {
    <#
    .SYNOPSIS
        Gets the cycles of Linear teams.

    .DESCRIPTION
        Returns the cycles of one team, or of every team when -Team is not given, sorted by team
        and cycle number. Each cycle has a Status of Active, Next, Previous, Past or Future.

        -Active, -Next and -Previous can be combined to return any of those cycles, and -Number
        returns specific cycles.

    .PARAMETER Team
        The team key (ENG), name or id. Accepts PSLinear.Team objects from the pipeline.
        Supports tab completion once connected. Defaults to every team.

    .PARAMETER Number
        One or more cycle numbers.

    .PARAMETER Active
        Returns the active (current) cycle.

    .PARAMETER Next
        Returns the next cycle.

    .PARAMETER Previous
        Returns the previous cycle.

    .EXAMPLE
        Get-LinearCycle -Team ENG

        Lists every cycle of the ENG team.

    .EXAMPLE
        Get-LinearCycle -Active

        Shows the current cycle of every team that uses cycles.

    .EXAMPLE
        Get-LinearCycle -Team ENG -Previous -Active -Next | Format-Table Number, Status, StartsAt, EndsAt, Progress

        Shows the previous, current and next cycle side by side.

    .INPUTS
        PSLinear.Team
        System.Management.Automation.PSObject

    .OUTPUTS
        PSLinear.Cycle

    .LINK
        Get-LinearIssue
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Cycle')]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('Key')]
        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [ValidateRange(0, [int]::MaxValue)]
        [int[]] $Number,

        [switch] $Active,

        [switch] $Next,

        [switch] $Previous
    )

    process {
        try {
            $filter = @{}
            if ($Team) {
                $filter['team'] = @{ id = @{ eq = (Resolve-LinearTeamId -Team $Team) } }
            }
            if ($Number) {
                $filter['number'] = @{ in = @($Number) }
            }
            $when = @(
                if ($Active) { @{ isActive = @{ eq = $true } } }
                if ($Next) { @{ isNext = @{ eq = $true } } }
                if ($Previous) { @{ isPrevious = @{ eq = $true } } }
            )
            if ($when.Count -gt 0) {
                $filter['or'] = $when
            }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $variables = @{}
        if ($filter.Count -gt 0) { $variables['filter'] = $filter }
        Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListCycles') -ConnectionPath 'cycles' -Limit 0 -Variables $variables |
            ConvertTo-LinearCycle |
            Sort-Object -Property Team, Number
    }
}
