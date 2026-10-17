function Set-LinearInitiativeUpdate {
    <#
    .SYNOPSIS
        Edits initiative status updates.

    .DESCRIPTION
        Changes the body or health of initiative updates given by id or piped in from
        Get-LinearInitiativeUpdate. Nothing is returned unless you use -PassThru.

        A missing update, or a change Linear rejects, writes a non-terminating error and the
        remaining updates are still processed. With -WhatIf nothing is sent.

    .PARAMETER Id
        One or more initiative update ids.

    .PARAMETER InputObject
        PSLinear.InitiativeUpdate objects, typically from Get-LinearInitiativeUpdate.

    .PARAMETER Body
        The new text, in Markdown.

    .PARAMETER Health
        The new health: OnTrack, AtRisk or OffTrack.

    .PARAMETER PassThru
        Returns the edited initiative updates.

    .EXAMPLE
        Get-LinearInitiativeUpdate -Initiative 'Q1 growth' -First 1 | Set-LinearInitiativeUpdate -Health AtRisk

        Changes the health of an initiative's latest update.

    .INPUTS
        System.String
        PSLinear.InitiativeUpdate

    .OUTPUTS
        PSLinear.InitiativeUpdate

    .LINK
        Get-LinearInitiativeUpdate

    .LINK
        Remove-LinearInitiativeUpdate
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('PSLinear.InitiativeUpdate')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.InitiativeUpdate')]
        [object[]] $InputObject,

        [ValidateNotNullOrEmpty()]
        [string] $Body,

        [ValidateSet('OnTrack', 'AtRisk', 'OffTrack')]
        [string] $Health,

        [switch] $PassThru
    )

    begin {
        $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name 'Body', 'Health'
        if (-not $changes) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message 'Specify -Body, -Health or both.' -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }
        $updateInput = @{}
        if ($Body) { $updateInput['body'] = $Body }
        if ($Health) { $updateInput['health'] = $script:HealthMap[$Health] }
        $updateQuery = Get-LinearGraphQLDocument -Name 'UpdateInitiativeUpdate'
    }

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($updateId in $Id) { [pscustomobject]@{ Id = $updateId; Name = "initiative update $updateId" } }
        }
        else {
            foreach ($update in $InputObject) {
                $initiativeName = Get-LinearNestedValue -InputObject $update -Name 'Initiative'
                [pscustomobject]@{ Id = $update.Id; Name = "initiative update $($update.Id)$(if ($initiativeName) { " on $initiativeName" })" }
            }
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, "Edit initiative update ($changes)")) {
                continue
            }
            $result = Invoke-LinearRequest -Query $updateQuery -Variables @{ id = $target.Id; input = $updateInput } -IncludeErrors
            $updated = Get-LinearNestedValue -InputObject $result.Data -Name 'initiativeUpdateUpdate.initiativeUpdate'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'initiativeUpdateUpdate.success') -or $null -eq $updated) {
                $message = Format-LinearFailureMessage -Message "Linear did not edit $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.InitiativeUpdateUpdateFailed' -Category WriteError -TargetObject $target.Id))
                continue
            }
            if ($PassThru) {
                ConvertTo-LinearInitiativeUpdate -InputObject $updated
            }
        }
    }
}
