function Send-LinearOAuthRequest {
    <#
    .SYNOPSIS
        Performs one form-encoded POST to a Linear OAuth endpoint (token or revoke). Kept tiny on
        purpose so tests can mock it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [uri] $Uri,

        [Parameter(Mandatory)]
        [hashtable] $Form,

        [hashtable] $Headers = @{}
    )

    $requestHeaders = @{ Accept = 'application/json'; 'User-Agent' = $script:UserAgent }
    foreach ($key in $Headers.Keys) { $requestHeaders[$key] = $Headers[$key] }
    $statusCode = 0
    $requestParameters = @{
        Uri                = $Uri
        Method             = 'Post'
        Body               = $Form
        ContentType        = 'application/x-www-form-urlencoded'
        Headers            = $requestHeaders
        StatusCodeVariable = 'statusCode'
        SkipHttpErrorCheck = $true
        ErrorAction        = 'Stop'
    }
    $content = Invoke-RestMethod @requestParameters
    [pscustomobject]@{
        StatusCode = [int]$statusCode
        Content    = $content
    }
}

function ConvertTo-LinearBase64Url {
    <#
    .SYNOPSIS
        Encodes bytes as unpadded base64url (RFC 4648), as PKCE requires.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )

    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-LinearOAuthSecret {
    <#
    .SYNOPSIS
        Returns a random base64url string from a cryptographic random number generator.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a value in memory only.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateRange(16, 96)]
        [int] $ByteCount = 32
    )

    ConvertTo-LinearBase64Url -Bytes ([System.Security.Cryptography.RandomNumberGenerator]::GetBytes($ByteCount))
}

function New-LinearPkcePair {
    <#
    .SYNOPSIS
        Creates a PKCE code verifier and its S256 code challenge (RFC 7636).
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates values in memory only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $verifier = New-LinearOAuthSecret -ByteCount 32
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes($verifier))
    [pscustomobject]@{
        Verifier  = $verifier
        Challenge = ConvertTo-LinearBase64Url -Bytes $hash
    }
}

function Get-LinearOAuthAuthorizeUrl {
    <#
    .SYNOPSIS
        Builds the URL of Linear's OAuth consent page for the authorization code flow with PKCE.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ClientId,

        [Parameter(Mandatory)]
        [uri] $RedirectUri,

        [Parameter(Mandatory)]
        [string[]] $Scope,

        [Parameter(Mandatory)]
        [string] $State,

        [Parameter(Mandatory)]
        [string] $CodeChallenge
    )

    $query = [ordered]@{
        client_id             = $ClientId
        redirect_uri          = $RedirectUri.AbsoluteUri
        response_type         = 'code'
        scope                 = $Scope -join ','
        state                 = $State
        code_challenge        = $CodeChallenge
        code_challenge_method = 'S256'
    }
    $pairs = foreach ($key in $query.Keys) { '{0}={1}' -f $key, [uri]::EscapeDataString($query[$key]) }
    '{0}?{1}' -f $script:OAuthAuthorizeUrl, ($pairs -join '&')
}

function Start-LinearOAuthBrowser {
    <#
    .SYNOPSIS
        Opens the consent page in the default browser and shows the URL in case it does not open.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'The sign-in URL is an interactive prompt for the person running Connect-Linear.')]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Opens a browser window only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Url
    )

    Write-Host 'Opening your browser to sign in to Linear. If it does not open, go to this address:'
    Write-Host $Url
    try {
        Start-Process -FilePath $Url -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not open a browser ($($_.Exception.Message)). Open the address above yourself."
    }
}

