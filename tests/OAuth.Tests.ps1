BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force

    function New-TestTokenResponse {
        # A token endpoint answer: 200 with tokens, or an OAuth error.
        param([string] $AccessToken = 'access-1', [string] $RefreshToken = 'refresh-1', [int] $ExpiresIn = 86399, [string] $ErrorCode, [int] $StatusCode = 200)
        $content = if ($ErrorCode) {
            @{ error = $ErrorCode; error_description = "The grant is $ErrorCode." }
        }
        else {
            $tokens = @{ access_token = $AccessToken; token_type = 'Bearer'; expires_in = $ExpiresIn; scope = 'read,write' }
            # Client credentials tokens come without a refresh token.
            if ($RefreshToken) { $tokens['refresh_token'] = $RefreshToken }
            $tokens
        }
        [pscustomobject]@{ StatusCode = $StatusCode; Content = ConvertTo-TestObject -InputObject $content }
    }

    function Get-TestFreePort {
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $probe.Start()
        $port = $probe.LocalEndpoint.Port
        $probe.Stop()
        $port
    }

    $script:viewerResponse = {
        New-LinearTestResponse -Data @{
            viewer       = @{ id = 'user-1'; name = 'Ada Lovelace'; displayName = 'ada'; email = 'ada@example.com'; admin = $true; active = $true }
            organization = @{ id = 'org-1'; name = 'Acme'; urlKey = 'acme' }
        }
    }
}

