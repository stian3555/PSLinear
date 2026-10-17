function Remove-LinearComment {
    <#
    .SYNOPSIS
        Deletes Linear comments.

    .DESCRIPTION
        Deletes comments, given by id or piped in from Get-LinearComment. Deleting a comment
        cannot be undone. The command asks for confirmation for each comment; use
        -Confirm:$false to skip that, or -WhatIf to see what would happen without sending
        anything.

        A missing comment, or one Linear refuses to delete, writes a non-terminating error and
        the remaining comments are still processed. Nothing is returned.

    .PARAMETER Id
        One or more comment ids.

    .PARAMETER InputObject
        PSLinear.Comment objects, typically from Get-LinearComment.

    .EXAMPLE
        Remove-LinearComment -Id 3f2a9c1e-0000-4000-8000-000000000000

        Deletes a comment, after asking for confirmation.

    .EXAMPLE
        Get-LinearComment ENG-123 | Where-Object Author -EQ 'GitHub' | Remove-LinearComment -WhatIf

        Shows which comments from the GitHub integration would be deleted.

    .INPUTS
        System.String
        PSLinear.Comment

    .OUTPUTS
        None

    .LINK
        Get-LinearComment
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Comment')]
        [object[]] $InputObject
    )

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($commentId in $Id) { [pscustomobject]@{ Id = $commentId; Name = "comment $commentId" } }
        }
        else {
            foreach ($comment in $InputObject) {
                $target = Get-LinearNestedValue -InputObject $comment -Name 'Target'
                [pscustomobject]@{ Id = $comment.Id; Name = "comment $($comment.Id)$(if ($target) { " on $target" })" }
            }
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, 'Delete comment')) {
                continue
            }

            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'DeleteComment') -Variables @{ id = $target.Id } -IncludeErrors
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'commentDelete.success')) {
                $message = Format-LinearFailureMessage -Message "Linear did not delete $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.CommentDeleteFailed' -Category WriteError -TargetObject $target.Id))
            }
        }
    }
}
