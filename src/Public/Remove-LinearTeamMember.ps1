function Remove-LinearTeamMember {
    <#
    .SYNOPSIS
        Removes users from a Linear team.

    .DESCRIPTION
        Removes users from a team, given with -Team and -User or piped in from
        Get-LinearTeamMember. You can always remove yourself; removing others needs team owner
        or workspace admin rights. Their issues stay in the team.

        The command asks for confirmation for each member; use -Confirm:$false to skip that, or
        -WhatIf to see what would happen without sending anything. A user who is not a member,
        or a removal Linear refuses, writes a non-terminating error and the remaining users are
        still processed. Nothing is returned.

    .PARAMETER Team
        The team key, name or id. Supports tab completion once connected.

    .PARAMETER User
        One or more users: 'me', email addresses, user ids, or full or display names.

    .PARAMETER InputObject
        PSLinear.TeamMember objects, typically from Get-LinearTeamMember.

    .EXAMPLE
        Remove-LinearTeamMember ENG -User 'grace@example.com'

        Removes someone from a team, after asking for confirmation.

    .EXAMPLE
        Get-LinearTeamMember OPS | Where-Object { -not $_.Active } | Remove-LinearTeamMember -Confirm:$false

        Removes deactivated users from a team without asking.

    .INPUTS
        PSLinear.TeamMember

    .OUTPUTS
        None

    .LINK
        Get-LinearTeamMember

    .LINK
        Add-LinearTeamMember
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByUser', SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'ByUser')]
        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [Parameter(Mandatory, Position = 1, ParameterSetName = 'ByUser')]
        [ValidateNotNullOrEmpty()]
        [string[]] $User,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.TeamMember')]
        [object[]] $InputObject
    )

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ByObject') {
            foreach ($member in $InputObject) {
                $memberName = Get-LinearNestedValue -InputObject $member -Name 'Name'
                [pscustomobject]@{
                    MembershipId  = Get-LinearNestedValue -InputObject $member -Name 'MembershipId'
                    UserReference = Get-LinearNestedValue -InputObject $member -Name 'UserId'
                    Name          = "$memberName in team $(Get-LinearNestedValue -InputObject $member -Name 'Team')"
                }
            }
        }
        else {
            foreach ($value in $User) { [pscustomobject]@{ MembershipId = $null; UserReference = $value; Name = "$value in team $Team" } }
        }

        $members = $null
        $teamId = $null
        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, 'Remove team member')) {
                continue
            }

            $membershipId = $target.MembershipId
            if (-not $membershipId) {
                try {
                    if ($null -eq $teamId) { $teamId = Resolve-LinearTeamId -Team $Team }
                    $userId = Resolve-LinearUserId -User $target.UserReference
                }
                catch {
                    $PSCmdlet.ThrowTerminatingError($_)
                }
                if ($null -eq $members) {
                    $list = Get-LinearTeamMemberList -TeamId $teamId
                    if ($list.Errors.Count -gt 0) {
                        $message = Format-LinearFailureMessage -Message "Could not get the members of team $Team." -Errors $list.Errors
                        $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.TeamMemberListFailed' -Category ReadError -TargetObject $Team))
                        return
                    }
                    $members = $list.Members
                }
                $member = @($members | Where-Object { $null -ne $_ -and $_.UserId -eq $userId })
                if ($member.Count -eq 0) {
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message "$($target.UserReference) is not a member of team $Team." `
                                -ErrorId 'PSLinear.TeamMemberNotFound' -Category ObjectNotFound -TargetObject $target.UserReference))
                    continue
                }
                $membershipId = $member[0].MembershipId
            }

            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'DeleteTeamMembership') -Variables @{ id = $membershipId } -IncludeErrors
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'teamMembershipDelete.success')) {
                $message = Format-LinearFailureMessage -Message "Linear did not remove $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.TeamMemberRemoveFailed' -Category WriteError -TargetObject $membershipId))
            }
        }
    }
}
