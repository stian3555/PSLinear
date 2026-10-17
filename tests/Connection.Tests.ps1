BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force

    $script:viewerResponse = {
        New-LinearTestResponse -Data @{
            viewer       = @{ id = 'user-1'; name = 'Ada Lovelace'; displayName = 'ada'; email = 'ada@example.com'; admin = $true; active = $true }
            organization = @{ id = 'org-1'; name = 'Acme'; urlKey = 'acme' }
        }
    }
}

Describe 'Connect-Linear' {
    BeforeEach {
        $env:LINEAR_API_KEY = $null
        InModuleScope PSLinear { $script:LinearContext = $null }
        Mock -ModuleName PSLinear Send-LinearHttpRequest $script:viewerResponse
    }

    AfterEach {
        $env:LINEAR_API_KEY = $null
    }

    It 'connects with an API key and validates it' {
        $context = Connect-Linear -ApiKey (ConvertTo-SecureString 'lin_api_test' -AsPlainText -Force) -PassThru
        $context.Organization | Should -Be 'Acme'
        $context.User | Should -Be 'Ada Lovelace'
        $context.AuthScheme | Should -Be 'ApiKey'
        $context.PSObject.TypeNames | Should -Contain 'PSLinear.Context'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            (Get-RequestBody $Body).query -match 'query Viewer' -and $Headers.Authorization -eq 'lin_api_test'
        }
    }

    It 'never stores the token as plain text' {
        $context = Connect-Linear -ApiKey (ConvertTo-SecureString 'lin_api_secret' -AsPlainText -Force) -PassThru
        $context.Token | Should -BeOfType [securestring]
        ($context | Out-String) | Should -Not -Match 'lin_api_secret'
        ($context | ConvertTo-Json -Depth 3 -WarningAction SilentlyContinue) | Should -Not -Match 'lin_api_secret'
    }

    It 'connects with an OAuth access token using the Bearer scheme' {
        Connect-Linear -AccessToken (ConvertTo-SecureString 'oauth-token' -AsPlainText -Force)
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter { $Headers.Authorization -eq 'Bearer oauth-token' }
    }

    It 'connects from the LINEAR_API_KEY environment variable' {
        $env:LINEAR_API_KEY = 'lin_api_env'
        Connect-Linear -FromEnvironment
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter { $Headers.Authorization -eq 'lin_api_env' }
    }

    It 'fails clearly when -FromEnvironment is used without the variable' {
        { Connect-Linear -FromEnvironment } | Should -Throw -ExpectedMessage '*LINEAR_API_KEY*' -ErrorId 'PSLinear.InvalidCredential*'
    }

    It 'skips the validation call with -SkipValidation' {
        Connect-Linear -ApiKey (ConvertTo-SecureString 'lin_api_test' -AsPlainText -Force) -SkipValidation
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
    }

    It 'keeps the previous connection when validation fails' {
        Connect-Linear -ApiKey (ConvertTo-SecureString 'lin_api_good' -AsPlainText -Force)
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            New-LinearTestResponse -StatusCode 400 -Errors @(New-LinearTestError -Message 'Authentication required' -Code 'AUTHENTICATION_ERROR')
        }
        { Connect-Linear -ApiKey (ConvertTo-SecureString 'lin_api_bad' -AsPlainText -Force) } | Should -Throw -ErrorId 'PSLinear.AuthenticationFailed*'
        InModuleScope PSLinear { Get-LinearAuthorizationValue -Context $script:LinearContext } | Should -Be 'lin_api_good'
    }

    It 'reads the credential from a SecretManagement vault' {
        function global:Get-Secret { param($Name, $Vault) $null = $Vault; if ($Name -eq 'LinearKey') { 'lin_api_vault' } }
        try {
            Connect-Linear -SecretName 'LinearKey'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter { $Headers.Authorization -eq 'lin_api_vault' }
        }
        finally {
            Remove-Item -Path Function:\Get-Secret
        }
    }

    It 'explains how to install SecretManagement when it is missing' {
        Mock -ModuleName PSLinear Get-Command { $null } -ParameterFilter { $Name -eq 'Get-Secret' }
        { Connect-Linear -SecretName 'LinearKey' } | Should -Throw -ExpectedMessage '*Microsoft.PowerShell.SecretManagement*'
    }

    It 'clears cached teams when the connection changes' {
        InModuleScope PSLinear {
            $script:LinearTeamCache = @([pscustomobject]@{ Key = 'OLD' })
            $script:LinearTeamCacheExpires = [datetime]::UtcNow.AddMinutes(10)
        }
        Connect-Linear -ApiKey (ConvertTo-SecureString 'lin_api_test' -AsPlainText -Force)
        InModuleScope PSLinear { $script:LinearTeamCache } | Should -BeNullOrEmpty
    }
}

Describe 'Implicit connection' {
    BeforeEach {
        InModuleScope PSLinear { $script:LinearContext = $null }
        Mock -ModuleName PSLinear Send-LinearHttpRequest $script:viewerResponse
    }

    AfterEach {
        $env:LINEAR_API_KEY = $null
    }

    It 'uses LINEAR_API_KEY automatically when not connected' {
        $env:LINEAR_API_KEY = 'lin_api_implicit'
        (Get-LinearViewer).Email | Should -Be 'ada@example.com'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter { $Headers.Authorization -eq 'lin_api_implicit' }
    }

    It 'asks the user to connect when there is no credential at all' {
        $env:LINEAR_API_KEY = $null
        { Get-LinearViewer } | Should -Throw -ExpectedMessage '*Connect-Linear*'
    }
}

Describe 'Disconnect-Linear' {
    It 'forgets the connection' {
        $env:LINEAR_API_KEY = $null
        Mock -ModuleName PSLinear Send-LinearHttpRequest $script:viewerResponse
        Connect-Linear -ApiKey (ConvertTo-SecureString 'lin_api_test' -AsPlainText -Force)
        Disconnect-Linear
        InModuleScope PSLinear { $script:LinearContext } | Should -BeNullOrEmpty
    }

    It 'warns when LINEAR_API_KEY would reconnect it' {
        $env:LINEAR_API_KEY = 'lin_api_env'
        try {
            Disconnect-Linear -WarningVariable warnings -WarningAction SilentlyContinue
            $warnings | Should -Not -BeNullOrEmpty
        }
        finally {
            $env:LINEAR_API_KEY = $null
        }
    }
}

Describe 'Get-LinearViewer' {
    It 'returns a typed user with the organization name' {
        $env:LINEAR_API_KEY = $null
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest $script:viewerResponse
        $viewer = Get-LinearViewer
        $viewer.PSObject.TypeNames | Should -Contain 'PSLinear.User'
        $viewer.Organization | Should -Be 'Acme'
        $viewer.Admin | Should -BeTrue
    }
}
