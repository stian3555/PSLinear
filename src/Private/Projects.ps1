function Get-LinearProjectCache {
    <#
    .SYNOPSIS
        Returns all non-archived projects, cached for a few minutes. Used for name resolution.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Project')]
    param(
        [switch] $Refresh
    )

    if ($Refresh -or $null -eq $script:LinearProjectCache -or [datetime]::UtcNow -ge $script:LinearProjectCacheExpires) {
        $script:LinearProjectCache = @(Get-LinearProjectList)
        $script:LinearProjectCacheExpires = [datetime]::UtcNow.Add($script:CacheLifetime)
    }
    $script:LinearProjectCache
}

function Get-LinearProjectList {
    <#
    .SYNOPSIS
        Fetches the workspace's projects, sorted by name. Archived projects are included only with -IncludeArchived.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Project')]
    param(
        [switch] $IncludeArchived
    )

    Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListProjects') -ConnectionPath 'projects' -Limit 0 `
        -Variables @{ includeArchived = [bool]$IncludeArchived } |
        ConvertTo-LinearProject |
        Sort-Object -Property Name
}

function Resolve-LinearProjectId {
    <#
    .SYNOPSIS
        Resolves a project id, URL, slug id (the hex suffix of its URL) or name to the project's id.
    .NOTES
        Throws an ErrorRecord (PSLinear.ProjectNotFound or PSLinear.AmbiguousProject) that callers
        rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Project
    )

    if (Test-LinearGuid -Value $Project) { return $Project }

    # https://linear.app/acme/project/mobile-launch-272f50ef9250 -> slug id 272f50ef9250
    $slugId = if ($Project -match '^https?://linear\.app/[^/]+/project/(?:[^/?#]*-)?([0-9a-f]+)(?:[/?#]|$)') { $Matches[1] } else { $Project }

    $match = @()
    foreach ($refresh in $false, $true) {
        $projects = @(Get-LinearProjectCache -Refresh:$refresh | Where-Object { $null -ne $_ })
        $match = @($projects | Where-Object { $_.SlugId -eq $slugId })
        if ($match.Count -eq 0) { $match = @($projects | Where-Object { $_.Name -eq $Project }) }
        if ($match.Count -gt 0) { break }
    }

    if ($match.Count -eq 1) { return $match[0].Id }
    if ($match.Count -gt 1) {
        $matchList = ($match | ForEach-Object { "$($_.Name) ($($_.Id))" }) -join ', '
        throw (New-LinearErrorRecord -Message "Project '$Project' is ambiguous. Use the project id instead. Matches: $matchList." `
                -ErrorId 'PSLinear.AmbiguousProject' -Category InvalidArgument -TargetObject $Project)
    }

    $available = Format-LinearValueList -Value (Get-LinearProjectCache | Where-Object { $null -ne $_ } | ForEach-Object Name)
    throw (New-LinearErrorRecord -Message "Project '$Project' was not found. Valid projects: $available." `
            -ErrorId 'PSLinear.ProjectNotFound' -Category ObjectNotFound -TargetObject $Project)
}