Describe 'OAuth helpers' {
    It 'encodes base64url without padding' {
        InModuleScope PSLinear { ConvertTo-LinearBase64Url -Bytes ([byte[]](251, 255, 191)) } | Should -Be '-_-_'
        InModuleScope PSLinear { ConvertTo-LinearBase64Url -Bytes ([byte[]](1)) } | Should -Be 'AQ'
    }

    It 'creates a PKCE verifier and its S256 challenge' {
        $pair = InModuleScope PSLinear { New-LinearPkcePair }
        $pair.Verifier | Should -Match '^[A-Za-z0-9_-]{43}$'
        $expected = InModuleScope PSLinear -Parameters @{ Verifier = $pair.Verifier } {
            param($Verifier)
            ConvertTo-LinearBase64Url -Bytes ([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes($Verifier)))
        }
        $pair.Challenge | Should -Be $expected
        # RFC 7636, appendix B.
        InModuleScope PSLinear {
            ConvertTo-LinearBase64Url -Bytes ([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk')))
        } | Should -Be 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM'
    }

    It 'builds the consent URL with every parameter encoded' {
        $url = InModuleScope PSLinear {
            Get-LinearOAuthAuthorizeUrl -ClientId 'client 1' -RedirectUri 'http://localhost:47821/callback' -Scope 'read', 'write' -State 'state-1' -CodeChallenge 'challenge-1'
        }
        $url | Should -BeLike 'https://linear.app/oauth/authorize?*'
        $url | Should -Match 'client_id=client%201'
        $url | Should -Match 'redirect_uri=http%3A%2F%2Flocalhost%3A47821%2Fcallback'
        $url | Should -Match 'response_type=code'
        $url | Should -Match 'scope=read%2Cwrite'
        $url | Should -Match 'state=state-1'
        $url | Should -Match 'code_challenge=challenge-1&code_challenge_method=S256'
    }

    Context 'Wait-LinearOAuthCallback' {
        BeforeEach {
            $script:port = Get-TestFreePort
            $script:client = [System.Net.Http.HttpClient]::new()
            $script:pages = [System.Collections.Generic.List[object]]::new()
        }

        AfterEach {
            $script:client.Dispose()
        }

        It 'answers on the loopback address and returns the code and state' {
            # The fake browser follows the redirect once the listener is up.
            Mock -ModuleName PSLinear Start-LinearOAuthBrowser {
                $script:pages.Add($script:client.GetAsync("http://127.0.0.1:$($script:port)/favicon.ico"))
                $script:pages.Add($script:client.GetStringAsync("http://127.0.0.1:$($script:port)/callback?code=abc%20123&state=xyz"))
            }
            $result = InModuleScope PSLinear -Parameters @{ Port = $script:port } {
                param($Port)
                Wait-LinearOAuthCallback -RedirectUri "http://localhost:$Port/callback" -TimeoutSeconds 20 -BrowserUrl 'https://linear.app/oauth/authorize'
            }
            $result.Code | Should -Be 'abc 123'
            $result.State | Should -Be 'xyz'
            $result.Error | Should -BeNullOrEmpty
            $script:pages[1].GetAwaiter().GetResult() | Should -Match 'You are signed in to Linear'
        }

        It 'returns the error Linear sends when the sign-in is denied' {
            Mock -ModuleName PSLinear Start-LinearOAuthBrowser {
                $script:pages.Add($script:client.GetStringAsync("http://127.0.0.1:$($script:port)/callback?error=access_denied&error_description=The+user+denied+access&state=xyz"))
            }
            $result = InModuleScope PSLinear -Parameters @{ Port = $script:port } {
                param($Port)
                Wait-LinearOAuthCallback -RedirectUri "http://localhost:$Port/callback" -TimeoutSeconds 20 -BrowserUrl 'https://linear.app/oauth/authorize'
            }
            $result.Error | Should -Be 'access_denied'
            $result.ErrorDescription | Should -Be 'The user denied access'
            $script:pages[0].GetAwaiter().GetResult() | Should -Match 'not completed'
        }

        It 'gives up after the timeout' {
            {
                InModuleScope PSLinear -Parameters @{ Port = $script:port } {
                    param($Port)
                    Wait-LinearOAuthCallback -RedirectUri "http://localhost:$Port/callback" -TimeoutSeconds 1
                }
            } | Should -Throw -ErrorId 'PSLinear.OAuthFailed*' -ExpectedMessage '*within 1 seconds*'
        }

        It 'explains when the port is in use' {
            $blockers = foreach ($address in [System.Net.IPAddress]::Loopback, [System.Net.IPAddress]::IPv6Loopback) {
                try { $blocker = [System.Net.Sockets.TcpListener]::new($address, $script:port); $blocker.Start(); $blocker } catch { $null = $_ }
            }
            try {
                {
                    InModuleScope PSLinear -Parameters @{ Port = $script:port } {
                        param($Port)
                        Wait-LinearOAuthCallback -RedirectUri "http://localhost:$Port/callback" -TimeoutSeconds 1
                    }
                } | Should -Throw -ErrorId 'PSLinear.OAuthFailed*' -ExpectedMessage "*port $($script:port)*"
            }
            finally {
                foreach ($blocker in $blockers) { if ($null -ne $blocker) { $blocker.Stop() } }
            }
        }
    }
}

Describe 'Connect-Linear -Browser' {
    BeforeEach {
        $env:LINEAR_API_KEY = $null
        $env:LINEAR_OAUTH_CLIENT_ID = $null
        InModuleScope PSLinear { $script:LinearContext = $null }
        Mock -ModuleName PSLinear Send-LinearHttpRequest $script:viewerResponse
        Mock -ModuleName PSLinear Start-LinearOAuthBrowser {}
        $script:browserUrl = $null
        # The fake browser approves the sign-in and comes back with the state it was given.
        Mock -ModuleName PSLinear Wait-LinearOAuthCallback {
            $script:browserUrl = $BrowserUrl
            $state = [uri]::UnescapeDataString(([regex]::Match($BrowserUrl, 'state=([^&]+)')).Groups[1].Value)
            [pscustomobject]@{ Code = 'code-1'; State = $state; Error = $null; ErrorDescription = $null }
        }
        Mock -ModuleName PSLinear Send-LinearOAuthRequest { New-TestTokenResponse }
    }

    AfterEach {
        $env:LINEAR_OAUTH_CLIENT_ID = $null
        foreach ($name in 'Get-Secret', 'Set-Secret', 'Remove-Secret') {
            if (Test-Path -Path "Function:\$name") { Remove-Item -Path "Function:\$name" }
        }
    }

    It 'signs in through the browser and connects with the OAuth token' {
        $context = Connect-Linear -Browser -ClientId 'client-1' -PassThru
        $context.AuthScheme | Should -Be 'OAuth'
        $context.ClientId | Should -Be 'client-1'
        $context.RefreshToken | Should -BeOfType [securestring]
        ($context.ExpiresAt - [datetimeoffset]::UtcNow).TotalHours | Should -BeGreaterThan 23
        $context.Organization | Should -Be 'Acme'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { $Headers.Authorization -eq 'Bearer access-1' }
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            $Uri.AbsoluteUri -eq 'https://api.linear.app/oauth/token' -and
            $Form['grant_type'] -eq 'authorization_code' -and $Form['code'] -eq 'code-1' -and $Form['client_id'] -eq 'client-1' -and
            $Form['redirect_uri'] -eq 'http://localhost:47821/callback' -and $Form['code_verifier'] -match '^[A-Za-z0-9_-]{43}$' -and
            -not $Form.ContainsKey('client_secret')
        }
        ($context | Out-String) | Should -Not -Match 'access-1|refresh-1'
    }

    It 'sends the challenge that matches the verifier it exchanges' {
        $script:verifier = $null
        Mock -ModuleName PSLinear Send-LinearOAuthRequest { $script:verifier = $Form['code_verifier']; New-TestTokenResponse }
        Connect-Linear -Browser -ClientId 'client-1' -Scope read, write, issues:create
        $challenge = [regex]::Match($script:browserUrl, 'code_challenge=([^&]+)').Groups[1].Value
        $expected = InModuleScope PSLinear -Parameters @{ Verifier = $script:verifier } {
            param($Verifier)
            ConvertTo-LinearBase64Url -Bytes ([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::ASCII.GetBytes($Verifier)))
        }
        $challenge | Should -Be $expected
        $script:browserUrl | Should -Match 'scope=read%2Cwrite%2Cissues%3Acreate'
    }

    It 'signs in through PSL by default, unless LINEAR_OAUTH_CLIENT_ID or -ClientId names another application' {
        (Connect-Linear -Browser -PassThru).ClientId | Should -Be '410663939bc11881898c33ce6ba801db'
        $script:browserUrl | Should -Match 'client_id=410663939bc11881898c33ce6ba801db'
        $env:LINEAR_OAUTH_CLIENT_ID = 'client-env'
        (Connect-Linear -Browser -PassThru).ClientId | Should -Be 'client-env'
        (Connect-Linear -Browser -ClientId 'client-param' -PassThru).ClientId | Should -Be 'client-param'
    }

    It 'uses -RedirectUri for the callback and the token request' {
        Connect-Linear -Browser -ClientId 'client-1' -RedirectUri 'http://127.0.0.1:50000/callback'
        Should -Invoke Wait-LinearOAuthCallback -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { $RedirectUri.Port -eq 50000 }
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { $Form['redirect_uri'] -eq 'http://127.0.0.1:50000/callback' }
    }

    It 'refuses a callback with the wrong state, without asking for a token' {
        Mock -ModuleName PSLinear Wait-LinearOAuthCallback { [pscustomobject]@{ Code = 'code-1'; State = 'forged'; Error = $null; ErrorDescription = $null } }
        { Connect-Linear -Browser -ClientId 'client-1' } | Should -Throw -ErrorId 'PSLinear.OAuthFailed*' -ExpectedMessage '*state mismatch*'
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 0 -Exactly
        InModuleScope PSLinear { $script:LinearContext } | Should -BeNullOrEmpty
    }

    It 'reports a denied sign-in and a rejected code' {
        Mock -ModuleName PSLinear Wait-LinearOAuthCallback { [pscustomobject]@{ Code = $null; State = 'x'; Error = 'access_denied'; ErrorDescription = 'The user denied access' } }
        { Connect-Linear -Browser -ClientId 'client-1' } | Should -Throw -ErrorId 'PSLinear.OAuthFailed*' -ExpectedMessage '*access_denied: The user denied access*'
        Mock -ModuleName PSLinear Wait-LinearOAuthCallback {
            $state = [uri]::UnescapeDataString(([regex]::Match($BrowserUrl, 'state=([^&]+)')).Groups[1].Value)
            [pscustomobject]@{ Code = 'code-1'; State = $state; Error = $null; ErrorDescription = $null }
        }
        Mock -ModuleName PSLinear Send-LinearOAuthRequest { New-TestTokenResponse -ErrorCode 'invalid_grant' -StatusCode 400 }
        { Connect-Linear -Browser -ClientId 'client-1' } | Should -Throw -ErrorId 'PSLinear.OAuthFailed*' -ExpectedMessage '*The grant is invalid_grant.*'
    }

    Context 'with -SecretName' {
        BeforeEach {
            $script:savedSecrets = @{}
            function global:Get-Secret { param($Name, $Vault) $null = $Vault; if ($script:savedSecrets.ContainsKey($Name)) { $script:savedSecrets[$Name] } else { throw "Secret $Name not found" } }
            function global:Set-Secret { param($Name, $Secret, $Vault) $null = $Vault; $script:savedSecrets[$Name] = [System.Net.NetworkCredential]::new('', $Secret).Password }
            function global:Remove-Secret { param($Name, $Vault) $null = $Vault; $script:savedSecrets.Remove($Name) }
        }

        It 'signs in through the browser the first time and saves the refresh token' {
            Connect-Linear -Browser -ClientId 'client-1' -SecretName 'LinearSignIn'
            Should -Invoke Wait-LinearOAuthCallback -ModuleName PSLinear -Times 1 -Exactly
            $script:savedSecrets['LinearSignIn'] | Should -Be 'refresh-1'
        }

        It 'signs in with a saved refresh token without the browser, and saves the new one' {
            $script:savedSecrets['LinearSignIn'] = 'refresh-saved'
            Mock -ModuleName PSLinear Send-LinearOAuthRequest { New-TestTokenResponse -AccessToken 'access-2' -RefreshToken 'refresh-2' }
            Connect-Linear -Browser -ClientId 'client-1' -SecretName 'LinearSignIn'
            Should -Invoke Wait-LinearOAuthCallback -ModuleName PSLinear -Times 0 -Exactly
            Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $Form['grant_type'] -eq 'refresh_token' -and $Form['refresh_token'] -eq 'refresh-saved' -and $Form['client_id'] -eq 'client-1'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { $Headers.Authorization -eq 'Bearer access-2' }
            $script:savedSecrets['LinearSignIn'] | Should -Be 'refresh-2'
        }

        It 'falls back to the browser when the saved refresh token no longer works' {
            $script:savedSecrets['LinearSignIn'] = 'refresh-revoked'
            Mock -ModuleName PSLinear Send-LinearOAuthRequest {
                if ($Form['grant_type'] -eq 'refresh_token') { New-TestTokenResponse -ErrorCode 'invalid_grant' -StatusCode 400 } else { New-TestTokenResponse -RefreshToken 'refresh-new' }
            }
            Connect-Linear -Browser -ClientId 'client-1' -SecretName 'LinearSignIn'
            Should -Invoke Wait-LinearOAuthCallback -ModuleName PSLinear -Times 1 -Exactly
            $script:savedSecrets['LinearSignIn'] | Should -Be 'refresh-new'
        }

        It 'explains how to install SecretManagement when it is missing' {
            # Mocked rather than removed, so the test does not depend on whether SecretManagement is installed.
            Mock -ModuleName PSLinear Get-Command { $null } -ParameterFilter { $Name -eq 'Set-Secret' }
            { Connect-Linear -Browser -ClientId 'client-1' -SecretName 'LinearSignIn' } | Should -Throw -ExpectedMessage '*Microsoft.PowerShell.SecretManagement*'
            Should -Invoke Wait-LinearOAuthCallback -ModuleName PSLinear -Times 0 -Exactly
        }
    }
}

Describe 'OAuth token renewal' {
    BeforeEach {
        $env:LINEAR_API_KEY = $null
        $script:savedSecrets = @{}
        function global:Set-Secret { param($Name, $Secret, $Vault) $null = $Vault; $script:savedSecrets[$Name] = [System.Net.NetworkCredential]::new('', $Secret).Password }
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'access-old') -AuthScheme 'OAuth' -MaxRetries 0 `
                -RefreshToken (ConvertTo-LinearSecureString -Value 'refresh-old') -ExpiresAt ([datetimeoffset]::UtcNow.AddHours(12)) -ClientId 'client-1' -SecretName 'LinearSignIn'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest $script:viewerResponse
        Mock -ModuleName PSLinear Send-LinearOAuthRequest { New-TestTokenResponse -AccessToken 'access-new' -RefreshToken 'refresh-new' }
    }

    AfterEach {
        Remove-Item -Path Function:\Set-Secret -ErrorAction SilentlyContinue
    }

    It 'does not renew a token that is still valid' {
        $null = Get-LinearViewer
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 0 -Exactly
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { $Headers.Authorization -eq 'Bearer access-old' }
    }

    It 'renews a token about to expire before the request, and saves the new refresh token' {
        InModuleScope PSLinear { $script:LinearContext.ExpiresAt = [datetimeoffset]::UtcNow.AddMinutes(2) }
        $null = Get-LinearViewer
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            $Form['grant_type'] -eq 'refresh_token' -and $Form['refresh_token'] -eq 'refresh-old' -and $Form['client_id'] -eq 'client-1'
        }
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { $Headers.Authorization -eq 'Bearer access-new' }
        $script:savedSecrets['LinearSignIn'] | Should -Be 'refresh-new'
        $expiresAt = InModuleScope PSLinear { $script:LinearContext.ExpiresAt }
        ($expiresAt - [datetimeoffset]::UtcNow).TotalHours | Should -BeGreaterThan 23
    }

    It 'renews once and retries when Linear rejects the token' {
        $script:calls = 0
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $script:calls++
            if ($Headers.Authorization -eq 'Bearer access-old') {
                return New-LinearTestResponse -StatusCode 401 -Errors @(New-LinearTestError -Message 'Authentication required' -Code 'AUTHENTICATION_ERROR')
            }
            & $script:viewerResponse
        }
        (Get-LinearViewer).Name | Should -Be 'Ada Lovelace'
        $script:calls | Should -Be 2
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly
    }

    It 'stops after one renewal when the new token is rejected too' {
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            New-LinearTestResponse -StatusCode 401 -Errors @(New-LinearTestError -Message 'Authentication required' -Code 'AUTHENTICATION_ERROR')
        }
        { Get-LinearViewer } | Should -Throw -ErrorId 'PSLinear.AuthenticationFailed*'
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly
    }

    It 'asks to sign in again when the renewal fails' {
        InModuleScope PSLinear { $script:LinearContext.ExpiresAt = [datetimeoffset]::UtcNow.AddMinutes(-1) }
        Mock -ModuleName PSLinear Send-LinearOAuthRequest { New-TestTokenResponse -ErrorCode 'invalid_grant' -StatusCode 400 }
        { Get-LinearViewer } | Should -Throw -ErrorId 'PSLinear.TokenRefreshFailed*' -ExpectedMessage '*Connect-Linear -Browser again*'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
    }

    It 'never renews API keys or access tokens without a refresh token' {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey' -MaxRetries 0
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            New-LinearTestResponse -StatusCode 401 -Errors @(New-LinearTestError -Message 'Authentication required' -Code 'AUTHENTICATION_ERROR')
        }
        { Get-LinearViewer } | Should -Throw -ErrorId 'PSLinear.AuthenticationFailed*'
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 0 -Exactly
    }
}

Describe 'Connect-Linear -ClientCredential' {
    BeforeEach {
        $env:LINEAR_API_KEY = $null
        InModuleScope PSLinear { $script:LinearContext = $null }
        Mock -ModuleName PSLinear Send-LinearHttpRequest $script:viewerResponse
        Mock -ModuleName PSLinear Send-LinearOAuthRequest { New-TestTokenResponse -AccessToken 'app-1' -RefreshToken '' -ExpiresIn 2591999 }
        Mock -ModuleName PSLinear Start-Sleep {}
        $script:credential = [pscredential]::new('client-1', (ConvertTo-SecureString -String 'secret-1' -AsPlainText -Force))
    }

    It 'requests an app token with the client credentials grant and connects with it' {
        $context = Connect-Linear -ClientCredential $script:credential -PassThru
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            $Form['grant_type'] -eq 'client_credentials' -and $Form['client_id'] -eq 'client-1' -and
            $Form['client_secret'] -eq 'secret-1' -and $Form['scope'] -eq 'read,write' -and -not $Form.ContainsKey('refresh_token')
        }
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { $Headers.Authorization -eq 'Bearer app-1' }
        $context.AuthScheme | Should -Be 'OAuth'
        $context.ClientId | Should -Be 'client-1'
        $context.RefreshToken | Should -BeNullOrEmpty
        ($context.ExpiresAt - [datetimeoffset]::UtcNow).TotalDays | Should -BeGreaterThan 29
    }

    It 'asks for the scopes given with -Scope' {
        Connect-Linear -ClientCredential $script:credential -Scope read, issues:create, comments:create
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { $Form['scope'] -eq 'read,issues:create,comments:create' }
        (InModuleScope PSLinear { $script:LinearContext.Scope }) | Should -Be @('read', 'issues:create', 'comments:create')
    }

    It 'accepts a user name that the Windows credential prompt prefixed with a backslash' {
        $credential = [pscredential]::new('\client-1', (ConvertTo-SecureString -String 'secret-1' -AsPlainText -Force))
        Connect-Linear -ClientCredential $credential
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { $Form['client_id'] -eq 'client-1' }
    }

    It 'never keeps the client secret or the token as plain text' {
        $context = Connect-Linear -ClientCredential $script:credential -PassThru
        $context.ClientSecret | Should -BeOfType [securestring]
        $context.Token | Should -BeOfType [securestring]
        @($context.PSObject.Properties.Value | Where-Object { $_ -is [string] -and $_ -in 'secret-1', 'app-1' }) | Should -HaveCount 0
        ($context | Out-String) | Should -Not -Match 'secret-1|app-1'
    }

    It 'retries the token request after a network failure' {
        $script:tokenCalls = 0
        Mock -ModuleName PSLinear Send-LinearOAuthRequest {
            $script:tokenCalls++
            if ($script:tokenCalls -eq 1) { throw [System.Net.Http.HttpRequestException]::new('No such host') }
            New-TestTokenResponse -AccessToken 'app-1' -RefreshToken ''
        }
        Connect-Linear -ClientCredential $script:credential
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 2 -Exactly
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { $Headers.Authorization -eq 'Bearer app-1' }
    }

    It 'reports why Linear refused the credentials, and stays disconnected' {
        Mock -ModuleName PSLinear Send-LinearOAuthRequest {
            [pscustomobject]@{
                StatusCode = 400
                Content    = ConvertTo-TestObject -InputObject @{ error = 'unauthorized_client'; error_description = 'Client does not support the client_credentials grant type' }
            }
        }
        { Connect-Linear -ClientCredential $script:credential } |
            Should -Throw -ErrorId 'PSLinear.OAuthFailed*' -ExpectedMessage '*does not support the client_credentials grant type*'
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly
        InModuleScope PSLinear { $script:LinearContext } | Should -BeNullOrEmpty
    }

    It 'refuses a credential without a client secret' {
        $credential = [pscredential]::new('client-1', [securestring]::new())
        { Connect-Linear -ClientCredential $credential } | Should -Throw -ErrorId 'PSLinear.InvalidCredential*' -ExpectedMessage '*client secret*'
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 0 -Exactly
    }
}

Describe 'Client credentials token renewal' {
    BeforeEach {
        $env:LINEAR_API_KEY = $null
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'app-old') -AuthScheme 'OAuth' -MaxRetries 0 `
                -ExpiresAt ([datetimeoffset]::UtcNow.AddDays(20)) -ClientId 'client-1' -ClientSecret (ConvertTo-LinearSecureString -Value 'secret-1') -Scope 'read', 'write'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest $script:viewerResponse
        Mock -ModuleName PSLinear Send-LinearOAuthRequest { New-TestTokenResponse -AccessToken 'app-new' -RefreshToken '' -ExpiresIn 2591999 }
    }

    It 'requests a new app token with the same scopes before the old one expires' {
        InModuleScope PSLinear { $script:LinearContext.ExpiresAt = [datetimeoffset]::UtcNow.AddMinutes(2) }
        $null = Get-LinearViewer
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            $Form['grant_type'] -eq 'client_credentials' -and $Form['client_secret'] -eq 'secret-1' -and $Form['scope'] -eq 'read,write'
        }
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { $Headers.Authorization -eq 'Bearer app-new' }
    }

    It 'requests a new app token once when Linear rejects the current one' {
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            if ($Headers.Authorization -eq 'Bearer app-old') {
                return New-LinearTestResponse -StatusCode 401 -Errors @(New-LinearTestError -Message 'Authentication required' -Code 'AUTHENTICATION_ERROR')
            }
            & $script:viewerResponse
        }
        (Get-LinearViewer).Name | Should -Be 'Ada Lovelace'
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly
    }

    It 'asks to connect again when the client credentials no longer work' {
        InModuleScope PSLinear { $script:LinearContext.ExpiresAt = [datetimeoffset]::UtcNow.AddMinutes(-1) }
        Mock -ModuleName PSLinear Send-LinearOAuthRequest { New-TestTokenResponse -ErrorCode 'invalid_client' -StatusCode 401 }
        { Get-LinearViewer } | Should -Throw -ErrorId 'PSLinear.TokenRefreshFailed*' -ExpectedMessage '*Connect-Linear -ClientCredential again*'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
    }
}

