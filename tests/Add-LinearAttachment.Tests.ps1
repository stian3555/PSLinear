BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Add-LinearAttachment' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestAttachmentResponse -Request (Get-RequestBody -Body $Body)
        }
        Mock -ModuleName PSLinear Send-LinearFileUpload { 200 }
        Mock -ModuleName PSLinear Start-Sleep { }

        $files = Join-Path $TestDrive 'files'
        $null = New-Item -ItemType Directory -Path $files -Force
        Set-Content -LiteralPath (Join-Path $files 'screenshot.png') -Value 'png bytes' -NoNewline
        Set-Content -LiteralPath (Join-Path $files 'spec.pdf') -Value 'pdf bytes' -NoNewline
        Set-Content -LiteralPath (Join-Path $files 'run1.log') -Value 'log one' -NoNewline
        Set-Content -LiteralPath (Join-Path $files 'run2.log') -Value 'log two' -NoNewline
        Set-Content -LiteralPath (Join-Path $files 'override.bin') -Value 'bin' -NoNewline
    }

    Context 'Uploading files' {
        It 'asks Linear for an upload URL, uploads the file and attaches it to the issue' {
            $path = Join-Path $TestDrive 'files/screenshot.png'
            $attachment = Add-LinearAttachment ENG-1 $path
            $attachment.PSObject.TypeNames | Should -Contain 'PSLinear.Attachment'
            $attachment.Title | Should -Be 'screenshot.png'
            $attachment.Url | Should -Be 'https://uploads.linear.app/asset/screenshot.png'

            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'RequestFileUpload' -and
                (Get-RequestVariable $Body 'contentType') -eq 'image/png' -and
                (Get-RequestVariable $Body 'filename') -eq 'screenshot.png' -and
                (Get-RequestVariable $Body 'size') -eq 9 -and
                (Get-RequestVariable $Body 'makePublic') -eq $false
            }
            Should -Invoke Send-LinearFileUpload -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://storage.example/put/screenshot.png' -and
                $ContentType -eq 'image/png' -and
                (Split-Path $Path -Leaf) -eq 'screenshot.png' -and
                $Headers['x-goog-content-length-range'] -eq '0,9' -and
                $Headers['Cache-Control'] -eq 'public, max-age=31536000' -and
                -not $Headers.ContainsKey('Authorization')
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateAttachment' -and
                (Get-RequestVariable $Body 'input.issueId') -eq 'issue-uuid-ENG-1' -and
                (Get-RequestVariable $Body 'input.title') -eq 'screenshot.png' -and
                (Get-RequestVariable $Body 'input.url') -eq 'https://uploads.linear.app/asset/screenshot.png'
            }
        }

        It 'sends the title, subtitle and linked comment' {
            Add-LinearAttachment -Issue ENG-1 -Path (Join-Path $TestDrive 'files/spec.pdf') -Title 'Spec' -Subtitle 'Version 2' -Comment 'The spec.' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateAttachment' -and
                (Get-RequestVariable $Body 'input.title') -eq 'Spec' -and
                (Get-RequestVariable $Body 'input.subtitle') -eq 'Version 2' -and
                (Get-RequestVariable $Body 'input.commentBody') -eq 'The spec.'
            }
            Should -Invoke Send-LinearFileUpload -ModuleName PSLinear -ParameterFilter { $ContentType -eq 'application/pdf' }
        }

        It 'uploads every file a wildcard matches, checking the issue once' {
            $attachments = @(Add-LinearAttachment -Issue ENG-1 -Path (Join-Path $TestDrive 'files/*.log'))
            $attachments.Title | Should -Be @('run1.log', 'run2.log')
            Should -Invoke Send-LinearFileUpload -ModuleName PSLinear -Times 2 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'GetIssueTeam' }
        }

        It 'uses the content type Linear signs the upload with' {
            Add-LinearAttachment -Issue ENG-1 -Path (Join-Path $TestDrive 'files/override.bin') | Out-Null
            Should -Invoke Send-LinearFileUpload -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $ContentType -eq 'application/x-custom' -and -not $Headers.ContainsKey('content-type')
            }
        }

        It 'binds the issue from piped PSLinear.Issue objects' {
            $issue = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-uuid-ENG-7'; Identifier = 'ENG-7' }
            ($issue | Add-LinearAttachment -Path (Join-Path $TestDrive 'files/spec.pdf')).Issue | Should -Be 'ENG-7'
        }
    }

    Context 'Metadata' {
        It 'stores metadata on an uploaded file' {
            $attachment = Add-LinearAttachment -Issue ENG-1 -Path (Join-Path $TestDrive 'files/spec.pdf') -Metadata @{ pipeline = 'nightly'; failures = 3 }
            $attachment.Metadata.pipeline | Should -Be 'nightly'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateAttachment' -and
                (Get-RequestVariable $Body 'input.metadata.pipeline') -eq 'nightly' -and
                (Get-RequestVariable $Body 'input.metadata.failures') -eq 3
            }
        }

        It 'sets metadata on a link right after creating it, keeping the title' {
            $attachment = Add-LinearAttachment -Issue ENG-1 -Url 'https://example.com/doc' -Metadata @{ source = 'wiki' }
            $attachment.Metadata.source | Should -Be 'wiki'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateAttachment' -and
                (Get-RequestVariable $Body 'id') -eq 'attachment-link' -and
                (Get-RequestVariable $Body 'input.title') -eq 'Title from Linear' -and
                (Get-RequestVariable $Body 'input.metadata.source') -eq 'wiki'
            }
        }

        It 'sets the subtitle and metadata on a link right after creating it' {
            $attachment = Add-LinearAttachment -Issue ENG-1 -Url 'https://example.com/doc' -Subtitle 'Wiki page' -Metadata @{ source = 'wiki' }
            $attachment.Subtitle | Should -Be 'Wiki page'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateAttachment' -and
                (Get-RequestVariable $Body 'input.subtitle') -eq 'Wiki page' -and
                (Get-RequestVariable $Body 'input.metadata.source') -eq 'wiki'
            }
        }

        It 'stores boolean values' {
            $attachment = Add-LinearAttachment -Issue ENG-1 -Path (Join-Path $TestDrive 'files/spec.pdf') -Metadata @{ managed = $true; retired = $false }
            $attachment.Metadata.managed | Should -BeTrue
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestVariable $Body 'input.metadata.managed') -is [bool] -and
                (Get-RequestVariable $Body 'input.metadata.managed') -eq $true -and
                (Get-RequestVariable $Body 'input.metadata.retired') -eq $false
            }
        }

        It 'refuses values that are not strings, numbers or booleans, before sending anything' {
            { Add-LinearAttachment -Issue ENG-1 -Url 'https://example.com' -Metadata @{ nested = @{ a = 1 } } } |
                Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage "*Metadata value 'nested' is Hashtable; metadata values can be strings, numbers and booleans.*"
            { Add-LinearAttachment -Issue ENG-1 -Url 'https://example.com' -Metadata @{ list = @(1, 2) } } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            { Add-LinearAttachment -Issue ENG-1 -Url 'https://example.com' -Metadata @{ empty = $null } } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Links without integrations (-NoRichLink)' {
        It 'creates the attachment with its title, subtitle and metadata in one request' {
            $attachment = Add-LinearAttachment ENG-1 -Url 'https://monitor.example/alerts/42' -Title 'Alert 42' -Subtitle 'Firing' `
                -Metadata @{ alertId = 42; managed = $true } -NoRichLink
            $attachment.Title | Should -Be 'Alert 42'
            $attachment.Subtitle | Should -Be 'Firing'
            $attachment.Metadata.alertId | Should -Be 42
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateAttachment' -and
                (Get-RequestVariable $Body 'input.issueId') -eq 'ENG-1' -and
                (Get-RequestVariable $Body 'input.url') -eq 'https://monitor.example/alerts/42' -and
                (Get-RequestVariable $Body 'input.title') -eq 'Alert 42' -and
                (Get-RequestVariable $Body 'input.subtitle') -eq 'Firing' -and
                (Get-RequestVariable $Body 'input.metadata.managed') -eq $true
            }
        }

        It 'uses the URL as the title when -Title is not given' {
            (Add-LinearAttachment ENG-1 -Url 'https://monitor.example/alerts/42' -NoRichLink).Title | Should -Be 'https://monitor.example/alerts/42'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'LinkAttachmentUrl' }
        }

        It 'writes one error when the issue does not exist' {
            Add-LinearAttachment ENG-404 -Url 'https://monitor.example/alerts/42' -NoRichLink -ErrorAction SilentlyContinue -ErrorVariable linkErrors |
                Should -BeNullOrEmpty
            $linkErrors.Count | Should -Be 1
            $linkErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.AttachmentCreateFailed*'
            $linkErrors[0].Exception.Message | Should -BeLike '*Entity not found: Issue*'
        }

        It 'sends nothing with -WhatIf' {
            Add-LinearAttachment ENG-1 -Url 'https://monitor.example/alerts/42' -NoRichLink -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Public uploads' {
        It 'uploads images to a public URL with a warning' {
            Add-LinearAttachment -Issue ENG-1 -Path (Join-Path $TestDrive 'files/screenshot.png') -Public -WarningVariable uploadWarnings -WarningAction SilentlyContinue | Out-Null
            $uploadWarnings.Count | Should -Be 1
            $uploadWarnings[0].Message | Should -BeLike "*'screenshot.png' is uploaded to a public URL*"
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'RequestFileUpload' -and (Get-RequestVariable $Body 'makePublic') -eq $true
            }
        }

        It 'refuses to make other files public, before sending anything' {
            { Add-LinearAttachment -Issue ENG-1 -Path (Join-Path $TestDrive 'files/spec.pdf') -Public } |
                Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage "*'spec.pdf' is application/pdf; only PNG, JPEG*"
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Links' {
        It 'links a URL to the issue without uploading' {
            $attachment = Add-LinearAttachment -Issue 'https://linear.app/acme/issue/ENG-3/title' -Url 'https://github.com/acme/app/pull/42' -Title 'Fix PR'
            $attachment.Source | Should -Be 'github'
            Should -Invoke Send-LinearFileUpload -ModuleName PSLinear -Times 0 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'LinkAttachmentUrl' -and
                (Get-RequestVariable $Body 'issueId') -eq 'ENG-3' -and
                (Get-RequestVariable $Body 'url') -eq 'https://github.com/acme/app/pull/42' -and
                (Get-RequestVariable $Body 'title') -eq 'Fix PR'
            }
        }

        It 'leaves the title to Linear when -Title is not given' {
            (Add-LinearAttachment -Issue ENG-1 -Url 'https://example.com/doc').Title | Should -Be 'Title from Linear'
        }

        It 'writes one error when the issue does not exist' {
            Add-LinearAttachment -Issue ENG-404 -Url 'https://example.com' -ErrorAction SilentlyContinue -ErrorVariable linkErrors | Should -BeNullOrEmpty
            $linkErrors.Count | Should -Be 1
            $linkErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.AttachmentCreateFailed*'
        }
    }

    Context '-WhatIf' {
        It 'sends and uploads nothing' {
            Add-LinearAttachment -Issue ENG-1 -Path (Join-Path $TestDrive 'files/*.log') -WhatIf
            Add-LinearAttachment -Issue ENG-1 -Url 'https://example.com' -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
            Should -Invoke Send-LinearFileUpload -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Errors' {
        It 'stops on a missing file before sending anything' {
            { Add-LinearAttachment -Issue ENG-1 -Path (Join-Path $TestDrive 'files/nope.png') } | Should -Throw -ErrorId 'PSLinear.FileNotFound*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'refuses -Title for several files' {
            { Add-LinearAttachment -Issue ENG-1 -Path (Join-Path $TestDrive 'files/*.log') -Title 'Logs' } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'checks the issue first, so a missing issue uploads nothing' {
            Add-LinearAttachment -Issue ENG-404 -Path (Join-Path $TestDrive 'files/spec.pdf') -ErrorAction SilentlyContinue -ErrorVariable attachErrors | Should -BeNullOrEmpty
            $attachErrors.Count | Should -Be 1
            $attachErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueNotFound*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'RequestFileUpload' }
            Should -Invoke Send-LinearFileUpload -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'retries an upload that fails with a server error' {
            $script:uploadCalls = 0
            Mock -ModuleName PSLinear Send-LinearFileUpload { $script:uploadCalls++; if ($script:uploadCalls -eq 1) { 503 } else { 200 } }
            (Add-LinearAttachment -Issue ENG-1 -Path (Join-Path $TestDrive 'files/spec.pdf')).Title | Should -Be 'spec.pdf'
            Should -Invoke Send-LinearFileUpload -ModuleName PSLinear -Times 2 -Exactly
            Should -Invoke Start-Sleep -ModuleName PSLinear -Times 1 -Exactly
        }

        It 'stops with UploadFailed when the upload keeps failing' {
            Mock -ModuleName PSLinear Send-LinearFileUpload { 403 }
            { Add-LinearAttachment -Issue ENG-1 -Path (Join-Path $TestDrive 'files/spec.pdf') } |
                Should -Throw -ErrorId 'PSLinear.UploadFailed*' -ExpectedMessage "*Could not upload 'spec.pdf': the storage service returned HTTP 403*"
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'CreateAttachment' }
        }

        It 'writes one error when Linear rejects the attachment' {
            Add-LinearAttachment -Issue ENG-1 -Path (Join-Path $TestDrive 'files/spec.pdf') -Title 'reject' -ErrorAction SilentlyContinue -ErrorVariable attachErrors | Should -BeNullOrEmpty
            $attachErrors.Count | Should -Be 1
            $attachErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.AttachmentCreateFailed*'
        }
    }
}
