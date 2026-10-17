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
        $query = Get-LinearGraphQLDocument -Name 'ListProjects'
        $script:LinearProjectCache = @(Invoke-LinearPagedRequest -Query $query -ConnectionPath 'projects' -Limit 0 |
                ConvertTo-LinearProject |
                Sort-Object -Property Name)
        $script:LinearProjectCacheExpires = [datetime]::UtcNow.Add($script:CacheLifetime)
    }
    $script:LinearProjectCache
}

function Resolve-LinearProjectId {
    <#
    .SYNOPSIS
        Resolves a project name or id to the project's id.
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

    $match = @()
    foreach ($refresh in $false, $true) {
        $match = @(Get-LinearProjectCache -Refresh:$refresh | Where-Object { $null -ne $_ -and $_.Name -eq $Project })
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