function Wait-LinearOAuthCallback {
    <#
    .SYNOPSIS
        Waits for the browser to come back to the redirect URI and returns the query values.
    .DESCRIPTION
        Listens on the loopback addresses (127.0.0.1 and ::1) at the port of -RedirectUri, then
        opens -BrowserUrl (so a quick redirect cannot arrive before the listener is ready),
        answers the first request to the redirect path with a page the person can close, and returns
        [pscustomobject]@{ Code; State; Error; ErrorDescription }. Requests to other paths, such as
        /favicon.ico, get a 404 and the wait goes on.
    .NOTES
        Throws an ErrorRecord (PSLinear.OAuthFailed) when the port cannot be used or nothing
        arrives within -TimeoutSeconds.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [uri] $RedirectUri,

        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds = 300,

        [string] $BrowserUrl
    )

    $listeners = [System.Collections.Generic.List[System.Net.Sockets.TcpListener]]::new()
    foreach ($address in [System.Net.IPAddress]::Loopback, [System.Net.IPAddress]::IPv6Loopback) {
        try {
            $listener = [System.Net.Sockets.TcpListener]::new($address, $RedirectUri.Port)
            $listener.Start()
            $listeners.Add($listener)
        }
        catch {
            Write-Verbose "Could not listen on $($address):$($RedirectUri.Port): $($_.Exception.Message)"
        }
    }
    if ($listeners.Count -eq 0) {
        $message = ("Could not listen on port $($RedirectUri.Port) for the sign-in callback. Close the program that uses it, " +
            'or use -RedirectUri with another port (and register it in your OAuth application).')
        throw (New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.OAuthFailed' -Category ResourceUnavailable -TargetObject $RedirectUri)
    }

    try {
        $tasks = [System.Threading.Tasks.Task[]]@($listeners | ForEach-Object { $_.AcceptTcpClientAsync() })
        if ($BrowserUrl) { Start-LinearOAuthBrowser -Url $BrowserUrl }
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ($true) {
            # Short waits keep Ctrl+C responsive.
            $index = [System.Threading.Tasks.Task]::WaitAny($tasks, 250)
            if ($index -lt 0) {
                if ([datetime]::UtcNow -ge $deadline) {
                    throw (New-LinearErrorRecord -Message "No sign-in arrived within $TimeoutSeconds seconds. Run Connect-Linear -Browser again." `
                            -ErrorId 'PSLinear.OAuthFailed' -Category OperationTimeout -TargetObject $RedirectUri)
                }
                continue
            }

            $client = $tasks[$index].GetAwaiter().GetResult()
            $tasks[$index] = $listeners[$index].AcceptTcpClientAsync()
            try {
                $stream = $client.GetStream()
                $stream.ReadTimeout = 5000
                $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 4096, $true)
                $requestLine = $reader.ReadLine()
                while ($true) {
                    $header = $reader.ReadLine()
                    if ([string]::IsNullOrEmpty($header)) { break }
                }

                $target = if ($requestLine -match '^GET (\S+) HTTP/') { $Matches[1] } else { '' }
                $path, $queryString = $target.Split('?', 2)
                if ($path -ne $RedirectUri.AbsolutePath) {
                    $body = 'Not found'
                    $status = '404 Not Found'
                }
                else {
                    $values = @{}
                    foreach ($pair in ([string]$queryString).Split('&', [System.StringSplitOptions]::RemoveEmptyEntries)) {
                        $name, $value = $pair.Split('=', 2)
                        $values[[uri]::UnescapeDataString($name)] = [uri]::UnescapeDataString(([string]$value).Replace('+', ' '))
                    }
                    $result = [pscustomobject]@{
                        Code             = $values['code']
                        State            = $values['state']
                        Error            = $values['error']
                        ErrorDescription = $values['error_description']
                    }
                    $outcome = if ($result.Error) { 'Linear sign-in was not completed.' } else { 'You are signed in to Linear.' }
                    $body = ('<!DOCTYPE html><html><head><meta charset="utf-8"><title>PSLinear</title></head>' +
                        "<body style=`"font-family: sans-serif; margin: 3em`"><p>$outcome You can close this tab and return to PowerShell.</p></body></html>")
                    $status = '200 OK'
                }

                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                $headerText = (
                    "HTTP/1.1 $status",
                    'Content-Type: text/html; charset=utf-8',
                    "Content-Length: $($bodyBytes.Length)",
                    'Connection: close',
                    'Cache-Control: no-store',
                    '', ''
                ) -join "`r`n"
                $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headerText)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                $stream.Flush()
            }
            finally {
                $client.Dispose()
            }
            if ($status -eq '200 OK') { return $result }
        }
    }
    finally {
        foreach ($listener in $listeners) { $listener.Stop() }
    }
}

