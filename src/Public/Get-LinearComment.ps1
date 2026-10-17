function Get-LinearComment {
    <#
    .SYNOPSIS
        Gets the comments on a Linear issue, project or initiative.

    .DESCRIPTION
        Returns every comment on an issue, a project or an initiative, thread by thread: threads are ordered by
        their first comment, oldest first, and each thread's replies follow its first comment. A
        reply has IsReply set, and ParentId and ThreadId point at the first comment of its
        thread; a resolved thread has Resolved set on that first comment.

        Give an issue by identifier (ENG-123), UUID or URL, a project or initiative by name,
        slug id, URL or id, or pipe in issues, projects and initiatives. Use -Id to get specific
        comments.

        A missing issue or comment writes a non-terminating error and the remaining input is
        still processed.

    .PARAMETER Issue
        One or more issue identifiers (ENG-123), UUIDs or issue URLs.

    .PARAMETER Project
        A project name, slug id (the hex suffix of its URL), URL or id.

    .PARAMETER Initiative
        An initiative name, slug id (the hex suffix of its URL), URL or id.

    .PARAMETER InputObject
        PSLinear.Issue, PSLinear.Project or PSLinear.Initiative objects, typically from
        Get-LinearIssue, Get-LinearProject or Get-LinearInitiative.

    .PARAMETER Id
        One or more comment ids.

    .EXAMPLE
        Get-LinearComment ENG-123

        Lists the comments on an issue, thread by thread.

    .EXAMPLE
        Get-LinearIssue -Assignee me -State 'In Review' | Get-LinearComment | Where-Object { -not $_.IsReply -and -not $_.Resolved }

        Lists the open comment threads on your issues in review.

    .EXAMPLE
        Get-LinearComment ENG-123 | Group-Object ThreadId | ForEach-Object { $_.Group[0].Body; $_.Count - 1 }

        Shows the first comment of each thread and how many replies it has.

    .EXAMPLE
        Get-LinearComment -Project Website | Format-List Author, CreatedAt, Body

        Shows the full text of a project's comments.

    .EXAMPLE
        Get-LinearInitiative 'Q1 growth' | Get-LinearComment

        Lists the comments on an initiative.

    .INPUTS
        System.String
        PSLinear.Issue
        PSLinear.Project
        PSLinear.Initiative

    .OUTPUTS
        PSLinear.Comment

    .LINK
        Add-LinearComment

    .LINK
        Set-LinearComment

    .LINK
        Remove-LinearComment
    #>
    [CmdletBinding(DefaultParameterSetName = 'Issue')]
    [OutputType('PSLinear.Comment')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'Issue')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Issue,

        [Parameter(Mandatory, ParameterSetName = 'Project')]
        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [Parameter(Mandatory, ParameterSetName = 'Initiative')]
        [ValidateNotNullOrEmpty()]
        [string] $Initiative,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [object[]] $InputObject,

        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($commentId in $Id) {
                $result = Get-LinearCommentById -Id $commentId
                if ($null -eq $result.Comment) {
                    $message = Format-LinearFailureMessage -Message "Comment '$commentId' was not found." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.CommentNotFound' -Category ObjectNotFound -TargetObject $commentId))
                    continue
                }
                $result.Comment
            }
            return
        }

        try {
            $targets = switch ($PSCmdlet.ParameterSetName) {
                'Issue' { foreach ($value in $Issue) { Get-LinearCommentTarget -Issue $value } }
                'Project' { Get-LinearCommentTarget -Project $Project -Resolve }
                'Initiative' { Get-LinearCommentTarget -Initiative $Initiative -Resolve }
                'ByObject' { foreach ($object in $InputObject) { Get-LinearCommentTarget -InputObject $object } }
            }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        foreach ($target in $targets) {
            $result = Get-LinearCommentList -Target $target
            if ($result.Errors.Count -gt 0) {
                if ($target.Kind -eq 'Issue') {
                    $message = Format-LinearFailureMessage -Message "Issue '$($target.Name)' was not found." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.IssueNotFound' -Category ObjectNotFound -TargetObject $target.Name))
                }
                else {
                    $message = Format-LinearFailureMessage -Message "Could not get the comments on $($target.Name)." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.CommentListFailed' -Category ReadError -TargetObject $target.Name))
                }
                continue
            }
            foreach ($comment in $result.Comments) { $comment }
        }
    }
}
