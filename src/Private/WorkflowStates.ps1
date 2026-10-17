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
        Resolves a workflow state name (In Progress), state type (started) or id to a state id within one team.
    .DESCRIPTION
        A name match wins. Otherwise a state type (triage, backlog, unstarted, started, completed,
        canceled, duplicate) resolves to the team's first state of that type, which lets one
        command work across teams whose states have different names.
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

    $isStateType = $script:WorkflowStateTypeOrder.ContainsKey($State)
    foreach ($refresh in $false, $true) {
        $states = @(Get-LinearWorkflowStateCache -TeamId $TeamId -Refresh:$refresh | Where-Object { $null -ne $_ })
        $match = @($states | Where-Object { $_.Name -eq $State })
        if ($match.Count -gt 0) { return $match[0].Id }
        if ($isStateType) {
            # The cache is in workflow order, so the first state of the type has the lowest position.
            $match = @($states | Where-Object { $_.Type -eq $State })
            if ($match.Count -gt 0) { return $match[0].Id }
        }
    }

    $states = @(Get-LinearWorkflowStateCache -TeamId $TeamId | Where-Object { $null -ne $_ })
    $available = Format-LinearValueList -Value ($states | ForEach-Object Name)
    $types = ($states | ForEach-Object Type | Select-Object -Unique) -join ', '
    throw (New-LinearErrorRecord -Message "State '$State' was not found in team $(Get-LinearTeamKey -TeamId $TeamId). Valid states: $available; state types: $types." `
            -ErrorId 'PSLinear.StateNotFound' -Category ObjectNotFound -TargetObject $State)
}
