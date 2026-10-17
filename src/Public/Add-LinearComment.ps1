function Add-LinearComment {
    <#
    .SYNOPSIS
        Adds a comment to a Linear issue or project, or replies to a comment.

    .DESCRIPTION
        Adds a comment, written in Markdown, and returns it.

        Give the issue by identifier (ENG-123), UUID or URL, the project by name, slug id, URL or
        id, or pipe in issues and projects. To reply, use -ReplyTo with a comment id, or pipe in
        PSLinear.Comment objects. Linear threads are one level deep, so a reply to a reply is
        added to the same thread.

        -Attachment uploads files and adds them to the end of the comment: images are shown in
        the comment, other files as links. Uploads are private (only workspace members can open
        them) unless -Public, which uploads images to a public URL and warns about it.

        With -WhatIf nothing is sent to Linear, not even the project or comment lookups.

    .PARAMETER Issue
        The issue identifier (ENG-123), UUID or URL.

    .PARAMETER Project
        A project name, slug id (the hex suffix of its URL), URL or id.

    .PARAMETER InputObject
        PSLinear.Issue or PSLinear.Project objects to comment on, or PSLinear.Comment objects to
        reply to.

    .PARAMETER ReplyTo
        The id of the comment to reply to.

    .PARAMETER Body
        The comment text, in Markdown. Optional when -Attachment is given.

    .PARAMETER Attachment
        Files to upload and add to the comment. Wildcards are supported.

    .PARAMETER Public
        Uploads -Attachment images to a public URL that anyone with the link can open, instead of
        a private one. Only PNG, JPEG, GIF, WebP, BMP and TIFF images can be public.

    .EXAMPLE
        Add-LinearComment ENG-123 'Deployed to staging.'

        Comments on an issue.

    .EXAMPLE
        Add-LinearComment -Issue ENG-123 -Body (Get-Content ./notes.md -Raw)

        Comments with the contents of a Markdown file.

    .EXAMPLE
        Add-LinearComment ENG-123 'The dialog after the fix:' -Attachment ./before.png, ./after.png

        Comments with two screenshots shown in the comment.

    .EXAMPLE
        Get-LinearComment ENG-123 | Select-Object -Last 1 | Add-LinearComment -Body 'Thanks, fixed.'

        Replies to the latest comment on an issue.

    .EXAMPLE
        Get-LinearIssue -Label Flaky -All | Add-LinearComment -Body 'Tracking in ENG-500.' -WhatIf

        Shows which issues would get the comment, without sending anything.

    .INPUTS
        PSLinear.Issue
        PSLinear.Project
        PSLinear.Comment

    .OUTPUTS
        PSLinear.Comment

    .LINK
        Get-LinearComment

    .LINK
        Set-LinearComment

    .LINK
        Add-LinearAttachment
    #>
    [CmdletBinding(DefaultParameterSetName = 'Issue', SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PSLinear.Comment')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Issue')]
        [ValidateNotNullOrEmpty()]
        [string] $Issue,

        [Parameter(Mandatory, ParameterSetName = 'Project')]
        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [object] $InputObject,

        [Parameter(Mandatory, ParameterSetName = 'Reply')]
        [ValidateNotNullOrEmpty()]
        [string] $ReplyTo,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Body,

        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Attachment,

        [switch] $Public
    )

    begin {
        if (-not $Body -and -not $Attachment) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message 'Specify -Body, -Attachment or both.' `
                        -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }
        if ($Public -and -not $Attachment) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message '-Public applies to -Attachment files; give -Attachment too.' `
                        -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }
    }

    process {
        $replyToObject = $null
        if ($PSCmdlet.ParameterSetName -eq 'ByObject' -and @($InputObject.PSObject.TypeNames) -contains 'PSLinear.Comment') {
            $replyToObject = $InputObject
        }
        $isReply = $PSCmdlet.ParameterSetName -eq 'Reply' -or $null -ne $replyToObject

        try {
            $targetName = if ($PSCmdlet.ParameterSetName -eq 'Reply') {
                "comment $ReplyTo"
            }
            elseif ($null -ne $replyToObject) {
                "comment $($replyToObject.Id) on $(Get-LinearNestedValue -InputObject $replyToObject -Name 'Target')"
            }
            else {
                (Get-LinearCommentTarget -Issue $Issue -Project $Project -InputObject $InputObject).Name
            }

            $files = @(if ($Attachment) { Resolve-LinearUploadFile -Path $Attachment })
            if ($Public) {
                foreach ($file in $files) {
                    $contentType = Get-LinearContentType -Path $file.Name
                    if (-not (Test-LinearPublicImage -ContentType $contentType)) {
                        throw (New-LinearErrorRecord -Message "'$($file.Name)' is $contentType; only PNG, JPEG, GIF, WebP, BMP and TIFF images can be uploaded to a public URL." `
                                -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument -TargetObject $file.FullName)
                    }
                }
            }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $action = if ($isReply) { 'Reply' } else { 'Add comment' }
        $summary = @{}
        if ($Body) { $summary['Body'] = $Body }
        if ($files.Count -gt 0) { $summary['Attachment'] = @($files.Name) }
        $changes = Format-LinearChangeList -BoundParameters $summary -Name 'Body', 'Attachment'
        if (-not $PSCmdlet.ShouldProcess($targetName, "$action ($changes)")) {
            return
        }

        $commentInput = @{}
        if ($isReply) {
            $parent = $replyToObject
            if ($null -eq $parent) {
                $lookup = Get-LinearCommentById -Id $ReplyTo
                if ($null -eq $lookup.Comment) {
                    $message = Format-LinearFailureMessage -Message "Comment '$ReplyTo' was not found." -Errors $lookup.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.CommentNotFound' -Category ObjectNotFound -TargetObject $ReplyTo))
                    return
                }
                $parent = $lookup.Comment
            }
            # Linear threads are one level deep: a reply to a reply belongs to the same thread. The
            # parent also tells which issue or project the reply is on.
            $parentId = Get-LinearNestedValue -InputObject $parent -Name 'ParentId'
            $commentInput['parentId'] = if ($parentId) { $parentId } else { $parent.Id }
            $issueId = Get-LinearNestedValue -InputObject $parent -Name 'IssueId'
            $projectId = Get-LinearNestedValue -InputObject $parent -Name 'ProjectId'
            if ($issueId) { $commentInput['issueId'] = $issueId }
            elseif ($projectId) { $commentInput['projectId'] = $projectId }
        }
        else {
            try {
                $target = Get-LinearCommentTarget -Issue $Issue -Project $Project -InputObject $InputObject -Resolve
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }
            $commentInput[$(if ($target.Kind -eq 'Issue') { 'issueId' } else { 'projectId' })] = $target.Id
        }

        # Uploaded files go at the end of the comment, one per line.
        $parts = [System.Collections.Generic.List[string]]::new()
        if ($Body) { $parts.Add($Body) }
        foreach ($file in $files) {
            if ($Public) {
                Write-Warning "'$($file.Name)' is uploaded to a public URL that anyone with the link can open without signing in."
            }
            try {
                $upload = Invoke-LinearFileUpload -File $file -Public:$Public
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }
            $parts.Add($upload.Markdown)
        }
        $commentInput['body'] = $parts -join "`n`n"

        $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateComment') -Variables @{ input = $commentInput } -IncludeErrors
        $comment = Get-LinearNestedValue -InputObject $result.Data -Name 'commentCreate.comment'
        if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'commentCreate.success') -or $null -eq $comment) {
            $message = Format-LinearFailureMessage -Message "Linear did not add the comment to $targetName." -Errors $result.Errors
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.CommentCreateFailed' -Category WriteError -TargetObject $targetName))
            return
        }
        ConvertTo-LinearComment -InputObject $comment
    }
}
