function Get-LinearIssueRelation {
    <#
    .SYNOPSIS
        Gets the relations between a Linear issue and other issues.

    .DESCRIPTION
        Returns every relation of an issue, in both directions, seen from that issue: Blocks,
        BlockedBy, Related, DuplicateOf (the issue is a duplicate of the other), DuplicatedBy
        (the other issue is a duplicate of this one) or Similar. Each relation names the other
        issue with its title and state.

        Give issues by identifier (ENG-123), UUID or URL, or pipe them in. A missing issue writes
        a non-terminating error and the remaining issues are still processed.

    .PARAMETER Issue
        One or more issue identifiers (ENG-123), UUIDs or issue URLs.

    .PARAMETER InputObject
        PSLinear.Issue objects, typically from Get-LinearIssue.

    .PARAMETER Type
        Only relations of these types: Blocks, BlockedBy, Related, DuplicateOf, DuplicatedBy or
        Similar.

    .EXAMPLE
        Get-LinearIssueRelation ENG-123

        Lists the relations of an issue.

    .EXAMPLE
        Get-LinearIssue -Assignee me -StateType Unstarted, Started | Get-LinearIssueRelation -Type BlockedBy |
            Where-Object RelatedState -NE 'Done'

        Lists what is still blocking your open issues.

    .INPUTS
        System.String
        PSLinear.Issue

    .OUTPUTS
        PSLinear.IssueRelation

    .LINK
        Add-LinearIssueRelation

    .LINK
        Remove-LinearIssueRelation
    #>
    [CmdletBinding(DefaultParameterSetName = 'Issue')]
    [OutputType('PSLinear.IssueRelation')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'Issue')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Issue,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Issue')]
        [object[]] $InputObject,

        [ValidateSet('Blocks', 'BlockedBy', 'Related', 'DuplicateOf', 'DuplicatedBy', 'Similar')]
        [string[]] $Type
    )

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'Issue') { Get-LinearIssueTarget -Id $Issue } else { Get-LinearIssueTarget -InputObject $InputObject }
        foreach ($target in $targets) {
            $result = Get-LinearIssueRelationList -Issue $target.Id
            if ($result.Errors.Count -gt 0) {
                $message = Format-LinearFailureMessage -Message "Issue '$($target.Name)' was not found." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.IssueNotFound' -Category ObjectNotFound -TargetObject $target.Name))
                continue
            }
            $relations = @($result.Relations | Where-Object { -not $Type -or $_.Type -in $Type })
            foreach ($relation in $relations) { $relation }
        }
    }
}
