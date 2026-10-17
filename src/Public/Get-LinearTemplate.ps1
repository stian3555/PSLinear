function Get-LinearTemplate {
    <#
    .SYNOPSIS
        Gets the issue, project and document templates in the Linear workspace.

    .DESCRIPTION
        Returns the templates in the workspace, sorted by type and name. With -Team, only the
        workspace templates and that team's templates are returned, which are the ones
        New-LinearIssue -Template can use for the team. Use -Name to filter; wildcards are
        supported. A name without wildcards that matches no template writes a non-terminating
        error.

        The Content property holds the Markdown a template fills in.

    .PARAMETER Name
        One or more template names. Wildcards are supported.

    .PARAMETER Type
        Template types: Issue, Project or Document.

    .PARAMETER Team
        The team key (ENG), name or id. Accepts PSLinear.Team objects from the pipeline.
        Supports tab completion once connected.

    .EXAMPLE
        Get-LinearTemplate -Type Issue -Team ENG

        Lists the issue templates the ENG team can use.

    .EXAMPLE
        Get-LinearTemplate -Name 'Bug report' | Select-Object -ExpandProperty Content

        Shows what the Bug report template fills in.

    .INPUTS
        System.String
        PSLinear.Team

    .OUTPUTS
        PSLinear.Template

    .LINK
        New-LinearIssue
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Template')]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name,

        [ValidateSet('Issue', 'Project', 'Document')]
        [string[]] $Type,

        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('Key')]
        [ValidateNotNullOrEmpty()]
        [string] $Team
    )

    begin {
        $requested = [System.Collections.Generic.List[string]]::new()
        $teamValue = $null
    }

    process {
        if ($Name) { $requested.AddRange([string[]]$Name) }
        if ($Team) { $teamValue = $Team }
    }

    end {
        try {
            $teamId = if ($teamValue) { Resolve-LinearTeamId -Team $teamValue } else { $null }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $templates = @(Get-LinearTemplateCache -Refresh | Where-Object {
                $null -ne $_ -and
                (-not $Type -or $_.Type -in $Type) -and
                (-not $teamId -or $null -eq $_.TeamId -or $_.TeamId -eq $teamId)
            })

        if ($requested.Count -eq 0) {
            foreach ($template in $templates) { $template }
            return
        }

        $selection = Select-LinearObjectByName -InputObject $templates -Name $requested -Property 'Name'
        foreach ($missing in $selection.Missing) {
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message "Template '$missing' was not found." `
                        -ErrorId 'PSLinear.TemplateNotFound' -Category ObjectNotFound -TargetObject $missing))
        }
        foreach ($template in $selection.Selected) { $template }
    }
}
