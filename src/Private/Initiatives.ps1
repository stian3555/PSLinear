function Get-LinearInitiativeCache {
    <#
    .SYNOPSIS
        Returns all non-archived initiatives, cached for a few minutes. Used for name resolution.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Initiative')]
    param(
        [switch] $Refresh
    )

    if ($Refresh -or $null -eq $script:LinearInitiativeCache -or [datetime]::UtcNow -ge $script:LinearInitiativeCacheExpires) {
        $script:LinearInitiativeCache = @(Get-LinearInitiativeList)
        $script:LinearInitiativeCacheExpires = [datetime]::UtcNow.Add($script:CacheLifetime)
    }
    $script:LinearInitiativeCache
}

function Get-LinearInitiativeList {
    <#
    .SYNOPSIS
        Fetches the workspace's initiatives, sorted by name. Archived initiatives are included only with -IncludeArchived.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Initiative')]
    param(
        [switch] $IncludeArchived
    )

    Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListInitiatives') -ConnectionPath 'initiatives' -Limit 0 `
        -Variables @{ includeArchived = [bool]$IncludeArchived } |
        ConvertTo-LinearInitiative |
        Sort-Object -Property Name
}

function ConvertFrom-LinearInitiativeUrl {
    <#
    .SYNOPSIS
        Returns the slug id of an initiative URL, or the value unchanged when it is not an initiative URL.
    .EXAMPLE
        ConvertFrom-LinearInitiativeUrl -Value 'https://linear.app/acme/initiative/q1-growth-5f2c9a1b7e3d'
        # 5f2c9a1b7e3d
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    if ($Value -match '^https?://linear\.app/[^/]+/initiative/(?:[^/?#]*-)?([0-9a-f]+)(?:[/?#]|$)') { return $Matches[1] }
    $Value
}

function Resolve-LinearInitiativeId {
    <#
    .SYNOPSIS
        Resolves an initiative id, URL, slug id (the hex suffix of its URL) or name to the initiative's id.
    .NOTES
        Throws an ErrorRecord (PSLinear.InitiativeNotFound or PSLinear.AmbiguousInitiative) that
        callers rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Initiative
    )

    if (Test-LinearGuid -Value $Initiative) { return $Initiative }

    $slugId = ConvertFrom-LinearInitiativeUrl -Value $Initiative
    $match = @()
    foreach ($refresh in $false, $true) {
        $initiatives = @(Get-LinearInitiativeCache -Refresh:$refresh | Where-Object { $null -ne $_ })
        $match = @($initiatives | Where-Object { $_.SlugId -eq $slugId })
        if ($match.Count -eq 0) { $match = @($initiatives | Where-Object { $_.Name -eq $Initiative }) }
        if ($match.Count -gt 0) { break }
    }

    if ($match.Count -eq 1) { return $match[0].Id }
    if ($match.Count -gt 1) {
        $matchList = ($match | ForEach-Object { "$($_.Name) ($($_.Id))" }) -join ', '
        throw (New-LinearErrorRecord -Message "Initiative '$Initiative' is ambiguous. Use the initiative id instead. Matches: $matchList." `
                -ErrorId 'PSLinear.AmbiguousInitiative' -Category InvalidArgument -TargetObject $Initiative)
    }

    $available = Format-LinearValueList -Value (Get-LinearInitiativeCache | Where-Object { $null -ne $_ } | ForEach-Object Name)
    throw (New-LinearErrorRecord -Message "Initiative '$Initiative' was not found. Valid initiatives: $available." `
            -ErrorId 'PSLinear.InitiativeNotFound' -Category ObjectNotFound -TargetObject $Initiative)
}

function Get-LinearInitiativeTarget {
    <#
    .SYNOPSIS
        Describes the initiatives a write command acts on, without sending a request.
    .DESCRIPTION
        Returns [pscustomobject]@{ Id; Reference; Name } per initiative. Id is set for piped
        PSLinear.Initiative objects; an initiative given as text keeps it in Reference until the
        caller resolves it with Resolve-LinearInitiativeId after ShouldProcess.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $Initiative,

        [object[]] $InputObject
    )

    foreach ($value in $Initiative) {
        [pscustomobject]@{ Id = $null; Reference = $value; Name = "initiative '$value'" }
    }
    foreach ($object in $InputObject) {
        if ($null -eq $object) { continue }
        $initiativeName = Get-LinearNestedValue -InputObject $object -Name 'Name'
        [pscustomobject]@{ Id = $object.Id; Reference = $object.Id; Name = "initiative '$(if ($initiativeName) { $initiativeName } else { $object.Id })'" }
    }
}

function Get-LinearInitiativeDetail {
    <#
    .SYNOPSIS
        Fetches one initiative with its content, every label and project, and its sub-initiatives.
    .DESCRIPTION
        Returns [pscustomobject]@{ Initiative; Errors }: the raw node, or $null with the GraphQL
        errors when the initiative does not exist. Accepts an id or a slug id.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Id
    )

    $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'GetInitiative') -Variables @{ id = $Id } -IncludeErrors
    [pscustomobject]@{
        Initiative = Get-LinearNestedValue -InputObject $result.Data -Name 'initiative'
        Errors     = $result.Errors
    }
}

function Reset-LinearInitiativeCache {
    <#
    .SYNOPSIS
        Forgets the cached initiatives, so name lookups see one that was just created, renamed or removed.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Clears an in-memory cache only.')]
    [CmdletBinding()]
    param()

    $script:LinearInitiativeCache = $null
    $script:LinearInitiativeCacheExpires = [datetime]::MinValue
}

function Get-LinearInitiativeLabelCache {
    <#
    .SYNOPSIS
        Returns the initiative labels that can be applied (no groups, no retired labels), cached for a few minutes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch] $Refresh
    )

    if ($Refresh -or $null -eq $script:LinearInitiativeLabelCache -or [datetime]::UtcNow -ge $script:LinearInitiativeLabelCacheExpires) {
        $query = Get-LinearGraphQLDocument -Name 'ListInitiativeLabels'
        $script:LinearInitiativeLabelCache = @(Invoke-LinearPagedRequest -Query $query -ConnectionPath 'initiativeLabels' -Limit 0 |
                Where-Object { $null -ne $_ -and -not $_.isGroup -and $null -eq (Get-LinearNestedValue -InputObject $_ -Name 'retiredAt') } |
                ForEach-Object {
                    [pscustomobject]@{
                        PSTypeName = 'PSLinear.InitiativeLabel'
                        Id         = $_.id
                        Name       = $_.name
                        Group      = Get-LinearNestedValue -InputObject $_ -Name 'parent.name'
                        Team       = $null
                    }
                } |
                Sort-Object -Property Name, Id)
        $script:LinearInitiativeLabelCacheExpires = [datetime]::UtcNow.Add($script:CacheLifetime)
    }
    $script:LinearInitiativeLabelCache
}

function Resolve-LinearInitiativeLabelId {
    <#
    .SYNOPSIS
        Resolves initiative label names or ids to label ids.
    .NOTES
        Throws an ErrorRecord (PSLinear.LabelNotFound or PSLinear.AmbiguousLabel) that callers
        rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Label
    )

    Resolve-LinearListedLabelId -Label $Label -CacheCommand 'Get-LinearInitiativeLabelCache' -Noun 'Initiative label'
}
