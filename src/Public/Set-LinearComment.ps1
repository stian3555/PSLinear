function Set-LinearComment {
    <#
    .SYNOPSIS
        Edits a Linear comment, or resolves or reopens its thread.

    .DESCRIPTION
        Changes the text of comments, given by id or piped in from Get-LinearComment, and
        resolves (-Resolved $true) or reopens (-Resolved $false) their threads. Nothing is
        returned unless you use -PassThru.

        Linear resolves a whole thread on its first comment. Resolving through a reply resolves
        the reply's thread and records that reply as the resolution, as the Linear app does.

        A missing comment, or a change Linear rejects, writes a non-terminating error and the
        remaining comments are still processed.

    .PARAMETER Id
        One or more comment ids.

    .PARAMETER InputObject
        PSLinear.Comment objects, typically from Get-LinearComment.

    .PARAMETER Body
        The new comment text, in Markdown.

    .PARAMETER Resolved
        $true resolves the comment's thread, $false reopens it.

    .PARAMETER PassThru
        Returns the updated comments. After resolving or reopening through a reply, that is the
        first comment of the thread, which carries the resolved state.

    .EXAMPLE
        Set-LinearComment -Id 3f2a9c1e-0000-4000-8000-000000000000 -Body 'Fixed a typo.'

        Edits a comment.

    .EXAMPLE
        Get-LinearComment ENG-123 | Where-Object { -not $_.IsReply -and -not $_.Resolved } | Set-LinearComment -Resolved $true

        Resolves every open thread on an issue.

    .EXAMPLE
        Get-LinearComment ENG-123 | Where-Object Resolved | Set-LinearComment -Resolved $false -WhatIf

        Shows which threads would be reopened, without changing them.

    .INPUTS
        System.String
        PSLinear.Comment

    .OUTPUTS
        PSLinear.Comment

    .LINK
        Get-LinearComment

    .LINK
        Remove-LinearComment
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('PSLinear.Comment')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Comment')]
        [object[]] $InputObject,

        [ValidateNotNullOrEmpty()]
        [string] $Body,

        [bool] $Resolved,

        [switch] $PassThru
    )

    begin {
        $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name 'Body', 'Resolved'
        if (-not $changes) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message 'Specify -Body, -Resolved or both.' `
                        -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }
        $setBody = $PSBoundParameters.ContainsKey('Body')
        $setResolved = $PSBoundParameters.ContainsKey('Resolved')
    }

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($commentId in $Id) { [pscustomobject]@{ Id = $commentId; Name = "comment $commentId"; Comment = $null } }
        }
        else {
            foreach ($comment in $InputObject) {
                $target = Get-LinearNestedValue -InputObject $comment -Name 'Target'
                [pscustomobject]@{ Id = $comment.Id; Name = "comment $($comment.Id)$(if ($target) { " on $target" })"; Comment = $comment }
            }
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, "Update comment ($changes)")) {
                continue
            }

            $updated = $null
            if ($setBody) {
                $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'UpdateComment') `
                    -Variables @{ id = $target.Id; input = @{ body = $Body } } -IncludeErrors
                $updated = Get-LinearNestedValue -InputObject $result.Data -Name 'commentUpdate.comment'
                if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'commentUpdate.success') -or $null -eq $updated) {
                    $message = Format-LinearFailureMessage -Message "Linear did not update $($target.Name)." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.CommentUpdateFailed' -Category WriteError -TargetObject $target.Id))
                    continue
                }
            }

            if ($setResolved) {
                # Threads are resolved on their first comment, so a reply needs its parent's id.
                $known = if ($null -ne $updated) { ConvertTo-LinearComment -InputObject $updated } else { $target.Comment }
                if ($null -eq $known) {
                    $lookup = Get-LinearCommentById -Id $target.Id
                    if ($null -eq $lookup.Comment) {
                        $message = Format-LinearFailureMessage -Message "Comment '$($target.Id)' was not found." -Errors $lookup.Errors
                        $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.CommentNotFound' -Category ObjectNotFound -TargetObject $target.Id))
                        continue
                    }
                    $known = $lookup.Comment
                }
                $parentId = Get-LinearNestedValue -InputObject $known -Name 'ParentId'
                $threadId = if ($parentId) { $parentId } else { $target.Id }

                if ($Resolved) {
                    $operation = 'ResolveComment'
                    $field = 'commentResolve'
                    $variables = @{ id = $threadId }
                    if ($parentId) { $variables['resolvingCommentId'] = $target.Id }
                }
                else {
                    $operation = 'UnresolveComment'
                    $field = 'commentUnresolve'
                    $variables = @{ id = $threadId }
                }
                $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name $operation) -Variables $variables -IncludeErrors
                $updated = Get-LinearNestedValue -InputObject $result.Data -Name "$field.comment"
                if (-not (Get-LinearNestedValue -InputObject $result.Data -Name "$field.success") -or $null -eq $updated) {
                    $verb = if ($Resolved) { 'resolve' } else { 'reopen' }
                    $message = Format-LinearFailureMessage -Message "Linear did not $verb the thread of $($target.Name)." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.CommentUpdateFailed' -Category WriteError -TargetObject $target.Id))
                    continue
                }
            }

            if ($PassThru) {
                ConvertTo-LinearComment -InputObject $updated
            }
        }
    }
}
