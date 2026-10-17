BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Set-LinearAttachment' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestAttachmentResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    It 'changes the title and returns nothing' {
        Set-LinearAttachment -Id attachment-1 -Title 'Login error' | Should -BeNullOrEmpty
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            (Get-RequestOperation $Body) -eq 'UpdateAttachment' -and
            (Get-RequestVariable $Body 'id') -eq 'attachment-1' -and
            (Get-RequestVariable $Body 'input.title') -eq 'Login error' -and
            @((Get-RequestVariable $Body 'input').Keys).Count -eq 1
        }
    }

    It 'keeps the current title when only the subtitle changes, looking it up for an id' {
        $attachment = Set-LinearAttachment -Id attachment-2 -Subtitle 'Merged' -PassThru
        $attachment.Title | Should -Be 'Fix login'
        $attachment.Subtitle | Should -Be 'Merged'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'GetAttachment' }
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
            (Get-RequestOperation $Body) -eq 'UpdateAttachment' -and (Get-RequestVariable $Body 'input.title') -eq 'Fix login'
        }
    }

    It 'uses the title of piped attachments without a lookup' {
        $attachment = [pscustomobject]@{ PSTypeName = 'PSLinear.Attachment'; Id = 'attachment-1'; Title = 'screenshot.png'; Issue = 'ENG-1' }
        $attachment | Set-LinearAttachment -Subtitle 'Before the fix'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'GetAttachment' }
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
            (Get-RequestVariable $Body 'input.title') -eq 'screenshot.png' -and (Get-RequestVariable $Body 'input.subtitle') -eq 'Before the fix'
        }
    }

    It 'removes the subtitle with an empty string' {
        Set-LinearAttachment -Id attachment-2 -Title 'Fix login' -Subtitle ''
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
            $attachmentInput = Get-RequestVariable $Body 'input'
            $null -ne $attachmentInput -and $attachmentInput.Contains('subtitle') -and $null -eq $attachmentInput['subtitle']
        }
    }

    It 'replaces the metadata, keeping the title' {
        $attachment = Set-LinearAttachment -Id attachment-2 -Metadata @{ status = 'closed'; reviews = 3 } -PassThru
        $attachment.Metadata.status | Should -Be 'closed'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
            (Get-RequestOperation $Body) -eq 'UpdateAttachment' -and
            (Get-RequestVariable $Body 'input.title') -eq 'Fix login' -and
            (Get-RequestVariable $Body 'input.metadata.reviews') -eq 3
        }
    }

    It 'removes the metadata with an empty hashtable' {
        Set-LinearAttachment -Id attachment-2 -Title 'Fix login' -Metadata @{}
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
            $metadata = Get-RequestVariable $Body 'input.metadata'
            $null -ne $metadata -and $metadata.Count -eq 0
        }
    }

    It 'refuses metadata values that are not strings or numbers' {
        { Set-LinearAttachment -Id attachment-2 -Metadata @{ when = [datetime]'2026-01-01' } } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
    }

    It 'shows the metadata in the -WhatIf message' {
        $message = InModuleScope PSLinear { Format-LinearChangeList -BoundParameters @{ Metadata = [ordered]@{ a = 1; b = 'x' } } -Name 'Metadata' }
        $message | Should -Be "Metadata='{a=1; b=x}'"
    }

    It 'requires -Title or -Subtitle' {
        { Set-LinearAttachment -Id attachment-1 } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
    }

    It 'sends no request with -WhatIf' {
        'attachment-1', 'attachment-2' | Set-LinearAttachment -Title 'x' -WhatIf
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
    }

    It 'writes one error for a missing attachment and updates the rest' {
        $updated = @('missing', 'attachment-1' | Set-LinearAttachment -Title 'x' -PassThru -ErrorAction SilentlyContinue -ErrorVariable attachmentErrors)
        $updated.Id | Should -Be @('attachment-1')
        $attachmentErrors.Count | Should -Be 1
        $attachmentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.AttachmentUpdateFailed*'
    }

    It 'writes one error when the attachment to keep the title of does not exist' {
        Set-LinearAttachment -Id missing -Subtitle 'x' -ErrorAction SilentlyContinue -ErrorVariable attachmentErrors
        $attachmentErrors.Count | Should -Be 1
        $attachmentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.AttachmentNotFound*'
    }
}