function Request-LinearOAuthToken {
    <#
    .SYNOPSIS
        Exchanges an authorization code, or a refresh token, for an access token.
    .DESCRIPTION
        Returns [pscustomobject]@{ AccessToken; RefreshToken; ExpiresAt; Scope }, with the tokens
        as SecureStrings. RefreshToken is $null when Linear does not return one.
    .PARAMETER MaxRetries
        How many times to send the request again after a network failure, a server error or the
        rate limit. Use it only for grants that can be requested again safely, such as
        client_credentials: Linear replaces a refresh token when it is used, so repeating a
        refresh whose answer was lost would fail.
    .NOTES
        Throws an ErrorRecord (PSLinear.OAuthFailed) with Linear's error description.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Form,

        [ValidateRange(0, 10)]
        [int] $MaxRetries = 0
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $response = Send-LinearOAuthRequest -Uri $script:OAuthTokenUrl -Form $Form
        }
        catch {
            if ($attempt -le $MaxRetries) {
                $delay = Get-LinearRetryDelay -Attempt $attempt
                Write-Verbose "The token request failed ($($_.Exception.Message)). Retrying in $delay ms (retry $attempt of $MaxRetries)."
                Start-Sleep -Milliseconds $delay
                continue
            }
            throw (New-LinearErrorRecord -Message "Could not reach Linear to get an access token: $($_.Exception.Message)" `
                    -ErrorId 'PSLinear.OAuthFailed' -Category ConnectionError -TargetObject $script:OAuthTokenUrl)
        }
        if (($response.StatusCode -ge 500 -or $response.StatusCode -eq 429) -and $attempt -le $MaxRetries) {
            $delay = Get-LinearRetryDelay -Attempt $attempt
            Write-Verbose "The token request returned HTTP $($response.StatusCode). Retrying in $delay ms (retry $attempt of $MaxRetries)."
            Start-Sleep -Milliseconds $delay
            continue
        }
        break
    }
    $accessToken = Get-LinearNestedValue -InputObject $response.Content -Name 'access_token'
    if ($response.StatusCode -ge 400 -or -not $accessToken) {
        $reason = @(
            (Get-LinearNestedValue -InputObject $response.Content -Name 'error_description'),
            (Get-LinearNestedValue -InputObject $response.Content -Name 'error'),
            "HTTP $($response.StatusCode)"
        ) | Where-Object { $_ } | Select-Object -First 1
        throw (New-LinearErrorRecord -Message "Linear did not issue an access token: $reason" `
                -ErrorId 'PSLinear.OAuthFailed' -Category AuthenticationError -StatusCode $response.StatusCode -TargetObject $Form['grant_type'])
    }

    $refreshToken = Get-LinearNestedValue -InputObject $response.Content -Name 'refresh_token'
    $expiresIn = Get-LinearNestedValue -InputObject $response.Content -Name 'expires_in'
    [pscustomobject]@{
        AccessToken  = ConvertTo-LinearSecureString -Value $accessToken
        RefreshToken = if ($refreshToken) { ConvertTo-LinearSecureString -Value $refreshToken } else { $null }
        ExpiresAt    = if ($expiresIn) { [datetimeoffset]::UtcNow.AddSeconds([double]$expiresIn) } else { $null }
        Scope        = Get-LinearNestedValue -InputObject $response.Content -Name 'scope'
    }
}

function Request-LinearClientToken {
    <#
    .SYNOPSIS
        Gets an access token for an OAuth application with the client credentials grant. Returns the
        result of Request-LinearOAuthToken.
    .DESCRIPTION
        The token acts as the application (actor app), lasts 30 days and comes without a refresh
        token, so a new one is requested the same way. Linear revokes the application's other app
        tokens when a token is requested with other scopes, so renewals ask for the same scopes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ClientId,

        [Parameter(Mandatory)]
        [securestring] $ClientSecret,

        [Parameter(Mandatory)]
        [string[]] $Scope,

        [ValidateRange(0, 10)]
        [int] $MaxRetries = 0
    )

    Request-LinearOAuthToken -MaxRetries $MaxRetries -Form @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = [System.Net.NetworkCredential]::new('', $ClientSecret).Password
        scope         = $Scope -join ','
    }
}

function Save-LinearOAuthSecret {
    <#
    .SYNOPSIS
        Saves the context's refresh token to its SecretManagement secret, so a later
        Connect-Linear -Browser -SecretName can sign in without the browser.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called by Connect-Linear and token refreshes, which the person started; the secret only holds the current refresh token.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Context
    )

    if (-not $Context.SecretName -or $null -eq $Context.RefreshToken) { return }
    $secretParameters = @{ Name = $Context.SecretName; Secret = $Context.RefreshToken; ErrorAction = 'Stop' }
    if ($Context.Vault) { $secretParameters['Vault'] = $Context.Vault }
    Set-Secret @secretParameters
}

