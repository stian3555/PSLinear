function Set-LinearTeam {
    <#
    .SYNOPSIS
        Changes Linear teams.

    .DESCRIPTION
        Renames teams, changes their key, description or time zone, or moves them under another
        team. Give teams by key, name or id, or pipe them in from Get-LinearTeam. Changing the
        key changes the identifiers of the team's issues; Linear keeps the old identifiers
        working as redirects. Nothing is returned unless you use -PassThru.

        A change Linear rejects writes a non-terminating error and the remaining teams are still
        processed. An unknown team stops the command with an error that lists the valid keys.
        With -WhatIf nothing is sent.

    .PARAMETER Team
        One or more team keys, names or ids. Supports tab completion once connected.

    .PARAMETER InputObject
        PSLinear.Team objects, typically from Get-LinearTeam.

    .PARAMETER Name
        The new name.

    .PARAMETER Key
        The new key used in issue identifiers.

    .PARAMETER Description
        The new description. An empty string clears it.

    .PARAMETER Timezone
        The new time zone, as an IANA name such as Europe/Oslo.

    .PARAMETER Parent
        Makes the teams sub-teams of this team (key, name or id).

    .PARAMETER Clear
        Removes values: Parent (makes the teams top-level teams).

    .PARAMETER PassThru
        Returns the updated teams.

    .EXAMPLE
        Set-LinearTeam ENG -Description 'Product engineering' -Timezone Europe/Oslo

        Changes a team's description and time zone.

    .EXAMPLE
        Set-LinearTeam MOB -Parent ENG -PassThru

        Makes a team a sub-team of ENG and returns it.

    .INPUTS
        System.String
        PSLinear.Team

    .OUTPUTS
        PSLinear.Team

    .LINK
        Get-LinearTeam

    .LINK
        New-LinearTeam
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByTeam', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('PSLinear.Team')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ByTeam')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Team,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Team')]
        [object[]] $InputObject,

        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [ValidatePattern('^[A-Za-z0-9]+$', ErrorMessage = "'{0}' is not a team key. Use letters and digits only, such as ENG.")]
        [string] $Key,

        [string] $Description,

        [ValidateNotNullOrEmpty()]
        [string] $Timezone,

        [ValidateNotNullOrEmpty()]
        [string] $Parent,

        [ValidateSet('Parent')]
        [string[]] $Clear,

        [switch] $PassThru
    )

    begin {
        $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name 'Name', 'Key', 'Description', 'Timezone', 'Parent', 'Clear'
        $invalidMessage = if ($Clear -contains 'Parent' -and $Parent) {
            'Use either -Clear Parent or -Parent, not both.'
        }
        elseif (-not $changes) {
            'Specify at least one change, such as -Name, -Key or -Description.'
        }
        if ($invalidMessage) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message $invalidMessage -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }
        $updateQuery = Get-LinearGraphQLDocument -Name 'UpdateTeam'
    }

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ByTeam') {
            foreach ($value in $Team) { [pscustomobject]@{ Id = $null; Reference = $value; Name = "team $value" } }
        }
        else {
            foreach ($object in $InputObject) {
                [pscustomobject]@{ Id = $object.Id; Reference = $object.Id; Name = "team $(Get-LinearNestedValue -InputObject $object -Name 'Key')" }
            }
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, "Update team ($changes)")) {
                continue
            }

            try {
                $teamId = if ($target.Id) { $target.Id } else { Resolve-LinearTeamId -Team $target.Reference }
                $teamInput = @{}
                if ($PSBoundParameters.ContainsKey('Name')) { $teamInput['name'] = $Name }
                if ($Key) { $teamInput['key'] = $Key.ToUpperInvariant() }
                if ($PSBoundParameters.ContainsKey('Description')) { $teamInput['description'] = $Description }
                if ($Timezone) { $teamInput['timezone'] = $Timezone }
                if ($Parent) { $teamInput['parentId'] = Resolve-LinearTeamId -Team $Parent }
                if ($Clear -contains 'Parent') { $teamInput['parentId'] = $null }
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }

            $result = Invoke-LinearRequest -Query $updateQuery -Variables @{ id = $teamId; input = $teamInput } -IncludeErrors
            $updated = Get-LinearNestedValue -InputObject $result.Data -Name 'teamUpdate.team'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'teamUpdate.success') -or $null -eq $updated) {
                $message = Format-LinearFailureMessage -Message "Linear did not update $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.TeamUpdateFailed' -Category WriteError -TargetObject $target.Reference))
                continue
            }
            # Names, keys and parents feed -Team lookups and label inheritance.
            Reset-LinearTeamCache -TeamId $teamId
            if ($PassThru) {
                ConvertTo-LinearTeam -InputObject $updated
            }
        }
    }
}
