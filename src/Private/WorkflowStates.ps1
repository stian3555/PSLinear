function Get-LinearWorkflowStateCache {
    <#
    .SYNOPSIS
        Returns the workflow states of one team in workflow order, cached for a few minutes.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.WorkflowState')]
    param(
        [Parameter(Mandatory)]
        [string] $TeamId,

        [switch] $Refresh
    )

    $entry = $script:LinearWorkflowStateCache[$TeamId]
    if ($Refresh -or $null -eq $entry -or [datetime]::UtcNow -ge $entry.Expires) {
        $query = Get-LinearGraphQLDocument -Name 'ListWorkflowStates'
        $variables = @{ filter = @{ team = @{ id = @{ eq = $TeamId } } } }
        $states = @(Invoke-LinearPagedRequest -Query $query -ConnectionPath 'workflowStates' -Limit 0 -Variables $variables |
                ConvertTo-LinearWorkflowState |
                Sort-Object -Property { $script:WorkflowStateTypeOrder[[string]$_.Type] }, Position)
        $entry = @{ Items = $states; Expires = [datetime]::UtcNow.Add($script:CacheLifetime) }
        $script:LinearWorkflowStateCache[$TeamId] = $entry
    }
    $entry.Items
}

function Resolve-LinearWorkflowStateId {
    <#
    .SYNOPSIS
        Resolves a workflow state name (In Progress) or id to the state's id within one team.
    .NOTES
        Throws an ErrorRecord (PSLinear.StateNotFound) that callers rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $TeamId,

        [Parameter(Mandatory)]
        [string] $State
    )

    if (Test-LinearGuid -Value $State) { return $State }

    foreach ($refresh in $false, $true) {
        $match = @(Get-LinearWorkflowStateCache -TeamId $TeamId -Refresh:$refresh | Where-Object { $null -ne $_ -and $_.Name -eq $State })
        if ($match.Count -gt 0) { return $match[0].Id }
    }

    $available = Format-LinearValueList -Value (Get-LinearWorkflowStateCache -TeamId $TeamId | Where-Object { $null -ne $_ } | ForEach-Object Name)
    throw (New-LinearErrorRecord -Message "State '$State' was not found in team $(Get-LinearTeamKey -TeamId $TeamId). Valid states: $available." `
            -ErrorId 'PSLinear.StateNotFound' -Category ObjectNotFound -TargetObject $State)
}
