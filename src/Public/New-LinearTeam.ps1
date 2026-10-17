function New-LinearTeam {
    <#
    .SYNOPSIS
        Creates a Linear team.

    .DESCRIPTION
        Creates a team and returns it. You become its first member (not its owner). Linear
        derives the key from the name when -Key is not given, and creates the default workflow
        states. With -WhatIf nothing is sent, not even the parent team lookup.

    .PARAMETER Name
        The team name.

    .PARAMETER Key
        The team key used in issue identifiers, such as ENG in ENG-123.

    .PARAMETER Description
        The team description.

    .PARAMETER Parent
        Creates a sub-team of this team (key, name or id).

    .PARAMETER Timezone
        The team's time zone, as an IANA name such as Europe/Oslo. Linear uses it for cycles.

    .EXAMPLE
        New-LinearTeam 'Platform' -Key PLAT -Description 'Shared infrastructure'

        Creates a team with its own key.

    .EXAMPLE
        New-LinearTeam 'Mobile' -Parent ENG -Timezone Europe/Oslo

        Creates a sub-team.

    .INPUTS
        None

    .OUTPUTS
        PSLinear.Team

    .LINK
        Get-LinearTeam

    .LINK
        Set-LinearTeam

    .LINK
        Remove-LinearTeam
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PSLinear.Team')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [ValidatePattern('^[A-Za-z0-9]+$', ErrorMessage = "'{0}' is not a team key. Use letters and digits only, such as ENG.")]
        [string] $Key,

        [string] $Description,

        [ValidateNotNullOrEmpty()]
        [string] $Parent,

        [ValidateNotNullOrEmpty()]
        [string] $Timezone
    )

    $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name 'Key', 'Description', 'Parent', 'Timezone'
    $action = if ($changes) { "Create team '$Name' ($changes)" } else { "Create team '$Name'" }
    if (-not $PSCmdlet.ShouldProcess('workspace', $action)) {
        return
    }

    try {
        $teamInput = @{ name = $Name }
        if ($Key) { $teamInput['key'] = $Key.ToUpperInvariant() }
        if ($PSBoundParameters.ContainsKey('Description')) { $teamInput['description'] = $Description }
        if ($Parent) { $teamInput['parentId'] = Resolve-LinearTeamId -Team $Parent }
        if ($Timezone) { $teamInput['timezone'] = $Timezone }
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateTeam') -Variables @{ input = $teamInput } -IncludeErrors
    $team = Get-LinearNestedValue -InputObject $result.Data -Name 'teamCreate.team'
    if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'teamCreate.success') -or $null -eq $team) {
        $message = Format-LinearFailureMessage -Message "Linear did not create team '$Name'." -Errors $result.Errors
        $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.TeamCreateFailed' -Category WriteError -TargetObject $Name))
        return
    }
    # So that -Team finds the new team, and tab completion offers it, right away.
    Reset-LinearTeamCache
    ConvertTo-LinearTeam -InputObject $team
}
