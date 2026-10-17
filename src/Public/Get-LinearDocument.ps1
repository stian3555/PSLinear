function Get-LinearDocument {
    <#
    .SYNOPSIS
        Gets Linear documents.

    .DESCRIPTION
        Returns documents, the most recently updated first: every document you can see, or those
        of an issue, project, initiative or team. Use -Title to filter by title; wildcards are
        supported, and a title without wildcards that matches nothing writes a non-terminating
        error. Lists leave Content empty.

        Use -Id, or pipe in documents, to get the full document with its Markdown content. Pipe
        in issues, projects, initiatives or teams to list their documents.

    .PARAMETER Title
        One or more document titles. Wildcards are supported.

    .PARAMETER Issue
        Only documents of this issue: an identifier (ENG-123), UUID or URL.

    .PARAMETER Project
        Only documents of this project: a name, slug id, URL or id.

    .PARAMETER Initiative
        Only documents of this initiative: a name, slug id, URL or id.

    .PARAMETER Team
        Only documents of this team: a team key, name or id. Supports tab completion once
        connected.

    .PARAMETER First
        Returns only this many documents, the most recently updated first.

    .PARAMETER IncludeArchived
        Also returns archived and trashed documents.

    .PARAMETER Id
        One or more document ids, slug ids (the hex suffix of a document URL) or document URLs.
        Returns the full documents.

    .PARAMETER InputObject
        PSLinear.Document objects to get in full, or PSLinear.Issue, PSLinear.Project,
        PSLinear.Initiative or PSLinear.Team objects to list the documents of.

    .EXAMPLE
        Get-LinearDocument -Project Website

        Lists a project's documents.

    .EXAMPLE
        Get-LinearDocument -Project Website -Title 'Launch plan' | Get-LinearDocument | Select-Object -ExpandProperty Content

        Shows the content of a document.

    .EXAMPLE
        Get-LinearDocument -First 10

        Lists the ten most recently updated documents.

    .EXAMPLE
        Get-LinearIssue ENG-123 | Get-LinearDocument

        Lists an issue's documents.

    .INPUTS
        PSLinear.Document
        PSLinear.Issue
        PSLinear.Project
        PSLinear.Initiative
        PSLinear.Team

    .OUTPUTS
        PSLinear.Document

    .LINK
        New-LinearDocument

    .LINK
        Set-LinearDocument

    .LINK
        Remove-LinearDocument
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType('PSLinear.Document')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'List')]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Title,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string] $Issue,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string] $Initiative,

        [Parameter(ParameterSetName = 'List')]
        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [Parameter(ParameterSetName = 'List')]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $First,

        [Parameter(ParameterSetName = 'List')]
        [switch] $IncludeArchived,

        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [object[]] $InputObject
    )

    process {
        $references = [System.Collections.Generic.List[string]]::new()
        $containers = [System.Collections.Generic.List[object]]::new()
        if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($value in $Id) { $references.Add((ConvertFrom-LinearDocumentUrl -Value $value)) }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ByObject') {
            try {
                foreach ($object in $InputObject) {
                    if ($null -eq $object) { continue }
                    if (@($object.PSObject.TypeNames) -contains 'PSLinear.Document') { $references.Add($object.Id) }
                    else { $containers.Add((Get-LinearDocumentContainer -InputObject $object)) }
                }
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }
        }

        foreach ($reference in $references) {
            $result = Get-LinearDocumentDetail -Id $reference
            if ($null -eq $result.Document) {
                $message = Format-LinearFailureMessage -Message "Document '$reference' was not found." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.DocumentNotFound' -Category ObjectNotFound -TargetObject $reference))
                continue
            }
            ConvertTo-LinearDocument -InputObject $result.Document
        }

        $query = Get-LinearGraphQLDocument -Name 'ListDocuments'
        foreach ($container in $containers) {
            $filter = @{ ($container.Field -replace 'Id$') = @{ id = @{ eq = $container.Id } } }
            Invoke-LinearPagedRequest -Query $query -ConnectionPath 'documents' -Variables @{ filter = $filter } -Limit 0 | ConvertTo-LinearDocument
        }
        if ($PSCmdlet.ParameterSetName -ne 'List') { return }

        try {
            # Every container given narrows the list; Linear accepts issue identifiers in the filter.
            $conditions = @(
                if ($Issue) { @{ issue = @{ id = @{ eq = (ConvertTo-LinearIssueIdentifier -Value $Issue) } } } }
                if ($Project) { @{ project = @{ id = @{ eq = (Resolve-LinearProjectId -Project $Project) } } } }
                if ($Initiative) { @{ initiative = @{ id = @{ eq = (Resolve-LinearInitiativeId -Initiative $Initiative) } } } }
                if ($Team) { @{ team = @{ id = @{ eq = (Resolve-LinearTeamId -Team $Team) } } } }
            )
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $variables = @{ includeArchived = [bool]$IncludeArchived }
        if ($conditions.Count -eq 1) { $variables['filter'] = $conditions[0] }
        elseif ($conditions.Count -gt 1) { $variables['filter'] = @{ and = $conditions } }

        if (-not $Title) {
            $limit = if ($First) { $First } else { 0 }
            Invoke-LinearPagedRequest -Query $query -ConnectionPath 'documents' -Variables $variables -Limit $limit | ConvertTo-LinearDocument
            return
        }

        # Titles are matched here, so fetch every document first and apply -First afterwards.
        $documents = @(Invoke-LinearPagedRequest -Query $query -ConnectionPath 'documents' -Variables $variables -Limit 0 | ConvertTo-LinearDocument)
        $selection = Select-LinearObjectByName -InputObject $documents -Name $Title -Property 'Title'
        foreach ($missing in $selection.Missing) {
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message "Document '$missing' was not found." `
                        -ErrorId 'PSLinear.DocumentNotFound' -Category ObjectNotFound -TargetObject $missing))
        }
        $selected = @($selection.Selected)
        if ($First) { $selected = @($selected | Select-Object -First $First) }
        foreach ($document in $selected) { $document }
    }
}
