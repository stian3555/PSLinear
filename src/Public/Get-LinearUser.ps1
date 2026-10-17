function Get-LinearUser {
    <#
    .SYNOPSIS
        Gets users in the Linear workspace.

    .DESCRIPTION
        Returns the workspace's active users, sorted by name. Use -Name to filter by full name,
        display name or email address; wildcards are supported. A name without wildcards that
        matches nobody writes a non-terminating error.

        The result also refreshes the cache that New-LinearIssue and Set-LinearIssue use to
        resolve -Assignee.

    .PARAMETER Name
        One or more full names, display names or email addresses. Wildcards are supported.

    .PARAMETER IncludeDisabled
        Also returns disabled (deactivated) users.

    .EXAMPLE
        Get-LinearUser

        Lists the active users.

    .EXAMPLE
        Get-LinearUser -Name '*@example.com'

        Lists the users with an example.com email address.

    .EXAMPLE
        Get-LinearUser -IncludeDisabled | Where-Object -Not Active

        Lists the deactivated users.

    .INPUTS
        System.String

    .OUTPUTS
        PSLinear.User

    .LINK
        Get-LinearViewer
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.User')]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name,

        [switch] $IncludeDisabled
    )

    begin {
        $requestedNames = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($Name) { $requestedNames.AddRange([string[]]$Name) }
    }

    end {
        $users = if ($IncludeDisabled) { @(Get-LinearUserList -IncludeDisabled) } else { @(Get-LinearUserCache -Refresh) }

        if ($requestedNames.Count -eq 0) {
            foreach ($user in $users) { $user }
            return
        }

        $selection = Select-LinearObjectByName -InputObject $users -Name $requestedNames -Property 'Name', 'DisplayName', 'Email'
        foreach ($missing in $selection.Missing) {
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message "User '$missing' was not found." `
                        -ErrorId 'PSLinear.UserNotFound' -Category ObjectNotFound -TargetObject $missing))
        }
        foreach ($user in $selection.Selected) { $user }
    }
}
