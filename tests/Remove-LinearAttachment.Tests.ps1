BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Remove-LinearAttachment' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestAttachmentResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    It 'removes an attachment and returns nothing' {
        Remove-LinearAttachment -Id attachment-1 -Confirm:$false | Should -BeNullOrEmpty
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            (Get-RequestOperation $Body) -eq 'DeleteAttachment' -and (Get-RequestVariable $Body 'id') -eq 'attachment-1'
        }
    }

    It 'removes every attachment piped in' {
        $attachments = @(
            [pscustomobject]@{ PSTypeName = 'PSLinear.Attachment'; Id = 'attachment-1'; Title = 'screenshot.png'; Issue = 'ENG-1' }
            [pscustomobject]@{ PSTypeName = 'PSLinear.Attachment'; Id = 'attachment-2'; Title = 'Fix login'; Issue = 'ENG-1' }
        )
        $attachments | Remove-LinearAttachment -Confirm:$false
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly
    }

    It 'sends no request with -WhatIf' {
        'attachment-1', 'attachment-2' | Remove-LinearAttachment -WhatIf
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
    }

    It 'writes one error for a missing attachment and removes the rest' {
        'attachment-1', 'missing', 'attachment-2' | Remove-LinearAttachment -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable attachmentErrors
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 3 -Exactly
        $attachmentErrors.Count | Should -Be 1
        $attachmentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.AttachmentDeleteFailed*'
    }
}