function Update-LinearOAuthToken {
    <#
    .SYNOPSIS
        Gets a new access token with the context's refresh token, and saves the new refresh token,
        or with the context's client credentials.
    .NOTES
        Linear issues a new refresh token with every refresh, so the saved secret is updated too.
        Throws an ErrorRecord (PSLinear.TokenRefreshFailed) that asks the person to sign in again.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Renews the session credential in memory, as part of a request the person started.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Context
    )

    if ($null -ne $Context.ClientSecret) {
        try {
            $tokens = Request-LinearClientToken -ClientId $Context.ClientId -ClientSecret $Context.ClientSecret -Scope $Context.Scope -MaxRetries $Context.MaxRetries
        }
        catch {
            throw (New-LinearErrorRecord -Message "Could not get a new Linear access token with the client credentials ($($_.Exception.Message)). Check the client secret, then run Connect-Linear -ClientCredential again." `
                    -ErrorId 'PSLinear.TokenRefreshFailed' -Category AuthenticationError)
        }
    }
    else {
        $form = @{
            grant_type    = 'refresh_token'
            refresh_token = [System.Net.NetworkCredential]::new('', $Context.RefreshToken).Password
            client_id     = $Context.ClientId
        }
        try {
            $tokens = Request-LinearOAuthToken -Form $form
        }
        catch {
            throw (New-LinearErrorRecord -Message "The Linear sign-in has expired and could not be renewed ($($_.Exception.Message)). Run Connect-Linear -Browser again." `
                    -ErrorId 'PSLinear.TokenRefreshFailed' -Category AuthenticationError)
        }
    }
    $Context.Token = $tokens.AccessToken
    if ($null -ne $tokens.RefreshToken) { $Context.RefreshToken = $tokens.RefreshToken }
    $Context.ExpiresAt = $tokens.ExpiresAt
    Write-Verbose "Renewed the Linear access token; it expires at $($tokens.ExpiresAt)."
    try {
        Save-LinearOAuthSecret -Context $Context
    }
    catch {
        Write-Warning "Could not save the renewed sign-in to secret '$($Context.SecretName)': $($_.Exception.Message)"
    }
}

function Test-LinearTokenRenewable {
    <#
    .SYNOPSIS
        Returns whether the context holds an OAuth token that PSLinear can renew on its own: with a
        refresh token, or with the client credentials.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object] $Context
    )

    $Context.AuthScheme -eq 'OAuth' -and ($null -ne $Context.RefreshToken -or $null -ne $Context.ClientSecret)
}

function Test-LinearTokenExpiring {
    <#
    .SYNOPSIS
        Returns whether the context holds an OAuth token that expires within five minutes and can be renewed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object] $Context
    )

    (Test-LinearTokenRenewable -Context $Context) -and $null -ne $Context.ExpiresAt -and
    [datetimeoffset]::UtcNow -ge $Context.ExpiresAt.AddMinutes(-5)
}

function Invoke-LinearOAuthLogin {
    <#
    .SYNOPSIS
        Runs the browser sign-in: opens Linear's consent page, waits for the callback and exchanges
        the code for tokens. Returns the result of Request-LinearOAuthToken.
    .NOTES
        Throws an ErrorRecord (PSLinear.OAuthFailed) when the sign-in is denied, times out or
        comes back with the wrong state.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ClientId,

        [Parameter(Mandatory)]
        [string[]] $Scope,

        [Parameter(Mandatory)]
        [uri] $RedirectUri,

        [int] $TimeoutSeconds = 300
    )

    $pkce = New-LinearPkcePair
    $state = New-LinearOAuthSecret -ByteCount 16
    $url = Get-LinearOAuthAuthorizeUrl -ClientId $ClientId -RedirectUri $RedirectUri -Scope $Scope -State $state -CodeChallenge $pkce.Challenge
    $callback = Wait-LinearOAuthCallback -RedirectUri $RedirectUri -TimeoutSeconds $TimeoutSeconds -BrowserUrl $url

    if ($callback.Error) {
        $reason = if ($callback.ErrorDescription) { "$($callback.Error): $($callback.ErrorDescription)" } else { $callback.Error }
        throw (New-LinearErrorRecord -Message "Linear sign-in was not completed ($reason)." `
                -ErrorId 'PSLinear.OAuthFailed' -Category AuthenticationError -TargetObject $callback.Error)
    }
    if ($callback.State -ne $state) {
        throw (New-LinearErrorRecord -Message 'The sign-in callback did not match this sign-in (state mismatch), so it was ignored. Run Connect-Linear -Browser again.' `
                -ErrorId 'PSLinear.OAuthFailed' -Category SecurityError)
    }
    if (-not $callback.Code) {
        throw (New-LinearErrorRecord -Message 'The sign-in callback did not include an authorization code.' -ErrorId 'PSLinear.OAuthFailed' -Category AuthenticationError)
    }

    Request-LinearOAuthToken -Form @{
        grant_type    = 'authorization_code'
        code          = $callback.Code
        redirect_uri  = $RedirectUri.AbsoluteUri
        client_id     = $ClientId
        code_verifier = $pkce.Verifier
    }
}
