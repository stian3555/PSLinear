function Set-LinearProjectUpdate {
    <#
    .SYNOPSIS
        Edits project status updates.

    .DESCRIPTION
        Changes the body or health of project updates given by id or piped in from
        Get-LinearProjectUpdate. Nothing is returned unless you use -PassThru.

        A missing update, or a change Linear rejects, writes a non-terminating error and the
        remaining updates are still processed. With -WhatIf nothing is sent.

    .PARAMETER Id
        One or more project update ids.

    .PARAMETER InputObject
        PSLinear.ProjectUpdate objects, typically from Get-LinearProjectUpdate.

    .PARAMETER Body
        The new text, in Markdown.

    .PARAMETER Health
        The new health: OnTrack, AtRisk or OffTrack.

    .PARAMETER PassThru
        Returns the updated project updates.

    .EXAMPLE
        Get-LinearProjectUpdate -Project Website -First 1 | Set-LinearProjectUpdate -Health AtRisk

        Changes the health of a project's latest update.

    .EXAMPLE
        Set-LinearProjectUpdate -Id 3f2a9c1e-0000-4000-8000-000000000000 -Body 'Corrected: launch moves to May.' -PassThru

        Rewrites an update and returns it.

    .INPUTS
        System.String
        PSLinear.ProjectUpdate

    .OUTPUTS
        PSLinear.ProjectUpdate

    .LINK
        Get-LinearProjectUpdate

    .LINK
        Remove-LinearProjectUpdate
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('PSLinear.ProjectUpdate')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.ProjectUpdate')]
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
        $updateQuery = Get-LinearGraphQLDocument -Name 'UpdateProjectUpdate'
    }

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($updateId in $Id) { [pscustomobject]@{ Id = $updateId; Name = "project update $updateId" } }
        }
        else {
            foreach ($update in $InputObject) {
                $projectName = Get-LinearNestedValue -InputObject $update -Name 'Project'
                [pscustomobject]@{ Id = $update.Id; Name = "project update $($update.Id)$(if ($projectName) { " on $projectName" })" }
            }
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, "Edit project update ($changes)")) {
                continue
            }
            $result = Invoke-LinearRequest -Query $updateQuery -Variables @{ id = $target.Id; input = $updateInput } -IncludeErrors
            $updated = Get-LinearNestedValue -InputObject $result.Data -Name 'projectUpdateUpdate.projectUpdate'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'projectUpdateUpdate.success') -or $null -eq $updated) {
                $message = Format-LinearFailureMessage -Message "Linear did not edit $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.ProjectUpdateUpdateFailed' -Category WriteError -TargetObject $target.Id))
                continue
            }
            if ($PassThru) {
                ConvertTo-LinearProjectUpdate -InputObject $updated
            }
        }
    }
}
