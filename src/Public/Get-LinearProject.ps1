function Get-LinearProject {
    <#
    .SYNOPSIS
        Gets projects in the Linear workspace.

    .DESCRIPTION
        Returns the workspace's projects, sorted by name, with their status, health, lead, teams,
        labels, dates and progress. Use -Name to filter; wildcards are supported. A name without
        wildcards that matches no project writes a non-terminating error. -Team and -Status
        narrow the list further; an unknown team or status stops the command with an error that
        lists the valid values.

        Use -Id, or pipe in projects, to get the full project: its content (the long Markdown
        description), every team, label and member, and its initiatives. Lists leave Content,
        Members and Initiatives empty.

        The list also refreshes the cache that other commands use to resolve -Project.

    .PARAMETER Name
        One or more project names. Wildcards are supported.

    .PARAMETER Team
        Only projects of this team: a team key, name or id. Supports tab completion once
        connected.

    .PARAMETER Status
        Only projects with these statuses: a status name (In Progress), a status type (backlog,
        planned, started, paused, completed, canceled) that matches every status of that type,
        or a status id.

    .PARAMETER IncludeArchived
        Also returns archived projects.

    .PARAMETER Id
        One or more project ids, slug ids (the hex suffix of a project URL) or project URLs.
        Returns the full projects, including archived and trashed ones.

    .PARAMETER InputObject
        PSLinear.Project objects, typically from Get-LinearProject. Returns them again in full.

    .EXAMPLE
        Get-LinearProject

        Lists the projects.

    .EXAMPLE
        Get-LinearProject -Team ENG -Status started | Sort-Object TargetDate

        Lists ENG's projects in progress, the soonest target date first.

    .EXAMPLE
        Get-LinearProject -Name 'Website*' | Format-List

        Shows every property of the projects whose names start with 'Website'.

    .EXAMPLE
        Get-LinearProject Website | Get-LinearProject | Select-Object -ExpandProperty Content

        Shows the full content of a project.

    .EXAMPLE
        Get-LinearProject -Id https://linear.app/acme/project/website-a1b2c3d4e5f6

        Gets a project from its URL.

    .INPUTS
        System.String
        PSLinear.Project

    .OUTPUTS
        PSLinear.Project

    .LINK
        New-LinearProject

    .LINK
        Set-LinearProject

    .LINK
        Get-LinearProjectUpdate
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType('PSLinear.Project')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ParameterSetName = 'List')]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Status,

        [Parameter(ParameterSetName = 'List')]
        [switch] $IncludeArchived,

        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Project')]
        [object[]] $InputObject
    )

    begin {
        $requestedNames = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'List') {
            if ($Name) { $requestedNames.AddRange([string[]]$Name) }
            return
        }

        $references = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($value in $Id) { ConvertFrom-LinearProjectUrl -Value $value }
        }
        else {
            foreach ($project in $InputObject) { $project.Id }
        }
        foreach ($reference in $references) {
            $result = Get-LinearProjectDetail -Id $reference
            if ($null -eq $result.Project) {
                $message = Format-LinearFailureMessage -Message "Project '$reference' was not found." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.ProjectNotFound' -Category ObjectNotFound -TargetObject $reference))
                continue
            }
            ConvertTo-LinearProject -InputObject $result.Project
        }
    }

    end {
        if ($PSCmdlet.ParameterSetName -ne 'List') { return }

        try {
            $teamId = if ($Team) { Resolve-LinearTeamId -Team $Team } else { $null }
            $statusIds = @(foreach ($value in $Status) {
                    if (Test-LinearGuid -Value $value) { $value } else { Find-LinearProjectStatus -Status $value | ForEach-Object Id }
                })
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $projects = if ($IncludeArchived) { @(Get-LinearProjectList -IncludeArchived) } else { @(Get-LinearProjectCache -Refresh) }
        if ($teamId) {
            $projects = @($projects | Where-Object { $null -ne $_ -and $_.TeamIds -contains $teamId })
        }
        if ($statusIds.Count -gt 0) {
            $projects = @($projects | Where-Object { $null -ne $_ -and $_.StatusId -in $statusIds })
        }

        if ($requestedNames.Count -eq 0) {
            foreach ($project in $projects) { $project }
            return
        }

        $selection = Select-LinearObjectByName -InputObject $projects -Name $requestedNames -Property 'Name'
        foreach ($missing in $selection.Missing) {
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message "Project '$missing' was not found." `
                        -ErrorId 'PSLinear.ProjectNotFound' -Category ObjectNotFound -TargetObject $missing))
        }
        foreach ($project in $selection.Selected) { $project }
    }
}
