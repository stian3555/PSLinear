function Remove-LinearIssue {
    <#
    .SYNOPSIS
        Archives Linear issues, or moves them to the trash with -Delete.

    .DESCRIPTION
        By default, archives the issues: they disappear from views but keep their history
        and can be restored at any time. With -Delete, the issues are moved to the trash
        instead, where they can be restored for 30 days before Linear deletes them for good.

        Issues are given by identifier (ENG-123) or piped in from Get-LinearIssue. The
        command asks for confirmation for each issue; use -Confirm:$false to skip that, or
        -WhatIf to see what would happen without sending anything.

        A missing issue, or one Linear refuses to archive or delete, writes a non-terminating
        error and the remaining issues are still processed. Nothing is returned.

        To restore an archived issue outside the Linear app, run:
        Invoke-LinearGraphQL -Query 'mutation($id: String!) { issueUnarchive(id: $id) { success } }' -Variables @{ id = 'ENG-123' }

    .PARAMETER Id
        One or more issue identifiers (ENG-123) or UUIDs.

    .PARAMETER InputObject
        PSLinear.Issue objects to remove, typically from Get-LinearIssue.

    .PARAMETER Delete
        Moves the issues to the trash instead of archiving them. Trashed issues can be
        restored in Linear for 30 days.

    .EXAMPLE
        Remove-LinearIssue ENG-123

        Archives one issue, after asking for confirmation.

    .EXAMPLE
        Get-LinearIssue -Team ENG -StateType Canceled -All | Remove-LinearIssue -Confirm:$false

        Archives every canceled issue in the team without prompting.

    .EXAMPLE
        Remove-LinearIssue ENG-124, ENG-125 -Delete -WhatIf

        Shows which issues would be moved to the trash, without changing them.

    .INPUTS
        System.String
        PSLinear.Issue

    .OUTPUTS
        None

    .LINK
        Get-LinearIssue

    .LINK
        Set-LinearIssue
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

        [switch] $Delete
    )

    begin {
        if ($Delete) {
            $query = Get-LinearGraphQLDocument -Name 'DeleteIssue'
            $successPath = 'issueDelete.success'
            $action = 'Delete issue (move it to the trash for 30 days)'
            $failureVerb = 'delete'
            $errorId = 'PSLinear.IssueDeleteFailed'
        }
        else {
            $query = Get-LinearGraphQLDocument -Name 'ArchiveIssue'
            $successPath = 'issueArchive.success'
            $action = 'Archive issue'
            $failureVerb = 'archive'
            $errorId = 'PSLinear.IssueArchiveFailed'
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
