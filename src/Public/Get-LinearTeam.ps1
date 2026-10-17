function Get-LinearTeam {
    <#
    .SYNOPSIS
        Gets teams in the Linear workspace.

    .DESCRIPTION
        Returns the teams the authenticated user can access. Use -Name to filter by team
        key or name; wildcards are supported.

    .PARAMETER Name
        One or more team keys (ENG) or names (Engineering) to return. Wildcards are supported.

    .PARAMETER IncludeArchived
        Also returns archived teams.

    .EXAMPLE
        Get-LinearTeam

        Lists all teams.

    .EXAMPLE
        Get-LinearTeam -Name 'ENG', 'Plat*'

        Returns the ENG team and every team whose key or name starts with 'Plat'.

    .EXAMPLE
        Get-LinearTeam -Name ENG | Get-LinearIssue -State 'In Progress'

        Pipes a team into Get-LinearIssue.

    .INPUTS
        System.String

    .OUTPUTS
        PSLinear.Team

    .LINK
        Get-LinearIssue
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Team')]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name,

        [switch] $IncludeArchived
    )

    begin {
        $requestedNames = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($Name) { $requestedNames.AddRange([string[]]$Name) }
    }

    end {
        if ($IncludeArchived) {
            $query = Get-LinearGraphQLDocument -Name 'ListTeams'
            $teams = @(Invoke-LinearPagedRequest -Query $query -ConnectionPath 'teams' -Limit 0 -Variables @{ includeArchived = $true } |
                    ConvertTo-LinearTeam)
        }
        else {
            # Always fetch fresh data here; this also refreshes the cache used for name resolution.
            $teams = @(Get-LinearTeamCache -Refresh)
        }

        if ($requestedNames.Count -eq 0) {
            foreach ($team in $teams) { $team }
            return
        }

        foreach ($pattern in $requestedNames) {
            $found = @($teams | Where-Object { $_.Key -like $pattern -or $_.Name -like $pattern })
            if ($found.Count -eq 0 -and -not [WildcardPattern]::ContainsWildcardCharacters($pattern)) {
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message "Team '$pattern' was not found." `
                            -ErrorId 'PSLinear.TeamNotFound' -Category ObjectNotFound -TargetObject $pattern))
            }
            foreach ($team in $found) { $team }
        }
    }
}
