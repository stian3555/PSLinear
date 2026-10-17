BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Get-LinearAttachment' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestAttachmentResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    It 'lists an issue''s attachments oldest first, as typed objects' {
        $attachments = @(Get-LinearAttachment ENG-1)
        $attachments.Id | Should -Be @('attachment-1', 'attachment-2')
        $attachments[0].PSObject.TypeNames | Should -Contain 'PSLinear.Attachment'
        $attachments[0].Issue | Should -Be 'ENG-1'
        $attachments[0].Creator | Should -Be 'Ada Lovelace'
        $attachments[0].Source | Should -BeNullOrEmpty -Because "Linear reports uploads as source 'unknown'"
        $attachments[1].Source | Should -Be 'github'
        $attachments[1].Subtitle | Should -Be 'PR #42'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            (Get-RequestOperation $Body) -eq 'ListIssueAttachments' -and (Get-RequestVariable $Body 'id') -eq 'ENG-1'
        }
    }

    It 'accepts issue URLs, identifiers from the pipeline and issue objects' {
        @(Get-LinearAttachment 'https://linear.app/acme/issue/ENG-1/title').Count | Should -Be 2
        @('ENG-1', 'ENG-2' | Get-LinearAttachment).Count | Should -Be 2
        $issue = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-uuid-ENG-1'; Identifier = 'ENG-1' }
        @($issue | Get-LinearAttachment).Count | Should -Be 2
    }

    It 'writes one error for a missing issue and lists the rest' {
        $attachments = @('ENG-404', 'ENG-1' | Get-LinearAttachment -ErrorAction SilentlyContinue -ErrorVariable attachmentErrors)
        $attachments.Count | Should -Be 2
        $attachmentErrors.Count | Should -Be 1
        $attachmentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueNotFound*'
    }

    It 'gets attachments by id, writing one error for a missing one' {
        $attachments = @(Get-LinearAttachment -Id 'attachment-2', 'missing' -ErrorAction SilentlyContinue -ErrorVariable attachmentErrors)
        $attachments.Id | Should -Be @('attachment-2')
        $attachmentErrors.Count | Should -Be 1
        $attachmentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.AttachmentNotFound*'
    }
}
