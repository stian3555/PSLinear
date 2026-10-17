function New-LinearProjectUpdate {
    <#
    .SYNOPSIS
        Posts a status update on a Linear project.

    .DESCRIPTION
        Posts a project update with a health (OnTrack, AtRisk or OffTrack) and a Markdown body,
        and returns it. The project's health in Linear follows its latest update. Give -Body,
        -Health or both: without -Health, Linear records the update as OnTrack, whatever the
        previous update said; without -Body, the update has no text. With -WhatIf nothing is
        sent, not even the project lookup.

    .PARAMETER Project
        A project name, slug id, URL or id. Binds from the SlugId property of piped
        PSLinear.Project objects.

    .PARAMETER Body
        The update text, in Markdown.

    .PARAMETER Health
        The project's health: OnTrack, AtRisk or OffTrack.

    .EXAMPLE
        New-LinearProjectUpdate -Project Website 'Design review done; build starts Monday.' -Health OnTrack

        Posts an on-track update.

    .EXAMPLE
        Get-LinearProject Website | New-LinearProjectUpdate -Health AtRisk -Body (Get-Content ./status.md -Raw)

        Posts an update from a Markdown file.

    .INPUTS
        PSLinear.Project

    .OUTPUTS
        PSLinear.ProjectUpdate

    .LINK
        Get-LinearProjectUpdate

    .LINK
        Set-LinearProjectUpdate
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PSLinear.ProjectUpdate')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('SlugId')]
        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Body,

        [ValidateSet('OnTrack', 'AtRisk', 'OffTrack')]
        [string] $Health
    )

    begin {
        if (-not $Body -and -not $Health) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message 'Specify -Body, -Health or both.' -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }
        $action = if ($Health) { "Post project update (health $Health)" } else { 'Post project update' }
    }

    process {
        if (-not $PSCmdlet.ShouldProcess("project '$Project'", $action)) {
            return
        }

        try {
            $projectId = Resolve-LinearProjectId -Project $Project
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        # Linear rejects an update without a body, but accepts an empty one.
        $updateInput = @{ projectId = $projectId; body = $(if ($Body) { $Body } else { '' }) }
        if ($Health) { $updateInput['health'] = $script:HealthMap[$Health] }

        $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateProjectUpdate') -Variables @{ input = $updateInput } -IncludeErrors
        $update = Get-LinearNestedValue -InputObject $result.Data -Name 'projectUpdateCreate.projectUpdate'
        if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'projectUpdateCreate.success') -or $null -eq $update) {
            $message = Format-LinearFailureMessage -Message "Linear did not post the update on project '$Project'." -Errors $result.Errors
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.ProjectUpdateCreateFailed' -Category WriteError -TargetObject $Project))
            return
        }
        ConvertTo-LinearProjectUpdate -InputObject $update
    }
}
