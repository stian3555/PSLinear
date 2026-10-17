function Add-LinearIssueRelation {
    <#
    .SYNOPSIS
        Relates a Linear issue to other issues: blocks, blocked by, related or duplicate.

    .DESCRIPTION
        Creates a relation from an issue to each related issue and returns it, seen from the
        issue:

        Blocks        the issue blocks the related issue
        BlockedBy     the related issue blocks the issue
        Related       the issues are related
        DuplicateOf   the issue is a duplicate of the related issue
        DuplicatedBy  the related issue is a duplicate of the issue
        Similar       the issues are similar

        Marking an issue as a duplicate can move it to its team's duplicate state, as it does
        in the Linear app. A related issue that does not exist, or a relation Linear rejects,
        writes a non-terminating error and the remaining issues are still processed. With
        -WhatIf nothing is sent.

    .PARAMETER Issue
        The issue identifier (ENG-123), UUID or URL. Binds from the Identifier property of piped
        PSLinear.Issue objects.

    .PARAMETER Type
        How the issue relates to the related issues: Blocks, BlockedBy, Related, DuplicateOf,
        DuplicatedBy or Similar.

    .PARAMETER RelatedIssue
        One or more related issue identifiers (ENG-124), UUIDs or URLs.

    .EXAMPLE
        Add-LinearIssueRelation ENG-123 Blocks ENG-124, ENG-125

        Marks ENG-123 as blocking two issues.

    .EXAMPLE
        Add-LinearIssueRelation -Issue ENG-200 -Type DuplicateOf -RelatedIssue ENG-150

        Marks ENG-200 as a duplicate of ENG-150.

    .EXAMPLE
        Get-LinearIssue -Label 'Login' -StateType Unstarted | Add-LinearIssueRelation -Type Related -RelatedIssue ENG-300 -WhatIf

        Shows which issues would be related to ENG-300, without changing anything.

    .INPUTS
        PSLinear.Issue

    .OUTPUTS
        PSLinear.IssueRelation

    .LINK
        Get-LinearIssueRelation

    .LINK
        Remove-LinearIssueRelation
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PSLinear.IssueRelation')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('Identifier')]
        [ValidateNotNullOrEmpty()]
        [string] $Issue,

        [Parameter(Mandatory, Position = 1)]
        [ValidateSet('Blocks', 'BlockedBy', 'Related', 'DuplicateOf', 'DuplicatedBy', 'Similar')]
        [string] $Type,

        [Parameter(Mandatory, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string[]] $RelatedIssue
    )

    begin {
        $direction = Get-LinearRelationDirection -Type $Type
        $query = Get-LinearGraphQLDocument -Name 'CreateIssueRelation'
    }

    process {
        $issueId = ConvertTo-LinearIssueIdentifier -Value $Issue
        foreach ($value in $RelatedIssue) {
            $relatedId = ConvertTo-LinearIssueIdentifier -Value $value
            if (-not $PSCmdlet.ShouldProcess($issueId, "Add relation: $Type $relatedId")) {
                continue
            }

            # BlockedBy and DuplicatedBy are stored by Linear from the related issue's side.
            $relationInput = if ($direction.Swap) {
                @{ issueId = $relatedId; relatedIssueId = $issueId; type = $direction.ApiType }
            }
            else {
                @{ issueId = $issueId; relatedIssueId = $relatedId; type = $direction.ApiType }
            }
            $result = Invoke-LinearRequest -Query $query -Variables @{ input = $relationInput } -IncludeErrors
            $relation = Get-LinearNestedValue -InputObject $result.Data -Name 'issueRelationCreate.issueRelation'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'issueRelationCreate.success') -or $null -eq $relation) {
                $message = Format-LinearFailureMessage -Message "Linear did not relate $issueId ($Type) to $relatedId." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.RelationCreateFailed' -Category WriteError -TargetObject $relatedId))
                continue
            }
            ConvertTo-LinearIssueRelation -InputObject $relation -Inverse:$direction.Swap
        }
    }
}
