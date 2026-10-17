function Get-LinearRateLimit {
    <#
    .SYNOPSIS
        Shows the API rate-limit status reported by the most recent request.

    .DESCRIPTION
        Linear limits both the number of requests and the total query complexity per hour.
        Every response carries headers with the current status; this command returns the
        values from the latest response in this session. It does not call the API itself.

        PSLinear already retries rate-limited requests automatically. Use this command in
        long-running scripts to slow down before the limit is reached.

    .EXAMPLE
        Get-LinearRateLimit

        Shows remaining requests and complexity points, and when each window resets.

    .EXAMPLE
        if ((Get-LinearRateLimit).RequestsRemaining -lt 100) { Start-Sleep -Seconds 30 }

        Backs off in a script when few requests remain.

    .INPUTS
        None.

    .OUTPUTS
        PSLinear.RateLimit

    .LINK
        https://linear.app/developers/rate-limiting
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.RateLimit')]
    param()

    if ($null -eq $script:LinearRateLimit) {
        Write-Warning 'No rate-limit information yet. It becomes available after the first request to Linear.'
        return
    }
    $script:LinearRateLimit
}
