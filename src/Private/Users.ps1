function Get-LinearUserCache {
    <#
    .SYNOPSIS
        Returns the active users in the workspace, cached for a few minutes. Used for name resolution.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.User')]
    param(
        [switch] $Refresh
    )

    if ($Refresh -or $null -eq $script:LinearUserCache -or [datetime]::UtcNow -ge $script:LinearUserCacheExpires) {
        $query = Get-LinearGraphQLDocument -Name 'ListUsers'
        $script:LinearUserCache = @(Invoke-LinearPagedRequest -Query $query -ConnectionPath 'users' -Limit 0 |
                ForEach-Object { ConvertTo-LinearUser -InputObject $_ } |
                Sort-Object -Property Name)
        $script:LinearUserCacheExpires = [datetime]::UtcNow.Add($script:CacheLifetime)
    }
    $script:LinearUserCache
}

function Get-LinearViewerId {
    <#
    .SYNOPSIS
        Returns the authenticated user's id, asking Linear once when the connection does not know it yet.
    .NOTES
        Connect-Linear stores the id. An implicit connection from LINEAR_API_KEY does not, so the
        first lookup stores it in the context.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $context = Get-LinearContext
    if ([string]::IsNullOrEmpty($context.UserId)) {
        $data = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'Viewer')
        $context.UserId = Get-LinearNestedValue -InputObject $data -Name 'viewer.id'
    }
    $context.UserId
}

function Resolve-LinearUserId {
    <#
    .SYNOPSIS
        Resolves 'me', an email address, a user id, or a full or display name to the user's id.
    .NOTES
        Throws an ErrorRecord (PSLinear.UserNotFound or PSLinear.AmbiguousUser) that callers
        rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $User
    )

    if ($User -eq 'me') { return Get-LinearViewerId }
    if (Test-LinearGuid -Value $User) { return $User }

    $isEmail = $User -match '@'
    $match = @()
    foreach ($refresh in $false, $true) {
        $match = @(Get-LinearUserCache -Refresh:$refresh | Where-Object {
                $null -ne $_ -and (($isEmail -and $_.Email -eq $User) -or (-not $isEmail -and ($_.Name -eq $User -or $_.DisplayName -eq $User)))
            })
        if ($match.Count -gt 0) { break }
    }

    if ($match.Count -eq 1) { return $match[0].Id }
    if ($match.Count -gt 1) {
        $matchList = ($match | ForEach-Object { "$($_.Name) <$($_.Email)>" }) -join ', '
        throw (New-LinearErrorRecord -Message "User '$User' is ambiguous. Use the email address or id instead. Matches: $matchList." `
                -ErrorId 'PSLinear.AmbiguousUser' -Category InvalidArgument -TargetObject $User)
    }

    $available = Format-LinearValueList -Value (Get-LinearUserCache | Where-Object { $null -ne $_ } | ForEach-Object { "$($_.Name) <$($_.Email)>" })
    throw (New-LinearErrorRecord -Message "User '$User' was not found among active users. Valid users: $available." `
            -ErrorId 'PSLinear.UserNotFound' -Category ObjectNotFound -TargetObject $User)
}
