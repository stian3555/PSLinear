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

function Send-LinearFileUpload {
    <#
    .SYNOPSIS
        PUTs a file to a pre-signed upload URL from Linear's fileUpload mutation. Returns the HTTP status code.
    .DESCRIPTION
        The only request that does not go to the GraphQL endpoint: the URL points at Linear's
        cloud storage and carries its own signature, so no Authorization header is sent. Kept
        tiny on purpose so tests can mock the network boundary.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [uri] $Uri,

        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $ContentType,

        [hashtable] $Headers = @{}
    )

    $requestParameters = @{
        Uri                  = $Uri
        Method               = 'Put'
        # -InFile expands wildcards, so escape names like 'shot [1].png'.
        InFile               = [WildcardPattern]::Escape($Path)
        ContentType          = $ContentType
        Headers              = $Headers
        SkipHeaderValidation = $true
        SkipHttpErrorCheck   = $true
        ErrorAction          = 'Stop'
    }
    $response = Invoke-WebRequest @requestParameters
    [int]$response.StatusCode
}

function Invoke-LinearRequest {
    <#
    .SYNOPSIS
        Sends a GraphQL document to Linear and returns the 'data' part of the response.
    .DESCRIPTION
        Handles authentication, GraphQL errors (which may arrive with HTTP 200),
        rate limiting (HTTP 400 with code RATELIMITED), server errors and transient
        network failures, retrying with exponential backoff.

        Queries are retried after any of these. A mutation is retried only when Linear rejected
        it because of the rate limit, or when it never reached Linear (see
        Test-LinearRequestNotSent): after a server error or a connection that failed later,
        Linear may already have made the change, so sending it again could make it twice. Those
        failures throw PSLinear.MutationOutcomeUnknown instead.
    .PARAMETER Idempotent
        The mutation can be sent again without harm, for example because it only signs an upload
        URL or updates a record by its key, so it is retried like a query.
    .PARAMETER IncludeErrors
        Return [pscustomobject]@{ Data; Errors } instead of throwing on GraphQL errors.
        Authentication, rate-limit, server (HTTP 5xx), other HTTP and network failures still
        throw. Callers use this for expected errors (such as 'not found') so the error is
        written only once: PowerShell records a caught terminating error from a nested command
        in the caller's -ErrorVariable as well.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Query,

        [System.Collections.IDictionary] $Variables,

        [string] $OperationName,

        [switch] $Idempotent,

        [switch] $IncludeErrors
    )

    $context = Get-LinearContext
    if (Test-LinearTokenExpiring -Context $context) {
        try {
            Update-LinearOAuthToken -Context $context
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }

    $payload = [ordered]@{ query = $Query }
    if ($OperationName) { $payload['operationName'] = $OperationName }
    if ($null -ne $Variables -and $Variables.Count -gt 0) { $payload['variables'] = $Variables }
    $body = ConvertTo-Json -InputObject $payload -Depth 32 -Compress

    $headers = @{
        Authorization = Get-LinearAuthorizationValue -Context $context
        Accept        = 'application/json'
        'User-Agent'  = $script:UserAgent
    }

    $operation = Get-LinearOperation -Document $Query -OperationName $OperationName
    # Sending a mutation again after an unclear failure could make the change twice.
    $mayDuplicate = $operation.Type -eq 'mutation' -and -not $Idempotent
    $mutationName = if ($operation.Name) { "mutation $($operation.Name)" } else { 'the mutation' }
    $outcomeAdvice = 'Linear may or may not have made the change, so it was not sent again. Check the result in Linear before you retry.'

    $maxRetries = $context.MaxRetries
    $attempt = 0
    $renewed = $false
    while ($true) {
        $attempt++

        try {
            $response = Send-LinearHttpRequest -Uri $context.Endpoint -Headers $headers -Body $body
        }
        catch {
            if ($mayDuplicate -and -not (Test-LinearRequestNotSent -Exception $_.Exception)) {
                $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord `
                            -Message "The connection to Linear failed during $mutationName ($($_.Exception.Message)). $outcomeAdvice" `
                            -ErrorId 'PSLinear.MutationOutcomeUnknown' `
                            -Category ConnectionError `
                            -TargetObject $context.Endpoint))
            }
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
        # A rate-limited request was refused before Linear ran it, so even a mutation can be sent again.
        $isTransient = $isRateLimited -or ($response.StatusCode -ge 500 -and -not $mayDuplicate)

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
        if ($isAuthError -and -not $renewed -and (Test-LinearTokenRenewable -Context $context)) {
            # The access token may have been revoked or expired early: renew it once and retry.
            $renewed = $true
            try {
                Update-LinearOAuthToken -Context $context
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }
            $headers['Authorization'] = Get-LinearAuthorizationValue -Context $context
            $attempt--
            continue
        }
        if ($isAuthError) {
            $message = 'Linear rejected the credentials. Check that the API key or access token is valid and not revoked, then run Connect-Linear again.'
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.AuthenticationFailed' `
                        -Category AuthenticationError -Code 'AUTHENTICATION_ERROR' -StatusCode $response.StatusCode -TargetObject $errors))
        }

        $data = $null
        if ($null -ne $response.Content -and $response.Content -isnot [string]) {
            $data = Get-LinearNestedValue -InputObject $response.Content -Name 'data'
        }

        if ($response.StatusCode -ge 500 -and $mayDuplicate) {
            $message = Format-LinearFailureMessage -Message "Linear returned HTTP $($response.StatusCode) for $mutationName." -Errors $errors
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message "$message $outcomeAdvice" `
                        -ErrorId 'PSLinear.MutationOutcomeUnknown' -Category InvalidResult -StatusCode $response.StatusCode -TargetObject $response.Content))
        }

        if ($errors.Count -gt 0) {
            # A server error is never an expected per-item failure, so it is not returned with -IncludeErrors.
            if ($IncludeErrors -and $response.StatusCode -lt 500) {
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
    .PARAMETER IncludeErrors
        Collect every page and return [pscustomobject]@{ Nodes; Errors } instead of streaming the
        nodes and throwing on GraphQL errors. Paging stops at the first page with errors. Like
        Invoke-LinearRequest -IncludeErrors, this lets callers write an expected error (such as
        'not found') once, without catching a nested terminating error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Query,

        [Parameter(Mandatory)]
        [string] $ConnectionPath,

        [System.Collections.IDictionary] $Variables = @{},

        [ValidateRange(0, [int]::MaxValue)]
        [int] $Limit = $script:DefaultPageSize,

        [switch] $IncludeErrors
    )

    $pageVariables = @{}
    foreach ($key in $Variables.Keys) { $pageVariables[$key] = $Variables[$key] }
    $collected = [System.Collections.Generic.List[object]]::new()

    $remaining = if ($Limit -eq 0) { [int]::MaxValue } else { $Limit }
    $after = $null
    $page = 0
    do {
        $page++
        $pageVariables['first'] = [math]::Min($script:MaxPageSize, $remaining)
        $pageVariables['after'] = $after
        Write-Verbose "Fetching page $page ($($pageVariables['first']) items)."

        if ($IncludeErrors) {
            $result = Invoke-LinearRequest -Query $Query -Variables $pageVariables -IncludeErrors
            if ($result.Errors.Count -gt 0) {
                return [pscustomobject]@{ Nodes = $collected.ToArray(); Errors = $result.Errors }
            }
            $data = $result.Data
        }
        else {
            $data = Invoke-LinearRequest -Query $Query -Variables $pageVariables
        }
        $connection = Get-LinearNestedValue -InputObject $data -Name $ConnectionPath
        if ($null -eq $connection) { break }

        foreach ($node in @(Get-LinearNestedValue -InputObject $connection -Name 'nodes')) {
            if ($null -eq $node) { continue }
            if ($IncludeErrors) { $collected.Add($node) } else { $node }
            $remaining--
            if ($remaining -le 0) { break }
        }

        $hasNextPage = [bool](Get-LinearNestedValue -InputObject $connection -Name 'pageInfo.hasNextPage')
        $after = Get-LinearNestedValue -InputObject $connection -Name 'pageInfo.endCursor'
    } while ($remaining -gt 0 -and $hasNextPage -and $null -ne $after)

    if ($IncludeErrors) {
        [pscustomobject]@{ Nodes = $collected.ToArray(); Errors = @() }
    }
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

function Get-LinearOperation {
    <#
    .SYNOPSIS
        Returns the type (query, mutation or subscription) and name of the operation a GraphQL
        document runs, as [pscustomobject]@{ Type; Name }.
    .DESCRIPTION
        Reads only the top level of the document, after removing strings and comments, so a field
        named 'mutation' or a fragment cannot be mistaken for an operation. With -OperationName,
        returns that operation, otherwise the only one. When that is unclear (several operations,
        or a name that is not defined), the document counts as a mutation if it defines one, so
        a write is never retried or run under -WhatIf by mistake.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Document,

        [string] $OperationName
    )

    $text = [regex]::Replace($Document, '"""[\s\S]*?"""|"(?:\\.|[^"\\\r\n])*"|#[^\r\n]*', ' ')
    $operations = [System.Collections.Generic.List[object]]::new()
    $pending = $null
    $depth = 0
    foreach ($match in [regex]::Matches($text, '[{}()]|@?[_A-Za-z][_0-9A-Za-z]*')) {
        $token = $match.Value
        if ($token -eq '{' -or $token -eq '(') {
            # A selection set at the top level starts the body of an operation or a fragment.
            if ($depth -eq 0 -and $token -eq '{') {
                if ($null -eq $pending) {
                    $operations.Add([pscustomobject]@{ Type = 'query'; Name = $null })
                }
                elseif ($pending.Type -ne 'fragment') {
                    $operations.Add($pending)
                }
                $pending = $null
            }
            $depth++
        }
        elseif ($token -eq '}' -or $token -eq ')') {
            if ($depth -gt 0) { $depth-- }
        }
        elseif ($depth -eq 0 -and -not $token.StartsWith('@')) {
            if ($null -eq $pending) {
                if ($token -cin 'query', 'mutation', 'subscription', 'fragment') {
                    $pending = [pscustomobject]@{ Type = $token; Name = $null }
                }
            }
            elseif ($null -eq $pending.Name) {
                $pending.Name = $token
            }
        }
    }

    $selected = if ($OperationName) {
        $operations | Where-Object { $null -ne $_ -and $_.Name -ceq $OperationName } | Select-Object -First 1
    }
    elseif ($operations.Count -eq 1) {
        $operations[0]
    }
    if ($null -ne $selected) { return $selected }

    $hasMutation = @($operations | Where-Object { $null -ne $_ -and $_.Type -eq 'mutation' }).Count -gt 0
    [pscustomobject]@{
        Type = if ($hasMutation) { 'mutation' } else { 'query' }
        Name = if ($OperationName) { $OperationName } else { $null }
    }
}

function Test-LinearRequestNotSent {
    <#
    .SYNOPSIS
        Returns whether a failed HTTP request certainly never reached Linear: the host name did not
        resolve, or the connection, its TLS handshake or the proxy tunnel could not be set up.
    .NOTES
        Any other failure, such as a connection that broke during the request, may come after
        Linear received the request, so a mutation that failed that way may still have been made.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [System.Exception] $Exception
    )

    $notSentErrors = [System.Net.Http.HttpRequestError[]]@('NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ProxyTunnelError')
    $notSentSocketErrors = [System.Net.Sockets.SocketError[]]@('HostNotFound', 'TryAgain', 'NoData', 'ConnectionRefused', 'NetworkUnreachable', 'HostUnreachable', 'NetworkDown')
    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if ($current -is [System.Net.Http.HttpRequestException] -and $current.HttpRequestError -in $notSentErrors) { return $true }
        if ($current -is [System.Net.Sockets.SocketException] -and $current.SocketErrorCode -in $notSentSocketErrors) { return $true }
    }
    $false
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
