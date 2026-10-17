function Connect-Linear {
    <#
    .SYNOPSIS
        Connects the current PowerShell session to the Linear API.

    .DESCRIPTION
        Stores credentials for the Linear GraphQL API in the current session and, unless
        -SkipValidation is used, verifies them by fetching the authenticated user and
        organization.

        Credentials can come from a personal API key (prompted securely when omitted),
        a sign-in in the browser (-Browser), an OAuth access token, a secret in a
        Microsoft.PowerShell.SecretManagement vault, or the LINEAR_API_KEY environment variable.

        With -Browser, Linear's consent page opens in your browser (OAuth 2.0 with PKCE, so no
        client secret is involved) and PowerShell receives the result on a local address. This
        needs the client id of a Linear OAuth application whose callback URLs include the
        redirect URI (http://localhost:47821/callback unless you change -RedirectUri). Linear's
        access tokens last 24 hours; PSLinear renews them automatically with the refresh token.
        Add -SecretName to save the refresh token in a SecretManagement vault, so the next
        Connect-Linear -Browser -SecretName in a new session signs in without the browser.

        The token is kept as a SecureString and is only converted to plain text when a
        request header is built. Nothing is written to disk, except the refresh token in the
        vault you choose with -Browser -SecretName.

        Commands also connect implicitly when LINEAR_API_KEY is set, so Connect-Linear is
        optional in CI pipelines.

    .PARAMETER ApiKey
        A personal API key, created under Settings > Security & access in Linear.
        If omitted, you are prompted for it without echoing.

    .PARAMETER AccessToken
        An OAuth 2.0 access token. It is sent with the Bearer scheme.

    .PARAMETER Browser
        Signs in through Linear's consent page in the browser.

    .PARAMETER ClientId
        The client id of the Linear OAuth application to sign in with (Settings > API > OAuth
        applications in Linear). Defaults to the LINEAR_OAUTH_CLIENT_ID environment variable.
        The client id is not a secret.

    .PARAMETER Scope
        The permissions to ask for: read, write, issues:create, comments:create,
        timeSchedule:write or admin. Defaults to read and write.

    .PARAMETER RedirectUri
        The local address the browser returns to after you approve the sign-in. It must be one
        of the OAuth application's callback URLs, and its port must be free. Defaults to
        http://localhost:47821/callback.

    .PARAMETER TimeoutSeconds
        How long to wait for the sign-in in the browser. Defaults to 300 seconds.

    .PARAMETER SecretName
        The name of a secret in a SecretManagement vault. Without -Browser, the secret holds the
        API key or token to connect with. With -Browser, it holds the refresh token: PSLinear
        signs in with it when it is still valid, and saves the new refresh token after every
        sign-in and renewal. Requires the Microsoft.PowerShell.SecretManagement module.

    .PARAMETER Vault
        The SecretManagement vault for -SecretName. Uses the default vault when omitted.

    .PARAMETER FromEnvironment
        Reads the credential from the LINEAR_API_KEY environment variable.

    .PARAMETER TokenType
        Whether a credential read from a vault or the environment is a personal API key
        (default) or an OAuth access token.

    .PARAMETER Endpoint
        The GraphQL endpoint. Defaults to https://api.linear.app/graphql.

    .PARAMETER MaxRetries
        How many times to retry a request that was rate limited or failed with a server or
        network error. Defaults to 3.

    .PARAMETER SkipValidation
        Stores the credential without calling the API to verify it.

    .PARAMETER PassThru
        Returns the connection object.

    .EXAMPLE
        Connect-Linear

        Prompts securely for a personal API key and connects.

    .EXAMPLE
        Connect-Linear -SecretName 'LinearApiKey' -PassThru

        Reads the API key from the default SecretManagement vault and returns the connection.

    .EXAMPLE
        $env:LINEAR_API_KEY = $apiKeyFromPipelineSecret
        Connect-Linear -FromEnvironment

        Connects using the LINEAR_API_KEY environment variable, typical in CI.

    .EXAMPLE
        Connect-Linear -AccessToken (Read-Host -AsSecureString 'OAuth token')

        Connects with an OAuth access token.

    .EXAMPLE
        Connect-Linear -Browser -ClientId 'a1b2c3d4e5f6...'

        Signs in through the browser with your OAuth application.

    .EXAMPLE
        Connect-Linear -Browser -SecretName 'LinearSignIn'

        Signs in with the client id from LINEAR_OAUTH_CLIENT_ID. The first time, the browser
        opens; later sessions reuse the refresh token saved in the default vault.

    .INPUTS
        None.

    .OUTPUTS
        PSLinear.Context when -PassThru is used.

    .LINK
        Disconnect-Linear

    .LINK
        https://linear.app/developers/graphql
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'FromEnvironment', Justification = 'Selects the Environment parameter set.')]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Browser', Justification = 'Selects the Browser parameter set.')]
    [CmdletBinding(DefaultParameterSetName = 'ApiKey')]
    [OutputType('PSLinear.Context')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'ApiKey')]
        [securestring] $ApiKey,

        [Parameter(Mandatory, ParameterSetName = 'AccessToken')]
        [securestring] $AccessToken,

        [Parameter(Mandatory, ParameterSetName = 'Browser')]
        [switch] $Browser,

        [Parameter(ParameterSetName = 'Browser')]
        [ValidateNotNullOrEmpty()]
        [string] $ClientId,

        [Parameter(ParameterSetName = 'Browser')]
        [ValidateSet('read', 'write', 'issues:create', 'comments:create', 'timeSchedule:write', 'admin')]
        [string[]] $Scope = @('read', 'write'),

        [Parameter(ParameterSetName = 'Browser')]
        [ValidateNotNull()]
        [uri] $RedirectUri = $script:DefaultOAuthRedirectUri,

        [Parameter(ParameterSetName = 'Browser')]
        [ValidateRange(10, 3600)]
        [int] $TimeoutSeconds = 300,

        [Parameter(Mandatory, ParameterSetName = 'Secret')]
        [Parameter(ParameterSetName = 'Browser')]
        [ValidateNotNullOrEmpty()]
        [string] $SecretName,

        [Parameter(ParameterSetName = 'Secret')]
        [Parameter(ParameterSetName = 'Browser')]
        [ValidateNotNullOrEmpty()]
        [string] $Vault,

        [Parameter(Mandatory, ParameterSetName = 'Environment')]
        [switch] $FromEnvironment,

        [Parameter(ParameterSetName = 'Secret')]
        [Parameter(ParameterSetName = 'Environment')]
        [ValidateSet('ApiKey', 'OAuth')]
        [string] $TokenType = 'ApiKey',

        [ValidateNotNull()]
        [uri] $Endpoint = $script:DefaultEndpoint,

        [ValidateRange(0, 10)]
        [int] $MaxRetries = 3,

        [switch] $SkipValidation,

        [switch] $PassThru
    )

    $oauth = @{}
    try {
        switch ($PSCmdlet.ParameterSetName) {
            'ApiKey' {
                $token = $ApiKey
                $scheme = 'ApiKey'
            }
            'AccessToken' {
                $token = $AccessToken
                $scheme = 'OAuth'
            }
            'Secret' {
                if (-not (Get-Command -Name 'Get-Secret' -ErrorAction SilentlyContinue)) {
                    throw 'Reading from a vault requires the Microsoft.PowerShell.SecretManagement module. Install it with: Install-PSResource Microsoft.PowerShell.SecretManagement'
                }
                $secretParameters = @{ Name = $SecretName; ErrorAction = 'Stop' }
                if ($Vault) { $secretParameters['Vault'] = $Vault }
                $secret = Get-Secret @secretParameters
                $token = if ($secret -is [securestring]) {
                    $secret
                }
                elseif ($secret -is [string]) {
                    ConvertTo-LinearSecureString -Value $secret
                }
                else {
                    throw "Secret '$SecretName' must be a String or SecureString, but it is a $($secret.GetType().Name)."
                }
                $scheme = $TokenType
            }
            'Environment' {
                if ([string]::IsNullOrWhiteSpace($env:LINEAR_API_KEY)) {
                    throw 'The LINEAR_API_KEY environment variable is not set.'
                }
                $token = ConvertTo-LinearSecureString -Value $env:LINEAR_API_KEY
                $scheme = $TokenType
            }
            'Browser' {
                $resolvedClientId = if ($ClientId) { $ClientId } else { $env:LINEAR_OAUTH_CLIENT_ID }
                if ([string]::IsNullOrWhiteSpace($resolvedClientId)) {
                    throw ("Signing in through the browser needs the client id of a Linear OAuth application. Create one in Linear under Settings > API > OAuth applications, " +
                        "add $($RedirectUri.AbsoluteUri) to its callback URLs, then pass -ClientId or set the LINEAR_OAUTH_CLIENT_ID environment variable.")
                }
                if ($SecretName -and -not (Get-Command -Name 'Set-Secret' -ErrorAction SilentlyContinue)) {
                    throw 'Saving the sign-in in a vault requires the Microsoft.PowerShell.SecretManagement module. Install it with: Install-PSResource Microsoft.PowerShell.SecretManagement'
                }

                $tokens = $null
                if ($SecretName) {
                    $secretParameters = @{ Name = $SecretName; ErrorAction = 'Stop' }
                    if ($Vault) { $secretParameters['Vault'] = $Vault }
                    $saved = try { Get-Secret @secretParameters } catch { $null }
                    if ($saved -is [securestring]) { $saved = [System.Net.NetworkCredential]::new('', $saved).Password }
                    if ($saved -is [string] -and $saved) {
                        try {
                            $tokens = Request-LinearOAuthToken -Form @{ grant_type = 'refresh_token'; refresh_token = $saved; client_id = $resolvedClientId }
                            Write-Verbose "Signed in with the refresh token saved in secret '$SecretName'."
                        }
                        catch {
                            Write-Verbose "The sign-in saved in secret '$SecretName' could not be renewed ($($_.Exception.Message)); signing in through the browser."
                        }
                    }
                }
                if ($null -eq $tokens) {
                    $tokens = Invoke-LinearOAuthLogin -ClientId $resolvedClientId -Scope $Scope -RedirectUri $RedirectUri -TimeoutSeconds $TimeoutSeconds
                }
                $token = $tokens.AccessToken
                $scheme = 'OAuth'
                $oauth = @{ RefreshToken = $tokens.RefreshToken; ExpiresAt = $tokens.ExpiresAt; ClientId = $resolvedClientId }
                if ($SecretName) { $oauth['SecretName'] = $SecretName }
                if ($Vault) { $oauth['Vault'] = $Vault }
            }
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'PSLinear.*') {
            $PSCmdlet.ThrowTerminatingError($_)
        }
        $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message $_.Exception.Message -ErrorId 'PSLinear.InvalidCredential' -Category InvalidArgument))
    }

    if ($token.Length -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message 'The credential is empty.' -ErrorId 'PSLinear.InvalidCredential' -Category InvalidArgument))
    }

    $previousContext = $script:LinearContext
    $script:LinearContext = New-LinearContext -Token $token -AuthScheme $scheme -Endpoint $Endpoint -MaxRetries $MaxRetries @oauth
    Clear-LinearCache
    if ($oauth.ContainsKey('SecretName')) {
        # Linear replaces the refresh token on every sign-in and renewal, so save the new one now.
        try {
            Save-LinearOAuthSecret -Context $script:LinearContext
        }
        catch {
            Write-Warning "Could not save the sign-in to secret '$SecretName': $($_.Exception.Message)"
        }
    }

    if (-not $SkipValidation) {
        try {
            $data = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'Viewer')
            $script:LinearContext.Organization = Get-LinearNestedValue -InputObject $data -Name 'organization.name'
            $script:LinearContext.User = Get-LinearNestedValue -InputObject $data -Name 'viewer.name'
            $script:LinearContext.UserEmail = Get-LinearNestedValue -InputObject $data -Name 'viewer.email'
            $script:LinearContext.UserId = Get-LinearNestedValue -InputObject $data -Name 'viewer.id'
        }
        catch {
            $script:LinearContext = $previousContext
            $PSCmdlet.ThrowTerminatingError($_)
        }
        Write-Verbose "Connected to Linear organization '$($script:LinearContext.Organization)' as '$($script:LinearContext.User)'."
    }

    if ($PassThru) {
        $script:LinearContext
    }
}
