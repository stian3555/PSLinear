function New-LinearDocument {
    <#
    .SYNOPSIS
        Creates a Linear document.

    .DESCRIPTION
        Creates a document in an issue, a project, an initiative or a team, and returns it with
        its content. A document belongs to exactly one of them. Give it with -Issue, -Project,
        -Initiative or -Team, or pipe in the issue, project, initiative or team. Names are
        resolved to ids for you; an unknown name stops the command with an error that lists the
        valid values. With -WhatIf nothing is sent, not even the name lookups.

    .PARAMETER Title
        The document title.

    .PARAMETER Content
        The document content, in Markdown.

    .PARAMETER Issue
        The issue: an identifier (ENG-123), UUID or URL.

    .PARAMETER Project
        The project: a name, slug id, URL or id.

    .PARAMETER Initiative
        The initiative: a name, slug id, URL or id.

    .PARAMETER Team
        The team: a team key, name or id. Supports tab completion once connected.

    .PARAMETER InputObject
        A PSLinear.Issue, PSLinear.Project, PSLinear.Initiative or PSLinear.Team object to create
        the document in.

    .PARAMETER Owner
        The document owner: 'me', an email address, a user id, or the user's full name or display
        name. Without it, Linear makes you the owner.

    .EXAMPLE
        New-LinearDocument 'Launch plan' -Project Website -Content (Get-Content ./launch-plan.md -Raw)

        Creates a project document from a Markdown file.

    .EXAMPLE
        Get-LinearIssue ENG-123 | New-LinearDocument 'Investigation notes' "## Findings`n- ..."

        Creates a document on an issue.

    .EXAMPLE
        New-LinearDocument 'On-call handbook' -Team OPS -Owner me

        Creates a team document that you own.

    .INPUTS
        PSLinear.Issue
        PSLinear.Project
        PSLinear.Initiative
        PSLinear.Team

    .OUTPUTS
        PSLinear.Document

    .LINK
        Get-LinearDocument

    .LINK
        Set-LinearDocument
    #>
    [CmdletBinding(DefaultParameterSetName = 'Project', SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PSLinear.Document')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Title,

        [Parameter(Position = 1)]
        [string] $Content,

        [Parameter(Mandatory, ParameterSetName = 'Issue')]
        [ValidateNotNullOrEmpty()]
        [string] $Issue,

        [Parameter(Mandatory, ParameterSetName = 'Project')]
        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [Parameter(Mandatory, ParameterSetName = 'Initiative')]
        [ValidateNotNullOrEmpty()]
        [string] $Initiative,

        [Parameter(Mandatory, ParameterSetName = 'Team')]
        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [object] $InputObject,

        [ValidateNotNullOrEmpty()]
        [string] $Owner
    )

    process {
        try {
            $container = Get-LinearDocumentContainer -Issue $Issue -Project $Project -Initiative $Initiative -Team $Team -InputObject $InputObject
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
        $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name 'Content', 'Owner'
        $action = if ($changes) { "Create document '$Title' ($changes)" } else { "Create document '$Title'" }
        if (-not $PSCmdlet.ShouldProcess($container.Name, $action)) {
            return
        }

        try {
            if (-not $container.Id) {
                $container = Get-LinearDocumentContainer -Issue $Issue -Project $Project -Initiative $Initiative -Team $Team -Resolve
            }
            $documentInput = @{ title = $Title }
            $documentInput[$container.Field] = $container.Id
            if ($PSBoundParameters.ContainsKey('Content')) { $documentInput['content'] = $Content }
            if ($Owner) { $documentInput['ownerId'] = Resolve-LinearUserId -User $Owner }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateDocument') -Variables @{ input = $documentInput } -IncludeErrors
        $document = Get-LinearNestedValue -InputObject $result.Data -Name 'documentCreate.document'
        if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'documentCreate.success') -or $null -eq $document) {
            $message = Format-LinearFailureMessage -Message "Linear did not create document '$Title' in $($container.Name)." -Errors $result.Errors
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.DocumentCreateFailed' -Category WriteError -TargetObject $Title))
            return
        }
        ConvertTo-LinearDocument -InputObject $document
    }
}
