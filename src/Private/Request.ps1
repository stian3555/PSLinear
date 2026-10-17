function Send-LinearHttpRequest {
    <#
    .SYNOPSIS
        Performs one HTTP POST. Kept tiny on purpose so tests can mock the network boundary.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [uri] $Uri,

        [Parameter(Mandatory)]
        [hashtable] $Headers,

        [Parameter(Mandatory)]
        [string] $Body
    )

    $responseHeaders = $null
    $statusCode = 0
    $requestParameters = @{
        Uri                     = $Uri
        Method                  = 'Post'
        Headers                 = $Headers
        Body                    = [System.Text.Encoding]::UTF8.GetBytes($Body)
        ContentType             = 'application/json; charset=utf-8'
        ResponseHeadersVariable = 'responseHeaders'
        StatusCodeVariable      = 'statusCode'
        SkipHttpErrorCheck      = $true
        ErrorAction             = 'Stop'
    }
    $content = Invoke-RestMethod @requestParameters

    # Normalise to a case-insensitive hashtable of single strings.
    $normalisedHeaders = @{}
    if ($null -ne $responseHeaders) {
        foreach ($key in $responseHeaders.Keys) {
            $normalisedHeaders[$key] = $responseHeaders[$key] -join ','
        }
    }

    [pscustomobject]@{
        StatusCode = [int]$statusCode
        Headers    = $normalisedHeaders
        Content    = $content
    }
}

function Invoke-LinearRequest {
    <#
    .SYNOPSIS
        Sends a GraphQL document to Linear and returns the 'data' part of the response.
    .DESCRIPTION
        Handles authentication, GraphQL errors (which may arrive with HTTP 200),
        rate limiting (HTTP 400 with code RATELIMITED), server errors and transient
        network failures, retrying with exponential backoff.
    .PARAMETER IncludeErrors
        Return [pscustomobject]@{ Data; Errors } instead of throwing on GraphQL errors.
        Authentication, rate-limit, HTTP and network failures still throw. Callers use this
        for expected errors (such as 'not found') so the error is written only once:
        PowerShell records a caught terminating error from a nested command in the
        caller's -ErrorVariable as well.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Query,

        [System.Collections.IDictionary] $Variables,

        [string] $OperationName,

        [switch] $IncludeErrors
    )

    $context = Get-LinearContext

    $payload = [ordered]@{ query = $Query }
    if ($OperationName) { $payload['operationName'] = $OperationName }
    if ($null -ne $Variables -and $Variables.Count -gt 0) { $payload['variables'] = $Variables }
    $body = ConvertTo-Json -InputObject $payload -Depth 32 -Compress

    $headers = @{
        Authorization = Get-LinearAuthorizationValue -Context $context
        Accept        = 'application/json'
        'User-Agent'  = $script:UserAgent
    }

    $maxRetries = $context.MaxRetries
    $attempt = 0
    while ($true) {
        $attempt++

        try {
            $response = Send-LinearHttpRequest -Uri $context.Endpoint -Headers $headers -Body $body
        }
        catch {
            if ($attempt -le $maxRetries) {
                $delay = Get-LinearRetryDelay -Attempt $attempt
                Write-Verbose "Request to Linear failed ($($_.Exception.Message)). Retrying in $delay ms (retry $attempt of $maxRetries)."
                Start-Sleep -Milliseconds $delay
                continue
            }
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord `
                        -Message "Could not reach the Linear API: $($_.Exception.Message)" `
                        -ErrorId 'PSLinear.ConnectionFailed' `
                        -Category ConnectionError `
                        -TargetObject $context.Endpoint))
        }

        Save-LinearRateLimitState -Headers $response.Headers
        $errors = @(Get-LinearResponseError -Content $response.Content)
        $isRateLimited = ($response.StatusCode -eq 429) -or (@($errors | Where-Object Code -EQ 'RATELIMITED').Count -gt 0)
        $isTransient = $isRateLimited -or ($response.StatusCode -ge 500)

        if ($isTransient -and $attempt -le $maxRetries) {
            $delay = Get-LinearRetryDelay -Attempt $attempt -Headers $response.Headers
            $reason = if ($isRateLimited) { 'Rate limited by Linear' } else { "Linear returned HTTP $($response.StatusCode)" }
            Write-Verbose "$reason. Retrying in $delay ms (retry $attempt of $maxRetries)."
            Start-Sleep -Milliseconds $delay
            continue
        }

        if ($isRateLimited) {
            $message = 'Linear API rate limit exceeded and retries were exhausted. Use Get-LinearRateLimit to see when the limit resets.'
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.RateLimited' `
                        -Category LimitsExceeded -Code 'RATELIMITED' -StatusCode $response.StatusCode -TargetObject $errors))
        }

        $isAuthError = ($response.StatusCode -eq 401) -or (@($errors | Where-Object Code -EQ 'AUTHENTICATION_ERROR').Count -gt 0)
        if ($isAuthError) {
            $message = 'Linear rejected the credentials. Check that the API key or access token is valid and not revoked, then run Connect-Linear again.'
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.AuthenticationFailed' `
                        -Category AuthenticationError -Code 'AUTHENTICATION_ERROR' -StatusCode $response.StatusCode -TargetObject $errors))
        }

        $data = $null
        if ($null -ne $response.Content -and $response.Content -isnot [string]) {
            $data = Get-LinearNestedValue -InputObject $response.Content -Name 'data'
        }

        if ($errors.Count -gt 0) {
            if ($IncludeErrors) {
                return [pscustomobject]@{ Data = $data; Errors = $errors }
            }
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message (Format-LinearErrorMessage -Errors $errors) `
                        -ErrorId 'PSLinear.GraphQLError' -Code $errors[0].Code -StatusCode $response.StatusCode -TargetObject $errors))
        }

        if ($response.StatusCode -ge 400) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message "Linear API returned HTTP $($response.StatusCode)." `
                        -ErrorId 'PSLinear.HttpError' -StatusCode $response.StatusCode -TargetObject $response.Content))
        }

        if ($IncludeErrors) {
            return [pscustomobject]@{ Data = $data; Errors = @() }
        }
        return $data
    }
}

