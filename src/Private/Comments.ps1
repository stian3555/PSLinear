function Get-LinearCommentTarget {
    <#
    .SYNOPSIS
        Works out what a comment command acts on: an issue, a project, an initiative or a document.
    .DESCRIPTION
        Returns [pscustomobject]@{ Kind; Id; Name; ContentId }. Kind is Issue, Project, Initiative
        or Document, Id is what the API accepts (an issue identifier or UUID, a project or
        initiative UUID, a document id or slug id) and Name is for messages. ContentId is the
        document content id that new comments on a document are attached to.

        Without -Resolve no request is sent, so it is safe before ShouldProcess; a project or
        initiative given by name then has no Id yet, and a document given as text no ContentId.
        With -Resolve, names, slug ids and URLs are resolved and documents are looked up.
    .NOTES
        Throws an ErrorRecord (PSLinear.InvalidArgument, or the project and initiative resolvers'
        errors) that callers rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Issue,

        [string] $Project,

        [string] $Initiative,

        [string] $Document,

        [AllowNull()]
        [object] $InputObject,

        [switch] $Resolve
    )

    if ($Issue) {
        $identifier = ConvertTo-LinearIssueIdentifier -Value $Issue
        return [pscustomobject]@{ Kind = 'Issue'; Id = $identifier; Name = $identifier }
    }

    if ($Project) {
        $projectId = if ($Resolve) { Resolve-LinearProjectId -Project $Project } else { $null }
        return [pscustomobject]@{ Kind = 'Project'; Id = $projectId; Name = "project '$Project'" }
    }

    if ($Initiative) {
        $initiativeId = if ($Resolve) { Resolve-LinearInitiativeId -Initiative $Initiative } else { $null }
        return [pscustomobject]@{ Kind = 'Initiative'; Id = $initiativeId; Name = "initiative '$Initiative'" }
    }

    if ($Document) {
        $reference = ConvertFrom-LinearDocumentUrl -Value $Document
        $contentId = $null
        if ($Resolve) {
            $detail = Get-LinearDocumentDetail -Id $reference
            if ($null -eq $detail.Document) {
                $message = Format-LinearFailureMessage -Message "Document '$Document' was not found." -Errors $detail.Errors
                throw (New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.DocumentNotFound' -Category ObjectNotFound -TargetObject $Document)
            }
            $contentId = Get-LinearNestedValue -InputObject $detail.Document -Name 'documentContentId'
        }
        return [pscustomobject]@{ Kind = 'Document'; Id = $reference; Name = "document $reference"; ContentId = $contentId }
    }

    if ($null -ne $InputObject) {
        $typeNames = @($InputObject.PSObject.TypeNames)
        $objectId = Get-LinearNestedValue -InputObject $InputObject -Name 'Id'
        if ($typeNames -contains 'PSLinear.Issue') {
            $identifier = Get-LinearNestedValue -InputObject $InputObject -Name 'Identifier'
            return [pscustomobject]@{ Kind = 'Issue'; Id = $objectId; Name = $(if ($identifier) { $identifier } else { $objectId }) }
        }
        if ($typeNames -contains 'PSLinear.Project') {
            $name = Get-LinearNestedValue -InputObject $InputObject -Name 'Name'
            return [pscustomobject]@{ Kind = 'Project'; Id = $objectId; Name = "project '$(if ($name) { $name } else { $objectId })'" }
        }
        if ($typeNames -contains 'PSLinear.Initiative') {
            $name = Get-LinearNestedValue -InputObject $InputObject -Name 'Name'
            return [pscustomobject]@{ Kind = 'Initiative'; Id = $objectId; Name = "initiative '$(if ($name) { $name } else { $objectId })'" }
        }
        if ($typeNames -contains 'PSLinear.Document') {
            $title = Get-LinearNestedValue -InputObject $InputObject -Name 'Title'
            return [pscustomobject]@{
                Kind      = 'Document'
                Id        = $objectId
                Name      = "document '$(if ($title) { $title } else { $objectId })'"
                ContentId = Get-LinearNestedValue -InputObject $InputObject -Name 'DocumentContentId'
            }
        }
    }

    throw (New-LinearErrorRecord -Message ('Comments belong to an issue, a project, an initiative or a document. Use -Issue, -Project, ' +
            '-Initiative or -Document, or pipe in PSLinear.Issue, PSLinear.Project, PSLinear.Initiative or PSLinear.Document objects.') `
            -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument -TargetObject $InputObject)
}

function Get-LinearCommentList {
    <#
    .SYNOPSIS
        Fetches every comment on an issue, project, initiative or document, thread by thread.
    .DESCRIPTION
        Returns [pscustomobject]@{ Comments; Errors }. Threads are ordered by their first comment,
        oldest first, and each thread's replies follow its first comment in the order they were
        written, as the Linear app shows them. Errors holds the GraphQL errors when the issue or
        document does not exist, so the caller can write one non-terminating error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Target
    )

    $result = if ($Target.Kind -eq 'Issue') {
        Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListIssueComments') -ConnectionPath 'issue.comments' `
            -Variables @{ id = $Target.Id } -Limit 0 -IncludeErrors
    }
    elseif ($Target.Kind -eq 'Document') {
        Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListDocumentComments') -ConnectionPath 'document.comments' `
            -Variables @{ id = $Target.Id } -Limit 0 -IncludeErrors
    }
    else {
        $field = if ($Target.Kind -eq 'Initiative') { 'initiative' } else { 'project' }
        $filter = @{ $field = @{ id = @{ eq = $Target.Id } } }
        Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListComments') -ConnectionPath 'comments' `
            -Variables @{ filter = $filter } -Limit 0 -IncludeErrors
    }

    $comments = @($result.Nodes | ConvertTo-LinearComment)
    $threadStarts = @{}
    foreach ($comment in $comments) {
        if (-not $comment.IsReply) { $threadStarts[$comment.Id] = $comment.CreatedAt }
    }
    # A reply whose first comment is not in the list (deleted) sorts by its own time.
    $threadStart = { if ($threadStarts.ContainsKey($_.ThreadId)) { $threadStarts[$_.ThreadId] } else { $_.CreatedAt } }

    [pscustomobject]@{
        Comments = @($comments | Sort-Object -Property $threadStart, ThreadId, IsReply, CreatedAt)
        Errors   = $result.Errors
    }
}

function Get-LinearCommentById {
    <#
    .SYNOPSIS
        Fetches one comment. Returns [pscustomobject]@{ Comment; Errors }, so a missing comment
        can be written as one non-terminating error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Id
    )

    $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'GetComment') -Variables @{ id = $Id } -IncludeErrors
    [pscustomobject]@{
        Comment = Get-LinearNestedValue -InputObject $result.Data -Name 'comment' | ConvertTo-LinearComment
        Errors  = $result.Errors
    }
}
