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
        # $PSBoundParameters or a hashtable; both have ContainsKey.
        [System.Collections.IDictionary] $BoundParameters,

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
        if ($value -is [System.Collections.IDictionary]) {
            $pairs = foreach ($entry in $value.GetEnumerator()) { "$($entry.Key)=$($entry.Value)" }
            $value = '{' + ($pairs -join '; ') + '}'
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
        messages), and TeamId and ProjectId ($null when they are not known without a request).
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
        [pscustomobject]@{ Id = $identifier; Name = $identifier; TeamId = $null; ProjectId = $null }
    }

    foreach ($issue in @($InputObject)) {
        if ($null -eq $issue) { continue }
        $issueId = Get-LinearNestedValue -InputObject $issue -Name 'Id'
        $identifier = Get-LinearNestedValue -InputObject $issue -Name 'Identifier'
        [pscustomobject]@{
            Id        = $issueId
            Name      = if ($identifier) { $identifier } else { $issueId }
            TeamId    = Get-LinearNestedValue -InputObject $issue -Name 'TeamId'
            ProjectId = Get-LinearNestedValue -InputObject $issue -Name 'ProjectId'
        }
    }
}

function ConvertTo-LinearUserFilter {
    <#
    .SYNOPSIS
        Builds a UserFilter for 'me', an email address, a user id, or a full or display name.
    .NOTES
        Used for the assignee and delegate filters of Get-LinearIssue. Sends no request.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $User
    )

    if ($User -eq 'me') { return @{ isMe = @{ eq = $true } } }
    if ($User -match '@') { return @{ email = @{ eqIgnoreCase = $User } } }
    if (Test-LinearGuid -Value $User) { return @{ id = @{ eq = $User } } }
    @{ or = @(@{ name = @{ eqIgnoreCase = $User } }, @{ displayName = @{ eqIgnoreCase = $User } }) }
}

function ConvertTo-LinearUrlComparator {
    <#
    .SYNOPSIS
        Builds a StringComparator for a URL: exact, or with * at the end (starts with), at the
        start (ends with) or at both ends (contains).
    .NOTES
        Only * is special, because URLs often contain ? and [. Throws an ErrorRecord
        (PSLinear.InvalidArgument) for a * anywhere else.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Url
    )

    $leading = $Url.StartsWith('*')
    $trailing = $Url.Length -gt 1 -and $Url.EndsWith('*')
    $text = $Url.Substring([int]$leading, $Url.Length - [int]$leading - [int]$trailing)
    if ($text.Length -eq 0 -or $text.Contains('*')) {
        throw (New-LinearErrorRecord -Message "'$Url' is not a URL pattern. Use * only at the start or the end, for example 'https://monitor.example/alerts/*'." `
                -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument -TargetObject $Url)
    }
    if ($leading -and $trailing) { return @{ contains = $text } }
    if ($trailing) { return @{ startsWith = $text } }
    if ($leading) { return @{ endsWith = $text } }
    @{ eq = $text }
}

function Complete-LinearIssueAttachment {
    <#
    .SYNOPSIS
        Makes sure an issue node from ListIssuesWithAttachments holds all of its attachments.
    .DESCRIPTION
        The list query reads only the first attachments of each issue, to keep its complexity
        low. For an issue that has more, all of them are read with ListIssueAttachments, so
        callers that look for an attachment never miss one.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) { return }
        if (Get-LinearNestedValue -InputObject $InputObject -Name 'attachments.pageInfo.hasNextPage') {
            Write-Verbose "Issue $($InputObject.identifier) has more attachments than the list returns; reading all of them."
            $InputObject.attachments.nodes = @(Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListIssueAttachments') `
                    -ConnectionPath 'issue.attachments' -Variables @{ id = $InputObject.id } -Limit 0)
        }
        $InputObject
    }
}

function Get-LinearIssueReference {
    <#
    .SYNOPSIS
        Looks up an issue's id, identifier and team. Returns [pscustomobject]@{ Issue; Errors },
        so a missing issue can be written as one non-terminating error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Id
    )

    $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'GetIssueTeam') -Variables @{ id = $Id } -IncludeErrors
    [pscustomobject]@{
        Issue  = Get-LinearNestedValue -InputObject $result.Data -Name 'issue'
        Errors = $result.Errors
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