function Invoke-LinearPagedRequest {
    <#
    .SYNOPSIS
        Runs a query that returns a Relay connection and streams its nodes, following endCursor.
    .PARAMETER ConnectionPath
        Dot-separated path from 'data' to the connection, for example 'issues' or 'team.issues'.
    .PARAMETER Limit
        Maximum number of nodes to return. Use 0 for no limit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Query,

        [Parameter(Mandatory)]
        [string] $ConnectionPath,

        [System.Collections.IDictionary] $Variables = @{},

        [ValidateRange(0, [int]::MaxValue)]
        [int] $Limit = $script:DefaultPageSize
    )

    $pageVariables = @{}
    foreach ($key in $Variables.Keys) { $pageVariables[$key] = $Variables[$key] }

    $remaining = if ($Limit -eq 0) { [int]::MaxValue } else { $Limit }
    $after = $null
    $page = 0
    do {
        $page++
        $pageVariables['first'] = [math]::Min($script:MaxPageSize, $remaining)
        $pageVariables['after'] = $after
        Write-Verbose "Fetching page $page ($($pageVariables['first']) items)."

        $data = Invoke-LinearRequest -Query $Query -Variables $pageVariables
        $connection = Get-LinearNestedValue -InputObject $data -Name $ConnectionPath
        if ($null -eq $connection) { return }

        foreach ($node in @(Get-LinearNestedValue -InputObject $connection -Name 'nodes')) {
            if ($null -eq $node) { continue }
            $node
            $remaining--
            if ($remaining -le 0) { break }
        }

        $hasNextPage = [bool](Get-LinearNestedValue -InputObject $connection -Name 'pageInfo.hasNextPage')
        $after = Get-LinearNestedValue -InputObject $connection -Name 'pageInfo.endCursor'
    } while ($remaining -gt 0 -and $hasNextPage -and $null -ne $after)
}

