function Add-LinearTeamMember {
    <#
    .SYNOPSIS
        Adds users to a Linear team.

    .DESCRIPTION
        Adds one or more users to a team and returns the new memberships. Users who are already
        members are skipped with a warning. Give the team by key, name or id, or pipe in a team.
        Names are resolved to ids for you; an unknown team or user stops the command with an
        error that lists the valid values. With -WhatIf nothing is sent, not even the lookups.

    .PARAMETER Team
        The team key, name or id. Binds from the Key property of piped PSLinear.Team objects.
        Supports tab completion once connected.

    .PARAMETER User
        One or more users: 'me', email addresses, user ids, or full or display names.

    .EXAMPLE
        Add-LinearTeamMember ENG -User 'grace@example.com', 'ada@example.com'

        Adds two people to a team.

    .EXAMPLE
        Get-LinearTeam -Name 'Mobile*' | Add-LinearTeamMember -User me

        Joins every team whose name starts with Mobile.

    .INPUTS
        PSLinear.Team

    .OUTPUTS
        PSLinear.TeamMember

    .LINK
        Get-LinearTeamMember

    .LINK
        Remove-LinearTeamMember
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PSLinear.TeamMember')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('Key')]
        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string[]] $User
    )

    process {
        if (-not $PSCmdlet.ShouldProcess("team $Team", "Add member $($User -join ', ')")) {
            return
        }

        try {
            $teamId = Resolve-LinearTeamId -Team $Team
            $userIds = @(foreach ($value in $User) { Resolve-LinearUserId -User $value })
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $current = Get-LinearTeamMemberList -TeamId $teamId
        if ($current.Errors.Count -gt 0) {
            $message = Format-LinearFailureMessage -Message "Could not get the members of team $Team." -Errors $current.Errors
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.TeamMemberListFailed' -Category ReadError -TargetObject $Team))
            return
        }
        foreach ($userId in ($userIds | Select-Object -Unique)) {
            if (@($current.Members | Where-Object { $null -ne $_ -and $_.UserId -eq $userId }).Count -gt 0) {
                Write-Warning "User $userId is already a member of team $Team."
                continue
            }
            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateTeamMembership') `
                -Variables @{ input = @{ teamId = $teamId; userId = $userId } } -IncludeErrors
            $membership = Get-LinearNestedValue -InputObject $result.Data -Name 'teamMembershipCreate.teamMembership'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'teamMembershipCreate.success') -or $null -eq $membership) {
                $message = Format-LinearFailureMessage -Message "Linear did not add user $userId to team $Team." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.TeamMemberAddFailed' -Category WriteError -TargetObject $userId))
                continue
            }
            ConvertTo-LinearTeamMember -InputObject $membership
        }
    }
}
