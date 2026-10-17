BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Get-LinearUser' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestLookupResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    It 'lists the active users as typed objects, sorted by name' {
        $users = @(Get-LinearUser)
        $users.Name | Should -Be @('Ada Lovelace', 'Alex Smith', 'Alex Smith', 'Grace Hopper')
        $users[0].PSObject.TypeNames | Should -Contain 'PSLinear.User'
        $users[0].Email | Should -Be 'ada@example.com'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            (Get-RequestBody $Body).variables.includeDisabled -eq $false
        }
    }

    It 'includes disabled users with -IncludeDisabled' {
        $users = @(Get-LinearUser -IncludeDisabled)
        $users.Name | Should -Contain 'Old Timer'
        ($users | Where-Object Name -EQ 'Old Timer').Active | Should -BeFalse
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            (Get-RequestBody $Body).variables.includeDisabled -eq $true
        }
    }

    It 'filters by name, display name or email, with wildcards' {
        (Get-LinearUser -Name 'grace hopper').Id | Should -Be 'user-grace'
        (Get-LinearUser -Name 'ada').Id | Should -Be 'user-ada'
        @(Get-LinearUser -Name 'alex.*@example.com').Id | Should -Be @('user-alex-1', 'user-alex-2')
    }

    It 'accepts names from the pipeline and fetches the users once' {
        @('Ada Lovelace', 'Grace Hopper' | Get-LinearUser).Id | Should -Be @('user-ada', 'user-grace')
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
    }

    It 'writes a non-terminating error for a name that matches nobody' {
        $users = @(Get-LinearUser -Name 'Ada Lovelace', 'Nobody' -ErrorAction SilentlyContinue -ErrorVariable userErrors)
        $users.Id | Should -Be @('user-ada')
        $userErrors.Count | Should -Be 1
        $userErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.UserNotFound*'
        $userErrors[0].TargetObject | Should -Be 'Nobody'
    }

    It 'does not report a wildcard pattern that matches nobody' {
        Get-LinearUser -Name 'Z*' -ErrorVariable userErrors | Should -BeNullOrEmpty
        $userErrors.Count | Should -Be 0
    }

    It 'refreshes the user cache used for -Assignee' {
        Get-LinearUser | Out-Null
        InModuleScope PSLinear { Resolve-LinearUserId -User 'Grace Hopper' } | Should -Be 'user-grace'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
    }
}

Describe 'Get-LinearViewer output' {
    It 'is a PSLinear.User shown with the PSLinear.Viewer view' {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestLookupResponse -Request (Get-RequestBody -Body $Body)
        }
        $viewer = Get-LinearViewer
        $viewer.PSObject.TypeNames[0] | Should -Be 'PSLinear.Viewer'
        $viewer.PSObject.TypeNames | Should -Contain 'PSLinear.User'
        $viewer.Organization | Should -Be 'Acme'
    }
}
