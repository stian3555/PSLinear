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
        Works out what a document belongs to: an issue, a project, an initiative or a team.
    .DESCRIPTION
        Returns [pscustomobject]@{ Kind; Field; Id; Name }, or nothing when no container is given.
        Field is the DocumentCreateInput or DocumentUpdateInput field (issueId, projectId,
        initiativeId or teamId) and Id its value. Name is for messages.

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

        [string] $Initiative,

        [string] $Team,

        [AllowNull()]
        [object] $InputObject,

        [switch] $Resolve
    )

    if ($Issue) {
        $identifier = ConvertTo-LinearIssueIdentifier -Value $Issue
        return [pscustomobject]@{ Kind = 'Issue'; Field = 'issueId'; Id = $identifier; Name = $identifier }
    }
    if ($Project) {
        $projectId = if ($Resolve) { Resolve-LinearProjectId -Project $Project } else { $null }
        return [pscustomobject]@{ Kind = 'Project'; Field = 'projectId'; Id = $projectId; Name = "project '$Project'" }
    }
    if ($Initiative) {
        $initiativeId = if ($Resolve) { Resolve-LinearInitiativeId -Initiative $Initiative } else { $null }
        return [pscustomobject]@{ Kind = 'Initiative'; Field = 'initiativeId'; Id = $initiativeId; Name = "initiative '$Initiative'" }
    }
    if ($Team) {
        $teamId = if ($Resolve) { Resolve-LinearTeamId -Team $Team } else { $null }
        return [pscustomobject]@{ Kind = 'Team'; Field = 'teamId'; Id = $teamId; Name = "team $Team" }
    }

    if ($null -ne $InputObject) {
        $typeNames = @($InputObject.PSObject.TypeNames)
        $objectId = Get-LinearNestedValue -InputObject $InputObject -Name 'Id'
        $name = Get-LinearNestedValue -InputObject $InputObject -Name 'Name'
        if ($typeNames -contains 'PSLinear.Issue') {
            $identifier = Get-LinearNestedValue -InputObject $InputObject -Name 'Identifier'
            return [pscustomobject]@{ Kind = 'Issue'; Field = 'issueId'; Id = $objectId; Name = $(if ($identifier) { $identifier } else { $objectId }) }
        }
        if ($typeNames -contains 'PSLinear.Project') {
            return [pscustomobject]@{ Kind = 'Project'; Field = 'projectId'; Id = $objectId; Name = "project '$(if ($name) { $name } else { $objectId })'" }
        }
        if ($typeNames -contains 'PSLinear.Initiative') {
            return [pscustomobject]@{ Kind = 'Initiative'; Field = 'initiativeId'; Id = $objectId; Name = "initiative '$(if ($name) { $name } else { $objectId })'" }
        }
        if ($typeNames -contains 'PSLinear.Team') {
            $key = Get-LinearNestedValue -InputObject $InputObject -Name 'Key'
            return [pscustomobject]@{ Kind = 'Team'; Field = 'teamId'; Id = $objectId; Name = "team $(if ($key) { $key } else { $objectId })" }
        }
        throw (New-LinearErrorRecord -Message ('Documents belong to an issue, a project, an initiative or a team. Pipe in PSLinear.Issue, ' +
                'PSLinear.Project, PSLinear.Initiative or PSLinear.Team objects.') `
                -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument -TargetObject $InputObject)
    }
}
