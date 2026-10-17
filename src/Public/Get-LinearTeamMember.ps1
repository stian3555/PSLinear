function Get-LinearTeamMember {
    <#
    .SYNOPSIS
        Gets the members of Linear teams.

    .DESCRIPTION
        Returns the members of one or more teams, sorted by name, with whether they own the team.
        Give teams by key, name or id, or pipe in teams from Get-LinearTeam. Use -User to check
        for specific people. An unknown team stops the command with an error that lists the
        valid keys.

    .PARAMETER Team
        One or more team keys, names or ids. Binds from the Key property of piped PSLinear.Team
        objects. Supports tab completion once connected.

    .PARAMETER User
        Only these members: 'me', email addresses, user ids, or full or display names. A user
        who is not a member of the team writes a non-terminating error.

    .EXAMPLE
        Get-LinearTeamMember ENG

        Lists a team's members.

    .EXAMPLE
        Get-LinearTeam | Get-LinearTeamMember | Where-Object Owner

        Lists the owners of every team.

    .EXAMPLE
        Get-LinearTeamMember ENG -User me

        Shows whether you are a member of ENG.

    .INPUTS
        System.String
        PSLinear.Team

    .OUTPUTS
        PSLinear.TeamMember

    .LINK
        Add-LinearTeamMember

    .LINK
        Remove-LinearTeamMember
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.TeamMember')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Key')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Team,

        [ValidateNotNullOrEmpty()]
        [string[]] $User
    )

    process {
        try {
            $teamIds = @(foreach ($value in $Team) { Resolve-LinearTeamId -Team $value })
            $userIds = @(foreach ($value in $User) { Resolve-LinearUserId -User $value })
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        foreach ($teamId in $teamIds) {
            $result = Get-LinearTeamMemberList -TeamId $teamId
            if ($result.Errors.Count -gt 0) {
                $message = Format-LinearFailureMessage -Message "Could not get the members of team $(Get-LinearTeamKey -TeamId $teamId)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.TeamMemberListFailed' -Category ReadError -TargetObject $teamId))
                continue
            }
            if ($userIds.Count -eq 0) {
                foreach ($member in $result.Members) { $member }
                continue
            }
            foreach ($userId in $userIds) {
                $member = @($result.Members | Where-Object { $null -ne $_ -and $_.UserId -eq $userId })
                if ($member.Count -eq 0) {
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message "User $userId is not a member of team $(Get-LinearTeamKey -TeamId $teamId)." `
                                -ErrorId 'PSLinear.TeamMemberNotFound' -Category ObjectNotFound -TargetObject $userId))
                    continue
                }
                $member[0]
            }
        }
    }
}