Describe 'Disconnect-Linear -Revoke' {
    BeforeEach {
        $env:LINEAR_API_KEY = $null
        $script:removedSecrets = [System.Collections.Generic.List[string]]::new()
        function global:Remove-Secret { param($Name, $Vault) $null = $Vault; $script:removedSecrets.Add($Name) }
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'access-1') -AuthScheme 'OAuth' `
                -RefreshToken (ConvertTo-LinearSecureString -Value 'refresh-1') -ExpiresAt ([datetimeoffset]::UtcNow.AddHours(12)) -ClientId 'client-1' -SecretName 'LinearSignIn'
        }
        Mock -ModuleName PSLinear Send-LinearOAuthRequest { [pscustomobject]@{ StatusCode = 200; Content = $null } }
    }

    AfterEach {
        Remove-Item -Path Function:\Remove-Secret -ErrorAction SilentlyContinue
    }

    It 'revokes both tokens, removes the saved sign-in and disconnects' {
        Disconnect-Linear -Revoke
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            $Uri.AbsoluteUri -eq 'https://api.linear.app/oauth/revoke' -and $Form['token'] -eq 'access-1' -and $Form['token_type_hint'] -eq 'access_token' -and
            $Headers['Authorization'] -eq 'Bearer access-1'
        }
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { $Form['token'] -eq 'refresh-1' -and $Form['token_type_hint'] -eq 'refresh_token' }
        $script:removedSecrets | Should -Be @('LinearSignIn')
        InModuleScope PSLinear { $script:LinearContext } | Should -BeNullOrEmpty
    }

    It 'only warns for an API key, and still disconnects' {
        InModuleScope PSLinear { $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey' }
        Disconnect-Linear -Revoke -WarningVariable revokeWarnings -WarningAction SilentlyContinue
        $revokeWarnings.Count | Should -Be 1
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 0 -Exactly
        InModuleScope PSLinear { $script:LinearContext } | Should -BeNullOrEmpty
    }

    It 'does nothing with -WhatIf' {
        Disconnect-Linear -Revoke -WhatIf
        Should -Invoke Send-LinearOAuthRequest -ModuleName PSLinear -Times 0 -Exactly
        InModuleScope PSLinear { $script:LinearContext } | Should -Not -BeNullOrEmpty
    }
}