function Get-LinearRetryDelay {
    <#
    .SYNOPSIS
        Exponential backoff with jitter (1s, 2s, 4s ...), honouring Retry-After when present.
    .NOTES
        Linear uses a leaky bucket, so capacity refills continuously and a short wait is usually enough.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [int] $Attempt,

        [hashtable] $Headers
    )

    if ($null -ne $Headers -and $Headers.ContainsKey('Retry-After')) {
        $seconds = 0
        if ([int]::TryParse([string]$Headers['Retry-After'], [ref]$seconds) -and $seconds -gt 0) {
            return [int][math]::Min($seconds * 1000, 60000)
        }
    }

    $base = [math]::Min(30000, 1000 * [math]::Pow(2, $Attempt - 1))
    [int]($base + (Get-Random -Minimum 0 -Maximum 250))
}

function Save-LinearRateLimitState {
    <#
    .SYNOPSIS
        Records the rate-limit headers from the latest response for Get-LinearRateLimit.
    #>
    [CmdletBinding()]
    param(
        [hashtable] $Headers
    )

    if ($null -eq $Headers -or -not $Headers.ContainsKey('X-RateLimit-Requests-Remaining')) { return }

    $script:LinearRateLimit = [pscustomobject]@{
        PSTypeName          = 'PSLinear.RateLimit'
        RequestsLimit       = ConvertTo-LinearNumber -Value $Headers['X-RateLimit-Requests-Limit']
        RequestsRemaining   = ConvertTo-LinearNumber -Value $Headers['X-RateLimit-Requests-Remaining']
        RequestsReset       = ConvertFrom-LinearUnixTime -Value $Headers['X-RateLimit-Requests-Reset']
        ComplexityLimit     = ConvertTo-LinearNumber -Value $Headers['X-RateLimit-Complexity-Limit']
        ComplexityRemaining = ConvertTo-LinearNumber -Value $Headers['X-RateLimit-Complexity-Remaining']
        ComplexityReset     = ConvertFrom-LinearUnixTime -Value $Headers['X-RateLimit-Complexity-Reset']
        LastQueryComplexity = ConvertTo-LinearNumber -Value $Headers['X-Complexity']
        ObservedAt          = [datetimeoffset]::Now
    }
}

function ConvertTo-LinearNumber {
    [CmdletBinding()]
    [OutputType([long])]
    param([AllowNull()][object] $Value)

    $number = 0L
    if ($null -ne $Value -and [long]::TryParse([string]$Value, [ref]$number)) { return $number }
    $null
}

function ConvertFrom-LinearUnixTime {
    [CmdletBinding()]
    [OutputType([datetimeoffset])]
    param([AllowNull()][object] $Value)

    $milliseconds = ConvertTo-LinearNumber -Value $Value
    if ($null -eq $milliseconds) { return $null }
    [datetimeoffset]::FromUnixTimeMilliseconds($milliseconds).ToLocalTime()
}

function Get-LinearGraphQLDocument {
    <#
    .SYNOPSIS
        Returns a named operation with every fragment it uses (recursively) appended.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($script:LinearDocumentCache.ContainsKey($Name)) {
        return $script:LinearDocumentCache[$Name]
    }
    if (-not $script:GraphQLOperations.ContainsKey($Name)) {
        throw "Unknown GraphQL operation '$Name'."
    }

    $spreadPattern = '(?<!\.)\.\.\.\s*(?!on\b)([_A-Za-z][_0-9A-Za-z]*)'
    $operation = $script:GraphQLOperations[$Name]
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($operation.Trim())
    $included = [System.Collections.Generic.HashSet[string]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($operation)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($match in [regex]::Matches($current, $spreadPattern)) {
            $fragmentName = $match.Groups[1].Value
            if (-not $included.Add($fragmentName)) { continue }
            if (-not $script:GraphQLFragments.ContainsKey($fragmentName)) {
                throw "GraphQL operation '$Name' uses unknown fragment '$fragmentName'."
            }
            $fragment = $script:GraphQLFragments[$fragmentName]
            $parts.Add($fragment.Trim())
            $queue.Enqueue($fragment)
        }
    }

    $document = $parts -join "`n`n"
    $script:LinearDocumentCache[$Name] = $document
    $document
}
