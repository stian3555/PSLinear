function Get-LinearProject {
    <#
    .SYNOPSIS
        Gets projects in the Linear workspace.

    .DESCRIPTION
        Returns the workspace's projects, sorted by name, with their status, lead, dates and
        progress. Use -Name to filter; wildcards are supported. A name without wildcards that
        matches no project writes a non-terminating error.

        The result also refreshes the cache that New-LinearIssue and Set-LinearIssue use to
        resolve -Project.

    .PARAMETER Name
        One or more project names. Wildcards are supported.

    .PARAMETER IncludeArchived
        Also returns archived projects.

    .EXAMPLE
        Get-LinearProject

        Lists the projects.

    .EXAMPLE
        Get-LinearProject | Where-Object Status -EQ 'In Progress' | Sort-Object TargetDate

        Lists the projects in progress, the soonest target date first.

    .EXAMPLE
        Get-LinearProject -Name 'Website*' | Format-List

        Shows every property of the projects whose names start with 'Website'.

    .INPUTS
        System.String

    .OUTPUTS
        PSLinear.Project

    .LINK
        Get-LinearIssue
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Project')]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name,

        [switch] $IncludeArchived
    )

    begin {
        $requestedNames = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($Name) { $requestedNames.AddRange([string[]]$Name) }
    }

    end {
        $projects = if ($IncludeArchived) { @(Get-LinearProjectList -IncludeArchived) } else { @(Get-LinearProjectCache -Refresh) }

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
