BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Remove-LinearComment' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestCommentResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    It 'deletes a comment and returns nothing' {
        Remove-LinearComment -Id comment-1 -Confirm:$false | Should -BeNullOrEmpty
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            (Get-RequestOperation $Body) -eq 'DeleteComment' -and (Get-RequestBody $Body).variables.id -eq 'comment-1'
        }
    }

    It 'deletes every comment piped in' {
        $comments = @(
            [pscustomobject]@{ PSTypeName = 'PSLinear.Comment'; Id = 'comment-1'; Target = 'ENG-1' }
            [pscustomobject]@{ PSTypeName = 'PSLinear.Comment'; Id = 'comment-2'; Target = 'ENG-1' }
        )
        $comments | Remove-LinearComment -Confirm:$false
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly
    }

    It 'sends no request with -WhatIf' {
        'comment-1', 'comment-2' | Remove-LinearComment -WhatIf
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
    }

    It 'writes one error for a missing comment and deletes the rest' {
        'comment-1', 'missing', 'comment-2' | Remove-LinearComment -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable commentErrors
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 3 -Exactly
        $commentErrors.Count | Should -Be 1
        $commentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.CommentDeleteFailed*'
        $commentErrors[0].TargetObject | Should -Be 'missing'
    }
}
