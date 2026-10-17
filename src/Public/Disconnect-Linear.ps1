function Disconnect-Linear {
    <#
    .SYNOPSIS
        Removes the Linear connection from the current session.

    .DESCRIPTION
        Clears the stored credential and any cached lookups. If the LINEAR_API_KEY
        environment variable is set, the next PSLinear command will connect implicitly
        with it again; remove the variable to prevent that.

    .EXAMPLE
        Disconnect-Linear

        Forgets the current credential.

    .INPUTS
        None.

    .OUTPUTS
        None.

    .LINK
        Connect-Linear
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $wasConnected = $null -ne $script:LinearContext
    $script:LinearContext = $null
    $script:LinearRateLimit = $null
    Clear-LinearCache

    if ($wasConnected) {
        Write-Verbose 'Disconnected from Linear.'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LINEAR_API_KEY)) {
        Write-Warning 'LINEAR_API_KEY is still set, so the next PSLinear command will connect with it again.'
    }
}
