function ConvertFrom-LinearDocumentUrl {
    <#
    .SYNOPSIS
        Returns the slug id of a document URL, or the value unchanged when it is not a document URL.
    .EXAMPLE
        ConvertFrom-LinearDocumentUrl -Value 'https://linear.app/acme/document/release-plan-419202a9d18c'
        # 419202a9d18c
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    if ($Value -match '^https?://linear\.app/[^/]+/document/(?:[^/?#]*-)?([0-9a-f]+)(?:[/?#]|$)') { return $Matches[1] }
    $Value
}

function Get-LinearDocumentDetail {
    <#
    .SYNOPSIS
        Fetches one document with its content. Accepts an id or a slug id.
    .DESCRIPTION
        Returns [pscustomobject]@{ Document; Errors }: the raw node, or $null with the GraphQL
        errors when the document does not exist.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Id
    )

    $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'GetDocument') -Variables @{ id = $Id } -IncludeErrors
    [pscustomobject]@{
        Document = Get-LinearNestedValue -InputObject $result.Data -Name 'document'
        Errors   = $result.Errors
    }
}

function Get-LinearDocumentTarget {
    <#
    .SYNOPSIS
        Describes the documents a write command acts on, without sending a request.
    .DESCRIPTION
        Returns [pscustomobject]@{ Id; Name } per document. Id is what the API accepts: an id or a
        slug id (document URLs are reduced to their slug id). Name is for messages.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $Id,

        [object[]] $InputObject
    )

    foreach ($value in $Id) {
        $reference = ConvertFrom-LinearDocumentUrl -Value $value
        [pscustomobject]@{ Id = $reference; Name = "document $reference" }
    }
    foreach ($object in $InputObject) {
        if ($null -eq $object) { continue }
        $title = Get-LinearNestedValue -InputObject $object -Name 'Title'
        [pscustomobject]@{ Id = $object.Id; Name = "document '$(if ($title) { $title } else { $object.Id })'" }
    }
}

function Get-LinearDocumentContainer {
    <#
    .SYNOPSIS
        Works out which issue, project, initiative or team a document belongs to.
    .DESCRIPTION
        Returns [pscustomobject]@{ Kind; Filter; Field; Id; Name }, or nothing when no container
        is given. Filter is the DocumentFilter field (issue, project, initiative or team). Field
        is the DocumentCreateInput or DocumentUpdateInput field (issueId or projectId), and $null
        for initiatives and teams: Linear's public API lists their documents, but no longer
        creates or moves documents into them. Id is the value for either. Name is for messages.

        -ForWrite accepts only containers that can receive documents (issues and projects).

        Without -Resolve no request is sent, so it is safe before ShouldProcess; names then have
        no Id yet. Issues need no lookup: Linear accepts identifiers such as ENG-123.
    .NOTES
        Throws an ErrorRecord (PSLinear.InvalidArgument, or the resolvers' errors) that callers
        rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Issue,

        [string] $Project,

        [AllowNull()]
        [object] $InputObject,

        [switch] $Resolve,

        [switch] $ForWrite
    )

    if ($Issue) {
        $identifier = ConvertTo-LinearIssueIdentifier -Value $Issue
        return [pscustomobject]@{ Kind = 'Issue'; Filter = 'issue'; Field = 'issueId'; Id = $identifier; Name = $identifier }
    }
    if ($Project) {
        $projectId = if ($Resolve) { Resolve-LinearProjectId -Project $Project } else { $null }
        return [pscustomobject]@{ Kind = 'Project'; Filter = 'project'; Field = 'projectId'; Id = $projectId; Name = "project '$Project'" }
    }
    if ($null -eq $InputObject) { return }

    $typeNames = @($InputObject.PSObject.TypeNames)
    $objectId = Get-LinearNestedValue -InputObject $InputObject -Name 'Id'
    $name = Get-LinearNestedValue -InputObject $InputObject -Name 'Name'
    $container = if ($typeNames -contains 'PSLinear.Issue') {
        $identifier = Get-LinearNestedValue -InputObject $InputObject -Name 'Identifier'
        [pscustomobject]@{ Kind = 'Issue'; Filter = 'issue'; Field = 'issueId'; Id = $objectId; Name = $(if ($identifier) { $identifier } else { $objectId }) }
    }
    elseif ($typeNames -contains 'PSLinear.Project') {
        [pscustomobject]@{ Kind = 'Project'; Filter = 'project'; Field = 'projectId'; Id = $objectId; Name = "project '$(if ($name) { $name } else { $objectId })'" }
    }
    elseif ($typeNames -contains 'PSLinear.Initiative') {
        [pscustomobject]@{ Kind = 'Initiative'; Filter = 'initiative'; Field = $null; Id = $objectId; Name = "initiative '$(if ($name) { $name } else { $objectId })'" }
    }
    elseif ($typeNames -contains 'PSLinear.Team') {
        $key = Get-LinearNestedValue -InputObject $InputObject -Name 'Key'
        [pscustomobject]@{ Kind = 'Team'; Filter = 'team'; Field = $null; Id = $objectId; Name = "team $(if ($key) { $key } else { $objectId })" }
    }

    $message = if ($null -eq $container -and $ForWrite) {
        'Documents are created in an issue or a project. Pipe in PSLinear.Issue or PSLinear.Project objects.'
    }
    elseif ($null -eq $container) {
        'Documents belong to an issue, a project, an initiative or a team. Pipe in PSLinear.Issue, PSLinear.Project, PSLinear.Initiative or PSLinear.Team objects.'
    }
    elseif ($ForWrite -and $null -eq $container.Field) {
        "Linear's API no longer creates documents in teams or initiatives, so $($container.Name) cannot hold a new document. Use an issue or a project."
    }
    if ($message) {
        throw (New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument -TargetObject $InputObject)
    }
    $container
}
