function Get-LinearIssueRelationList {
    <#
    .SYNOPSIS
        Fetches every relation of an issue, in both directions, seen from that issue.
    .DESCRIPTION
        Returns [pscustomobject]@{ Relations; Errors }. Relations the issue starts (relations)
        and relations that point at it (inverseRelations) are fetched separately, each with
        paging, and combined oldest first. Errors holds the GraphQL errors when the issue does
        not exist.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Issue
    )

    $outgoing = Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListIssueRelations') -ConnectionPath 'issue.relations' `
        -Variables @{ id = $Issue } -Limit 0 -IncludeErrors
    if ($outgoing.Errors.Count -gt 0) {
        return [pscustomobject]@{ Relations = @(); Errors = $outgoing.Errors }
    }
    $incoming = Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListIssueInverseRelations') -ConnectionPath 'issue.inverseRelations' `
        -Variables @{ id = $Issue } -Limit 0 -IncludeErrors
    if ($incoming.Errors.Count -gt 0) {
        return [pscustomobject]@{ Relations = @(); Errors = $incoming.Errors }
    }

    $relations = @(
        $outgoing.Nodes | ConvertTo-LinearIssueRelation
        $incoming.Nodes | ConvertTo-LinearIssueRelation -Inverse
    )
    [pscustomobject]@{
        Relations = @($relations | Sort-Object -Property CreatedAt)
        Errors    = @()
    }
}

function Get-LinearRelationDirection {
    <#
    .SYNOPSIS
        Maps a PSLinear relation type (Blocks, BlockedBy, ...) to Linear's type and direction.
    .DESCRIPTION
        Returns [pscustomobject]@{ ApiType; Swap }. Swap is $true for BlockedBy and DuplicatedBy,
        which Linear stores the other way round (the related issue blocks, or is duplicated by).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Blocks', 'BlockedBy', 'Related', 'DuplicateOf', 'DuplicatedBy', 'Similar')]
        [string] $Type
    )

    switch ($Type) {
        'Blocks' { [pscustomobject]@{ ApiType = 'blocks'; Swap = $false } }
        'BlockedBy' { [pscustomobject]@{ ApiType = 'blocks'; Swap = $true } }
        'Related' { [pscustomobject]@{ ApiType = 'related'; Swap = $false } }
        'DuplicateOf' { [pscustomobject]@{ ApiType = 'duplicate'; Swap = $false } }
        'DuplicatedBy' { [pscustomobject]@{ ApiType = 'duplicate'; Swap = $true } }
        'Similar' { [pscustomobject]@{ ApiType = 'similar'; Swap = $false } }
    }
}
