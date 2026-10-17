function New-LinearErrorRecord {
    <#
    .SYNOPSIS
        Creates a consistent ErrorRecord for PSLinear failures.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)]
        [string] $Message,

        [Parameter(Mandatory)]
        [string] $ErrorId,

        [System.Management.Automation.ErrorCategory] $Category = 'InvalidOperation',

        [object] $TargetObject,

        [string] $Code,

        [int] $StatusCode
    )

    $exception = [System.InvalidOperationException]::new($Message)
    if ($Code) { $exception.Data['LinearErrorCode'] = $Code }
    if ($StatusCode) { $exception.Data['StatusCode'] = $StatusCode }
    [System.Management.Automation.ErrorRecord]::new($exception, $ErrorId, $Category, $TargetObject)
}

function Get-LinearResponseError {
    <#
    .SYNOPSIS
        Extracts GraphQL errors from a response body. Returns nothing when there are none.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Content
    )

    if ($null -eq $Content -or $Content -is [string]) { return }
    $errorsProperty = $Content.PSObject.Properties['errors']
    if ($null -eq $errorsProperty -or $null -eq $errorsProperty.Value) { return }

    foreach ($graphQLError in $errorsProperty.Value) {
        $code = $null
        $extensions = $graphQLError.PSObject.Properties['extensions']
        if ($null -ne $extensions -and $null -ne $extensions.Value) {
            $codeProperty = $extensions.Value.PSObject.Properties['code']
            if ($null -ne $codeProperty) { $code = [string]$codeProperty.Value }
        }

        $path = $null
        $pathProperty = $graphQLError.PSObject.Properties['path']
        if ($null -ne $pathProperty -and $null -ne $pathProperty.Value) {
            $path = $pathProperty.Value -join '.'
        }

        $messageProperty = $graphQLError.PSObject.Properties['message']
        [pscustomobject]@{
            Message = if ($null -ne $messageProperty) { [string]$messageProperty.Value } else { 'Unknown error' }
            Code    = $code
            Path    = $path
        }
    }
}

function Format-LinearValueList {
    <#
    .SYNOPSIS
        Joins valid values for an error message, listing at most $script:MaxListedValues of them.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Value
    )

    $values = @($Value | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($values.Count -eq 0) { return '(none)' }
    if ($values.Count -le $script:MaxListedValues) { return $values -join ', ' }
    '{0} (and {1} more)' -f ($values[0..($script:MaxListedValues - 1)] -join ', '), ($values.Count - $script:MaxListedValues)
}

function Format-LinearFailureMessage {
    <#
    .SYNOPSIS
        Appends the GraphQL errors from an -IncludeErrors response, if any, to a failure message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Message,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Errors
    )

    $graphQLErrors = @($Errors | Where-Object { $null -ne $_ })
    if ($graphQLErrors.Count -eq 0) { return $Message }
    '{0} {1}' -f $Message, (Format-LinearErrorMessage -Errors $graphQLErrors)
}

function Format-LinearErrorMessage {
    <#
    .SYNOPSIS
        Turns a list of GraphQL errors into one readable message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object[]] $Errors
    )

    $parts = foreach ($graphQLError in $Errors) {
        $details = @()
        if ($graphQLError.Code) { $details += "code: $($graphQLError.Code)" }
        if ($graphQLError.Path) { $details += "path: $($graphQLError.Path)" }
        if ($details.Count -gt 0) {
            '{0} ({1})' -f $graphQLError.Message, ($details -join ', ')
        }
        else {
            $graphQLError.Message
        }
    }
    'Linear API error: ' + ($parts -join '; ')
}
