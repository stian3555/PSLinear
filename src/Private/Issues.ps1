function Format-LinearChangeList {
    <#
    .SYNOPSIS
        Describes the change parameters a command was given, for ShouldProcess messages.
    .DESCRIPTION
        Returns text such as: State='Done', Label='Bug','UI', Unassign
        Long values are shortened, and switches are listed by name when present.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.IDictionary[string, object]] $BoundParameters,

        [Parameter(Mandatory)]
        [string[]] $Name
    )

    $parts = foreach ($key in $Name) {
        if (-not $BoundParameters.ContainsKey($key)) { continue }
        $value = $BoundParameters[$key]
        if ($value -is [switch]) {
            if ($value.IsPresent) { $key }
            continue
        }

        $texts = foreach ($item in @($value)) {
            $text = if ($item -is [datetime]) { ConvertTo-LinearTimelessDate -Date $item } else { [string]$item -replace '\s+', ' ' }
            if ($text.Length -gt 40) { $text = $text.Substring(0, 37) + '...' }
            "'$text'"
        }
        '{0}={1}' -f $key, ($texts -join ',')
    }
    $parts -join ', '
}

function Get-LinearIssueTarget {
    <#
    .SYNOPSIS
        Normalises -Id strings and PSLinear.Issue objects for the issue write commands.
    .DESCRIPTION
        Returns one object per issue with Id (sent to Linear), Name (the identifier, for
        messages) and TeamId ($null when it is not known without a request).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [string[]] $Id,

        [AllowNull()]
        [object[]] $InputObject
    )

    foreach ($value in @($Id)) {
        if ([string]::IsNullOrEmpty($value)) { continue }
        $identifier = ConvertTo-LinearIssueIdentifier -Value $value
        [pscustomobject]@{ Id = $identifier; Name = $identifier; TeamId = $null }
    }

    foreach ($issue in @($InputObject)) {
        if ($null -eq $issue) { continue }
        $issueId = Get-LinearNestedValue -InputObject $issue -Name 'Id'
        $identifier = Get-LinearNestedValue -InputObject $issue -Name 'Identifier'
        [pscustomobject]@{
            Id     = $issueId
            Name   = if ($identifier) { $identifier } else { $issueId }
            TeamId = Get-LinearNestedValue -InputObject $issue -Name 'TeamId'
        }
    }
}

function ConvertTo-LinearIssueIdentifier {
    <#
    .SYNOPSIS
        Turns an issue URL (https://linear.app/acme/issue/ENG-123/title) into its identifier (ENG-123).
        Any other value is returned unchanged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    if ($Value -match '^https?://linear\.app/[^/]+/issue/([A-Za-z0-9_]+-\d+)(?:[/?#]|$)') {
        return $Matches[1].ToUpperInvariant()
    }
    $Value
}

function ConvertTo-LinearPriority {
    <#
    .SYNOPSIS
        Converts a priority name (High) or number (0-4) to Linear's priority number.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $Priority
    )

    $number = 0
    if ([int]::TryParse($Priority, [ref]$number)) { return $number }
    $script:PriorityMap[$Priority]
}

function ConvertTo-LinearTimelessDate {
    <#
    .SYNOPSIS
        Formats a date as yyyy-MM-dd, the format of Linear's TimelessDate (for example dueDate).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [datetime] $Date
    )

    $Date.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
}
