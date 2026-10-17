function Get-LinearMilestoneCache {
    <#
    .SYNOPSIS
        Returns the milestones of one project, in their order in the project, cached for a few minutes.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Milestone')]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectId,

        [switch] $Refresh
    )

    $entry = $script:LinearMilestoneCache[$ProjectId]
    if ($Refresh -or $null -eq $entry -or [datetime]::UtcNow -ge $entry.Expires) {
        $variables = @{ filter = @{ project = @{ id = @{ eq = $ProjectId } } } }
        $milestones = @(Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListProjectMilestones') -ConnectionPath 'projectMilestones' -Limit 0 -Variables $variables |
                ConvertTo-LinearMilestone |
                Sort-Object -Property SortOrder)
        $entry = @{ Items = $milestones; Expires = [datetime]::UtcNow.Add($script:CacheLifetime) }
        $script:LinearMilestoneCache[$ProjectId] = $entry
    }
    $entry.Items
}

function Resolve-LinearMilestoneId {
    <#
    .SYNOPSIS
        Resolves a milestone name or id to a milestone id within one project.
    .NOTES
        Throws an ErrorRecord (PSLinear.MilestoneNotFound) that callers rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ProjectId,

        [Parameter(Mandatory)]
        [string] $Milestone
    )

    if (Test-LinearGuid -Value $Milestone) { return $Milestone }

    $milestones = @()
    foreach ($refresh in $false, $true) {
        $milestones = @(Get-LinearMilestoneCache -ProjectId $ProjectId -Refresh:$refresh | Where-Object { $null -ne $_ })
        $match = @($milestones | Where-Object Name -EQ $Milestone)
        if ($match.Count -gt 0) { return $match[0].Id }
    }

    $project = Get-LinearProjectCache | Where-Object { $null -ne $_ -and $_.Id -eq $ProjectId } | Select-Object -First 1
    $projectName = if ($null -ne $project) { "'$($project.Name)'" } else { $ProjectId }
    $message = if ($milestones.Count -eq 0) {
        "Project $projectName has no milestones."
    }
    else {
        "Milestone '$Milestone' was not found in project $projectName. Valid milestones: $(Format-LinearValueList -Value ($milestones | ForEach-Object Name))."
    }
    throw (New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.MilestoneNotFound' -Category ObjectNotFound -TargetObject $Milestone)
}
