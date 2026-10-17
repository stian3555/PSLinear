function Connect-Linear {
    <#
    .SYNOPSIS
        Connects the current PowerShell session to the Linear API.

    .DESCRIPTION
        Stores credentials for the Linear GraphQL API in the current session and, unless
        -SkipValidation is used, verifies them by fetching the authenticated user and
        organization.

        Credentials can come from a personal API key (prompted securely when omitted),
        an OAuth access token, a secret in a Microsoft.PowerShell.SecretManagement vault,
        or the LINEAR_API_KEY environment variable.

        The token is kept as a SecureString and is only converted to plain text when a
        request header is built. Nothing is written to disk.

        Commands also connect implicitly when LINEAR_API_KEY is set, so Connect-Linear is
        optional in CI pipelines.

    .PARAMETER ApiKey
        A personal API key, created under Settings > Security & access in Linear.
        If omitted, you are prompted for it without echoing.

    .PARAMETER AccessToken
        An OAuth 2.0 access token. It is sent with the Bearer scheme.

    .PARAMETER SecretName
        The name of a secret in a SecretManagement vault that holds the API key or token.
        Requires the Microsoft.PowerShell.SecretManagement module.

    .PARAMETER Vault
        The SecretManagement vault to read -SecretName from. Uses the default vault when omitted.

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
    [CmdletBinding(DefaultParameterSetName = 'ApiKey')]
    [OutputType('PSLinear.Context')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'ApiKey')]
        [securestring] $ApiKey,

        [Parameter(Mandatory, ParameterSetName = 'AccessToken')]
        [securestring] $AccessToken,

        [Parameter(Mandatory, ParameterSetName = 'Secret')]
        [ValidateNotNullOrEmpty()]
        [string] $SecretName,

        [Parameter(ParameterSetName = 'Secret')]
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
        }
    }
    catch {
        $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message $_.Exception.Message -ErrorId 'PSLinear.InvalidCredential' -Category InvalidArgument))
    }

    if ($token.Length -eq 0) {
        $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message 'The credential is empty.' -ErrorId 'PSLinear.InvalidCredential' -Category InvalidArgument))
    }

    $previousContext = $script:LinearContext
    $script:LinearContext = New-LinearContext -Token $token -AuthScheme $scheme -Endpoint $Endpoint -MaxRetries $MaxRetries
    Clear-LinearCache

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
