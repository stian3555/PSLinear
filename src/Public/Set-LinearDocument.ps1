function Set-LinearDocument {
    <#
    .SYNOPSIS
        Changes Linear documents.

    .DESCRIPTION
        Updates documents given by id, slug id or URL, or piped in from Get-LinearDocument:
        their title, content or owner, or moves them to another issue, project, initiative or
        team (a moved document leaves its current one). Nothing is returned unless you use
        -PassThru.

        -Content replaces the whole document. To append, read the current content first (see the
        examples).

        A missing document, or a change Linear rejects, writes a non-terminating error and the
        remaining documents are still processed. With -WhatIf nothing is sent, not even the name
        lookups.

    .PARAMETER Id
        One or more document ids, slug ids (the hex suffix of a document URL) or document URLs.

    .PARAMETER InputObject
        PSLinear.Document objects, typically from Get-LinearDocument.

    .PARAMETER Title
        The new title.

    .PARAMETER Content
        The new content, in Markdown. It replaces the current content; an empty string clears it.

    .PARAMETER Owner
        The new owner: 'me', an email address, a user id, or the user's full name or display name.

    .PARAMETER Issue
        Moves the documents to this issue: an identifier (ENG-123), UUID or URL.

    .PARAMETER Project
        Moves the documents to this project: a name, slug id, URL or id.

    .PARAMETER Initiative
        Moves the documents to this initiative: a name, slug id, URL or id.

    .PARAMETER Team
        Moves the documents to this team: a team key, name or id. Supports tab completion once
        connected.

    .PARAMETER Clear
        Removes values: Owner.

    .PARAMETER PassThru
        Returns the updated documents, with their content.

    .EXAMPLE
        Get-LinearDocument -Project Website -Title 'Launch plan' | Set-LinearDocument -Title 'Launch plan (v2)'

        Renames a document.

    .EXAMPLE
        $document = Get-LinearDocument -Id 419202a9d18c
        Set-LinearDocument -Id $document.Id -Content ($document.Content + "`n`n## Update`nShipped.")

        Appends a section to a document.

    .EXAMPLE
        Set-LinearDocument -Id https://linear.app/acme/document/launch-plan-419202a9d18c -Project 'Mobile App' -PassThru

        Moves a document to another project and returns it.

    .INPUTS
        System.String
        PSLinear.Document

    .OUTPUTS
        PSLinear.Document

    .LINK
        Get-LinearDocument

    .LINK
        Remove-LinearDocument
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('PSLinear.Document')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Document')]
        [object[]] $InputObject,

        [ValidateNotNullOrEmpty()]
        [string] $Title,

        [string] $Content,

        [ValidateNotNullOrEmpty()]
        [string] $Owner,

        [ValidateNotNullOrEmpty()]
        [string] $Issue,

        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [ValidateNotNullOrEmpty()]
        [string] $Initiative,

        [ValidateNotNullOrEmpty()]
        [string] $Team,

        [ValidateSet('Owner')]
        [string[]] $Clear,

        [switch] $PassThru
    )

    begin {
        $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name 'Title', 'Content', 'Owner', 'Issue', 'Project', 'Initiative', 'Team', 'Clear'
        $moves = @(foreach ($kind in 'Issue', 'Project', 'Initiative', 'Team') { if ($PSBoundParameters.ContainsKey($kind)) { $kind } })
        $invalidMessage = if ($moves.Count -gt 1) {
            "A document belongs to one issue, project, initiative or team. Use only one of -$($moves -join ', -')."
        }
        elseif ($Clear -contains 'Owner' -and $Owner) {
            'Use either -Clear Owner or -Owner, not both.'
        }
        elseif (-not $changes) {
            'Specify at least one change, such as -Title, -Content or -Project.'
        }
        if ($invalidMessage) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message $invalidMessage -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }
        $updateQuery = Get-LinearGraphQLDocument -Name 'UpdateDocument'
        $documentInput = $null
    }

    process {
        $targets = Get-LinearDocumentTarget -Id $Id -InputObject $InputObject

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, "Update document ($changes)")) {
                continue
            }

            # Names are the same for every document, so resolve them once.
            if ($null -eq $documentInput) {
                try {
                    $documentInput = @{}
                    if ($PSBoundParameters.ContainsKey('Title')) { $documentInput['title'] = $Title }
                    if ($PSBoundParameters.ContainsKey('Content')) { $documentInput['content'] = $Content }
                    if ($Owner) { $documentInput['ownerId'] = Resolve-LinearUserId -User $Owner }
                    if ($Clear -contains 'Owner') { $documentInput['ownerId'] = $null }
                    if ($moves.Count -eq 1) {
                        $container = Get-LinearDocumentContainer -Issue $Issue -Project $Project -Initiative $Initiative -Team $Team -Resolve
                        $documentInput[$container.Field] = $container.Id
                    }
                }
                catch {
                    $documentInput = $null
                    $PSCmdlet.ThrowTerminatingError($_)
                }
            }

            $result = Invoke-LinearRequest -Query $updateQuery -Variables @{ id = $target.Id; input = $documentInput } -IncludeErrors
            $updated = Get-LinearNestedValue -InputObject $result.Data -Name 'documentUpdate.document'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'documentUpdate.success') -or $null -eq $updated) {
                $message = Format-LinearFailureMessage -Message "Linear did not update $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.DocumentUpdateFailed' -Category WriteError -TargetObject $target.Id))
                continue
            }
            if ($PassThru) {
                ConvertTo-LinearDocument -InputObject $updated
            }
        }
    }
}
