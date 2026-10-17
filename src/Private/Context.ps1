function New-LinearContext {
    <#
    .SYNOPSIS
        Creates the in-memory connection context used by every request.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType('PSLinear.Context')]
    param(
        [Parameter(Mandatory)]
        [securestring] $Token,

        [Parameter(Mandatory)]
        [ValidateSet('ApiKey', 'OAuth')]
        [string] $AuthScheme,

        [uri] $Endpoint = $script:DefaultEndpoint,

        [ValidateRange(0, 10)]
        [int] $MaxRetries = 3,

        # OAuth sign-ins through the browser: the refresh token, when the access token expires,
        # the OAuth application, and the SecretManagement secret the refresh token is saved to.
        [securestring] $RefreshToken,

        [Nullable[datetimeoffset]] $ExpiresAt,

        [string] $ClientId,

        [string] $SecretName,

        [string] $Vault
    )

    [pscustomobject]@{
        PSTypeName   = 'PSLinear.Context'
        Organization = $null
        User         = $null
        UserEmail    = $null
        UserId       = $null
        AuthScheme   = $AuthScheme
        Endpoint     = $Endpoint.AbsoluteUri
        MaxRetries   = $MaxRetries
        ConnectedAt  = [datetimeoffset]::Now
        ExpiresAt    = $ExpiresAt
        ClientId     = $(if ($ClientId) { $ClientId } else { $null })
        SecretName   = $(if ($SecretName) { $SecretName } else { $null })
        Vault        = $(if ($Vault) { $Vault } else { $null })
        Token        = $Token
        RefreshToken = $RefreshToken
    }
}

function Get-LinearContext {
    <#
    .SYNOPSIS
        Returns the active connection, connecting implicitly from LINEAR_API_KEY when possible.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Context')]
    param()

    if ($null -ne $script:LinearContext) {
        return $script:LinearContext
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LINEAR_API_KEY)) {
        Write-Verbose 'Not connected; using the API key from the LINEAR_API_KEY environment variable.'
        $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value $env:LINEAR_API_KEY) -AuthScheme 'ApiKey'
        return $script:LinearContext
    }

    $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord `
                -Message 'Not connected to Linear. Run Connect-Linear, or set the LINEAR_API_KEY environment variable.' `
                -ErrorId 'PSLinear.NotConnected' `
                -Category AuthenticationError))
}

function Test-LinearConnection {
    <#
    .SYNOPSIS
        Returns $true when a request can be made without prompting the user.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    ($null -ne $script:LinearContext) -or (-not [string]::IsNullOrWhiteSpace($env:LINEAR_API_KEY))
}

function Clear-LinearCache {
    <#
    .SYNOPSIS
        Clears cached lookups (teams, workflow states, labels, users, projects, cycles, milestones,
        templates, project statuses and labels, initiatives and initiative labels). Called
        whenever the connection changes.
    #>
    [CmdletBinding()]
    param()

    $script:LinearTeamCache = $null
    $script:LinearTeamCacheExpires = [datetime]::MinValue
    $script:LinearUserCache = $null
    $script:LinearUserCacheExpires = [datetime]::MinValue
    $script:LinearProjectCache = $null
    $script:LinearProjectCacheExpires = [datetime]::MinValue
    $script:LinearWorkflowStateCache = @{}
    $script:LinearLabelCache = @{}
    $script:LinearCycleCache = @{}
    $script:LinearMilestoneCache = @{}
    $script:LinearTemplateCache = $null
    $script:LinearTemplateCacheExpires = [datetime]::MinValue
    $script:LinearProjectStatusCache = $null
    $script:LinearProjectStatusCacheExpires = [datetime]::MinValue
    $script:LinearProjectLabelCache = $null
    $script:LinearProjectLabelCacheExpires = [datetime]::MinValue
    $script:LinearInitiativeCache = $null
    $script:LinearInitiativeCacheExpires = [datetime]::MinValue
    $script:LinearInitiativeLabelCache = $null
    $script:LinearInitiativeLabelCacheExpires = [datetime]::MinValue
}

function Get-LinearAuthorizationValue {
    <#
    .SYNOPSIS
        Builds the Authorization header value. API keys are sent as-is, OAuth tokens as Bearer.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Context
    )

    $plainText = [System.Net.NetworkCredential]::new('', $Context.Token).Password
    if ($Context.AuthScheme -eq 'OAuth') {
        return "Bearer $plainText"
    }
    $plainText
}

function ConvertTo-LinearSecureString {
    <#
    .SYNOPSIS
        Converts a plain string (environment variable or vault value) to a read-only SecureString.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    $secure = [securestring]::new()
    foreach ($character in $Value.Trim().ToCharArray()) {
        $secure.AppendChar($character)
    }
    $secure.MakeReadOnly()
    $secure
}
