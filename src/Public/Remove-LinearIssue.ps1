function Remove-LinearIssue {
    <#
    .SYNOPSIS
        Moves Linear issues to the trash, or archives them with -Archive.

    .DESCRIPTION
        By default, moves the issues to the trash, which is what deleting an issue does in
        the Linear app. Trashed issues can be restored from the trash in Linear for 30 days,
        after which Linear deletes them for good.

        With -Archive, the issues are archived instead. Linear normally archives closed
        issues by itself and offers no manual archive in the app; archiving by hand skips
        the checks Linear's auto-archive makes (such as open sub-issues), and archived
        issues disappear from lists and search. Prefer closing an issue with
        Set-LinearIssue -State, or trashing it, unless you need it out of the way without
        either.

        Issues are given by identifier (ENG-123) or piped in from Get-LinearIssue.
        The command asks for confirmation for each issue; use -Confirm:$false to skip that,
        or -WhatIf to see what would happen without sending anything.

        A missing issue, or one Linear refuses to remove, writes a non-terminating error and
        the remaining issues are still processed. Nothing is returned.

        To restore an archived issue outside the Linear app, run:
        Invoke-LinearGraphQL -Query 'mutation($id: String!) { issueUnarchive(id: $id) { success } }' -Variables @{ id = 'ENG-123' }

    .PARAMETER Id
        One or more issue identifiers (ENG-123) or UUIDs.

    .PARAMETER InputObject
        PSLinear.Issue objects to remove, typically from Get-LinearIssue.

    .PARAMETER Archive
        Archives the issues instead of moving them to the trash.

    .EXAMPLE
        Remove-LinearIssue ENG-123

        Moves one issue to the trash, after asking for confirmation.

    .EXAMPLE
        Get-LinearIssue -Team ENG -Label Spam -All | Remove-LinearIssue -Confirm:$false

        Moves every issue with the Spam label to the trash without prompting.

    .EXAMPLE
        Remove-LinearIssue ENG-124, ENG-125 -Archive -WhatIf

        Shows which issues would be archived, without changing them.

    .INPUTS
        System.String
        PSLinear.Issue

    .OUTPUTS
        None

    .LINK
        Get-LinearIssue

    .LINK
        Set-LinearIssue

    .LINK
        https://linear.app/docs/delete-archive-issues
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [Alias('Identifier')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Issue')]
        [object[]] $InputObject,

        [switch] $Archive
    )

    begin {
        if ($Archive) {
            $query = Get-LinearGraphQLDocument -Name 'ArchiveIssue'
            $successPath = 'issueArchive.success'
            $action = 'Archive issue'
            $failureVerb = 'archive'
            $errorId = 'PSLinear.IssueArchiveFailed'
        }
        else {
            $query = Get-LinearGraphQLDocument -Name 'DeleteIssue'
            $successPath = 'issueDelete.success'
            $action = 'Move issue to the trash (restorable for 30 days)'
            $failureVerb = 'delete'
            $errorId = 'PSLinear.IssueDeleteFailed'
        }
    }

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            Get-LinearIssueTarget -Id $Id
        }
        else {
            Get-LinearIssueTarget -InputObject $InputObject
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, $action)) {
                continue
            }

            $result = Invoke-LinearRequest -Query $query -Variables @{ id = $target.Id } -IncludeErrors
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name $successPath)) {
                $message = Format-LinearFailureMessage -Message "Linear did not $failureVerb issue '$($target.Name)'." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId $errorId -Category WriteError -TargetObject $target.Name))
            }
        }
    }
}
