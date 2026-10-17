function Remove-LinearDocument {
    <#
    .SYNOPSIS
        Moves Linear documents to the trash.

    .DESCRIPTION
        Moves documents, given by id, slug id or URL or piped in from Get-LinearDocument, to the
        trash, which is what deleting a document does in the Linear app. Trashed documents can be
        restored from the trash in Linear. The command asks for confirmation for each document;
        use -Confirm:$false to skip that, or -WhatIf to see what would happen without sending
        anything.

        A missing document, or one Linear refuses to remove, writes a non-terminating error and
        the remaining documents are still processed. Nothing is returned.

        To restore a trashed document outside the Linear app, run:
        Invoke-LinearGraphQL -Query 'mutation($id: String!) { documentUnarchive(id: $id) { success } }' -Variables @{ id = '<document id>' }

    .PARAMETER Id
        One or more document ids, slug ids (the hex suffix of a document URL) or document URLs.

    .PARAMETER InputObject
        PSLinear.Document objects, typically from Get-LinearDocument.

    .EXAMPLE
        Get-LinearDocument -Project Website -Title 'Old draft' | Remove-LinearDocument

        Moves a document to the trash, after asking for confirmation.

    .INPUTS
        System.String
        PSLinear.Document

    .OUTPUTS
        None

    .LINK
        Get-LinearDocument

    .LINK
        New-LinearDocument
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Document')]
        [object[]] $InputObject
    )

    process {
        foreach ($target in (Get-LinearDocumentTarget -Id $Id -InputObject $InputObject)) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, 'Move document to the trash')) {
                continue
            }
            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'DeleteDocument') -Variables @{ id = $target.Id } -IncludeErrors
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'documentDelete.success')) {
                $message = Format-LinearFailureMessage -Message "Linear did not move $($target.Name) to the trash." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.DocumentDeleteFailed' -Category WriteError -TargetObject $target.Id))
            }
        }
    }
}
