function Remove-LinearIssueRelation {
    <#
    .SYNOPSIS
        Removes relations between Linear issues.

    .DESCRIPTION
        Removes relations given by id, piped in from Get-LinearIssueRelation, or named by the
        two issues: -Issue and -RelatedIssue remove every relation between them, in either
        direction, or only those of -Type.

        The command asks for confirmation; use -Confirm:$false to skip that, or -WhatIf to see
        what would happen without sending anything (for -Issue and -RelatedIssue the matching
        relations are then not looked up). A missing relation, or one Linear refuses to remove,
        writes a non-terminating error and the remaining input is still processed. Nothing is
        returned.

    .PARAMETER Id
        One or more relation ids.

    .PARAMETER InputObject
        PSLinear.IssueRelation objects, typically from Get-LinearIssueRelation.

    .PARAMETER Issue
        One of the two related issues: identifier (ENG-123), UUID or URL.

    .PARAMETER RelatedIssue
        The other issue: identifier, UUID or URL.

    .PARAMETER Type
        With -Issue and -RelatedIssue, only remove relations of this type, seen from -Issue:
        Blocks, BlockedBy, Related, DuplicateOf, DuplicatedBy or Similar.

    .EXAMPLE
        Remove-LinearIssueRelation -Issue ENG-123 -RelatedIssue ENG-124

        Removes every relation between two issues, after asking.

    .EXAMPLE
        Get-LinearIssueRelation ENG-123 -Type BlockedBy | Where-Object RelatedState -EQ 'Canceled' | Remove-LinearIssueRelation -Confirm:$false

        Removes blockers that were canceled, without asking.

    .INPUTS
        System.String
        PSLinear.IssueRelation

    .OUTPUTS
        None

    .LINK
        Get-LinearIssueRelation

    .LINK
        Add-LinearIssueRelation
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.IssueRelation')]
        [object[]] $InputObject,

        [Parameter(Mandatory, ParameterSetName = 'Between')]
        [ValidateNotNullOrEmpty()]
        [string] $Issue,

        [Parameter(Mandatory, ParameterSetName = 'Between')]
        [ValidateNotNullOrEmpty()]
        [string] $RelatedIssue,

        [Parameter(ParameterSetName = 'Between')]
        [ValidateSet('Blocks', 'BlockedBy', 'Related', 'DuplicateOf', 'DuplicatedBy', 'Similar')]
        [string] $Type
    )

    begin {
        $deleteQuery = Get-LinearGraphQLDocument -Name 'DeleteIssueRelation'
    }

    process {
        $targets = switch ($PSCmdlet.ParameterSetName) {
            'ById' {
                foreach ($relationId in $Id) { [pscustomobject]@{ Id = $relationId; Name = "relation $relationId" } }
            }
            'ByObject' {
                foreach ($relation in $InputObject) {
                    $from = Get-LinearNestedValue -InputObject $relation -Name 'Issue'
                    $kind = Get-LinearNestedValue -InputObject $relation -Name 'Type'
                    $to = Get-LinearNestedValue -InputObject $relation -Name 'RelatedIssue'
                    [pscustomobject]@{ Id = $relation.Id; Name = "relation $from $kind $to" }
                }
            }
            'Between' {
                $issueId = ConvertTo-LinearIssueIdentifier -Value $Issue
                $relatedId = ConvertTo-LinearIssueIdentifier -Value $RelatedIssue
                $description = if ($Type) { "$Type relations" } else { 'relations' }
                if (-not $PSCmdlet.ShouldProcess("$issueId and $relatedId", "Remove $description")) {
                    return
                }

                $result = Get-LinearIssueRelationList -Issue $issueId
                if ($result.Errors.Count -gt 0) {
                    $message = Format-LinearFailureMessage -Message "Issue '$issueId' was not found." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.IssueNotFound' -Category ObjectNotFound -TargetObject $issueId))
                    return
                }
                $matching = @($result.Relations | Where-Object {
                        ($_.RelatedIssue -eq $relatedId -or $_.RelatedIssueId -eq $relatedId) -and (-not $Type -or $_.Type -eq $Type)
                    })
                if ($matching.Count -eq 0) {
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message "$issueId has no $description with $relatedId." `
                                -ErrorId 'PSLinear.RelationNotFound' -Category ObjectNotFound -TargetObject $relatedId))
                    return
                }
                # Already confirmed above for the pair, so the matches are deleted without asking again.
                foreach ($relation in $matching) {
                    [pscustomobject]@{ Id = $relation.Id; Name = "relation $($relation.Issue) $($relation.Type) $($relation.RelatedIssue)"; Confirmed = $true }
                }
            }
        }

        foreach ($target in $targets) {
            $confirmed = [bool](Get-LinearNestedValue -InputObject $target -Name 'Confirmed')
            if (-not $confirmed -and -not $PSCmdlet.ShouldProcess($target.Name, 'Remove relation')) {
                continue
            }
            $result = Invoke-LinearRequest -Query $deleteQuery -Variables @{ id = $target.Id } -IncludeErrors
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'issueRelationDelete.success')) {
                $message = Format-LinearFailureMessage -Message "Linear did not remove $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.RelationDeleteFailed' -Category WriteError -TargetObject $target.Id))
            }
        }
    }
}
