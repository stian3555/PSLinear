function Get-LinearWorkflowState {
    <#
    .SYNOPSIS
        Gets the workflow states of Linear teams.

    .DESCRIPTION
        Returns the workflow states (such as Todo, In Progress and Done) of one team, or of
        every team when -Team is not given, in the order Linear shows them. Use -Name or -Type
        to filter. A name without wildcards that matches no state writes a non-terminating
        error.

        The result also refreshes the cache that New-LinearIssue and Set-LinearIssue use to
        resolve -State.

    .PARAMETER Team
        The team key (ENG), name or id. Accepts PSLinear.Team objects from the pipeline.
        Supports tab completion once connected. Defaults to every team.

    .PARAMETER Name
        One or more state names. Wildcards are supported.

    .PARAMETER Type
        State types: Triage, Backlog, Unstarted, Started, Completed, Canceled or Duplicate.

    .EXAMPLE
        Get-LinearWorkflowState -Team ENG

        Lists the ENG team's workflow states.

    .EXAMPLE
        Get-LinearWorkflowState -Type Started

        Lists the started states of every team.

    .EXAMPLE
        Get-LinearTeam | Get-LinearWorkflowState -Name 'In Review'

        Shows which teams have an 'In Review' state.

    .INPUTS
        PSLinear.Team
        System.Management.Automation.PSObject

    .OUTPUTS
        PSLinear.WorkflowState

    .LINK
        Set-LinearIssue
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.WorkflowState')]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('Key')]
        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name,

        [ValidateSet('Triage', 'Backlog', 'Unstarted', 'Started', 'Completed', 'Canceled', 'Duplicate')]
        [string[]] $Type
    )

    begin {
        $missingNames = $null
    }

    process {
        try {
            $teamIds = if ($Team) { Resolve-LinearTeamId -Team $Team } else { Get-LinearTeamCache -Refresh | ForEach-Object Id }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $states = @(foreach ($teamId in $teamIds) { Get-LinearWorkflowStateCache -TeamId $teamId -Refresh })
        if ($Type) {
            $states = @($states | Where-Object { $null -ne $_ -and $_.Type -in $Type })
        }
        if ($Name) {
            $selection = Select-LinearObjectByName -InputObject $states -Name $Name -Property 'Name'
            $states = $selection.Selected
            # A name only counts as missing when no team (from any pipeline input) has it.
            $missingNames = if ($null -eq $missingNames) { @($selection.Missing) } else { @($missingNames | Where-Object { $_ -in $selection.Missing }) }
        }
        foreach ($state in $states) { $state }
    }

    end {
        foreach ($missing in @($missingNames | Where-Object { $null -ne $_ })) {
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message "Workflow state '$missing' was not found." `
                        -ErrorId 'PSLinear.StateNotFound' -Category ObjectNotFound -TargetObject $missing))
        }
    }
}
