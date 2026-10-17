function Disconnect-Linear {
    <#
    .SYNOPSIS
        Removes the Linear connection from the current session.

    .DESCRIPTION
        Clears the stored credential and any cached lookups. If the LINEAR_API_KEY
        environment variable is set, the next PSLinear command will connect implicitly
        with it again; remove the variable to prevent that.

        With -Revoke, a sign-in from Connect-Linear -Browser or -AccessToken is also revoked at
        Linear, so the tokens stop working everywhere, and the refresh token saved with
        -SecretName is removed from the vault.

    .PARAMETER Revoke
        Revokes the OAuth access and refresh tokens at Linear before disconnecting, and removes
        the refresh token saved with Connect-Linear -Browser -SecretName.

    .EXAMPLE
        Disconnect-Linear

        Forgets the current credential.

    .EXAMPLE
        Disconnect-Linear -Revoke

        Signs out of a browser sign-in for good: revokes the tokens and removes the saved one.

    .INPUTS
        None.

    .OUTPUTS
        None.

    .LINK
        Connect-Linear
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([void])]
    param(
        [switch] $Revoke
    )

    $context = $script:LinearContext
    $action = if ($Revoke) { 'Revoke the sign-in and disconnect' } else { 'Disconnect' }
    if (-not $PSCmdlet.ShouldProcess('Linear connection', $action)) {
        return
    }

    if ($Revoke) {
        if ($null -eq $context -or $context.AuthScheme -ne 'OAuth') {
            Write-Warning 'Only OAuth sign-ins can be revoked here. Revoke an API key in Linear under Settings > Security & access.'
        }
        else {
            $accessToken = [System.Net.NetworkCredential]::new('', $context.Token).Password
            $tokens = @(
                @{ Value = $accessToken; Hint = 'access_token' }
                if ($null -ne $context.RefreshToken) { @{ Value = [System.Net.NetworkCredential]::new('', $context.RefreshToken).Password; Hint = 'refresh_token' } }
            )
            foreach ($token in $tokens) {
                try {
                    $response = Send-LinearOAuthRequest -Uri $script:OAuthRevokeUrl -Form @{ token = $token.Value; token_type_hint = $token.Hint } `
                        -Headers @{ Authorization = "Bearer $accessToken" }
                    if ($response.StatusCode -ge 400) {
                        Write-Verbose "Linear answered HTTP $($response.StatusCode) when revoking the $($token.Hint); it may already be revoked."
                    }
                }
                catch {
                    Write-Warning "Could not revoke the $($token.Hint): $($_.Exception.Message)"
                }
            }
            if ($context.SecretName) {
                $secretParameters = @{ Name = $context.SecretName; ErrorAction = 'Stop' }
                if ($context.Vault) { $secretParameters['Vault'] = $context.Vault }
                try {
                    Remove-Secret @secretParameters
                }
                catch {
                    Write-Warning "Could not remove the saved sign-in from secret '$($context.SecretName)': $($_.Exception.Message)"
                }
            }
        }
    }

    $wasConnected = $null -ne $context
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
