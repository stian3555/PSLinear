BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Upload helpers' {
    Context 'Get-LinearContentType' {
        It 'maps <Name> to <Type>' -ForEach @(
            @{ Name = 'shot.PNG'; Type = 'image/png' }
            @{ Name = 'photo.jpeg'; Type = 'image/jpeg' }
            @{ Name = 'spec.pdf'; Type = 'application/pdf' }
            @{ Name = 'notes.md'; Type = 'text/markdown' }
            @{ Name = 'run.log'; Type = 'text/plain' }
            @{ Name = 'data.json'; Type = 'application/json' }
            @{ Name = 'clip.mov'; Type = 'video/quicktime' }
            @{ Name = 'archive.tar.gz'; Type = 'application/gzip' }
            @{ Name = 'mystery.xyz'; Type = 'application/octet-stream' }
            @{ Name = 'Makefile'; Type = 'application/octet-stream' }
        ) {
            InModuleScope PSLinear -Parameters @{ Name = $Name } { param($Name) Get-LinearContentType -Path $Name } | Should -Be $Type
        }
    }

    Context 'Resolve-LinearUploadFile' {
        BeforeEach {
            $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'up/sub') -Force
            Set-Content -LiteralPath (Join-Path $TestDrive 'up/a.txt') -Value 'a'
            Set-Content -LiteralPath (Join-Path $TestDrive 'up/b.txt') -Value 'b'
        }

        It 'expands wildcards to files and skips directories' {
            $files = InModuleScope PSLinear -Parameters @{ Pattern = (Join-Path $TestDrive 'up/*') } { param($Pattern) Resolve-LinearUploadFile -Path $Pattern }
            @($files).Name | Should -Be @('a.txt', 'b.txt')
        }

        It 'uses a file whose name contains wildcard characters as written' {
            Set-Content -LiteralPath (Join-Path $TestDrive 'up/shot [1].png') -Value 'png'
            $files = InModuleScope PSLinear -Parameters @{ Pattern = (Join-Path $TestDrive 'up/shot [1].png') } { param($Pattern) Resolve-LinearUploadFile -Path $Pattern }
            @($files).Name | Should -Be @('shot [1].png')
        }

        It 'throws FileNotFound for a path that matches no file' {
            { InModuleScope PSLinear -Parameters @{ Pattern = (Join-Path $TestDrive 'up/sub') } { param($Pattern) Resolve-LinearUploadFile -Path $Pattern } } |
                Should -Throw -ErrorId 'PSLinear.FileNotFound*'
        }
    }

    Context 'Invoke-LinearFileUpload' {
        BeforeEach {
            InModuleScope PSLinear {
                $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
            }
            Mock -ModuleName PSLinear Send-LinearHttpRequest { Get-LinearTestAttachmentResponse -Request (Get-RequestBody -Body $Body) }
            Mock -ModuleName PSLinear Send-LinearFileUpload { 200 }
            Mock -ModuleName PSLinear Start-Sleep { }
            Set-Content -LiteralPath (Join-Path $TestDrive 'my [draft].png') -Value 'png' -NoNewline
            Set-Content -LiteralPath (Join-Path $TestDrive 'notes.txt') -Value 'text' -NoNewline
            Set-Content -LiteralPath (Join-Path $TestDrive 'noupload.png') -Value 'png' -NoNewline
        }

        It 'returns Markdown that shows images and escapes brackets in the name' {
            $upload = InModuleScope PSLinear -Parameters @{ Path = (Join-Path $TestDrive 'my [draft].png') } {
                param($Path)
                Invoke-LinearFileUpload -File (Get-Item -LiteralPath $Path)
            }
            $upload.Markdown | Should -Be '![my \[draft\].png](https://uploads.linear.app/asset/my [draft].png)'
            $upload.ContentType | Should -Be 'image/png'
            $upload.Public | Should -BeFalse
        }

        It 'links other files instead of showing them' {
            $upload = InModuleScope PSLinear -Parameters @{ Path = (Join-Path $TestDrive 'notes.txt') } {
                param($Path)
                Invoke-LinearFileUpload -File (Get-Item -LiteralPath $Path)
            }
            $upload.Markdown | Should -Be '[notes.txt](https://uploads.linear.app/asset/notes.txt)'
        }

        It 'stops when Linear provides no upload URL' {
            { InModuleScope PSLinear -Parameters @{ Path = (Join-Path $TestDrive 'noupload.png') } { param($Path) Invoke-LinearFileUpload -File (Get-Item -LiteralPath $Path) } } |
                Should -Throw -ErrorId 'PSLinear.UploadFailed*'
            Should -Invoke Send-LinearFileUpload -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'retries network failures, then reports the last one' {
            Mock -ModuleName PSLinear Send-LinearFileUpload { throw 'connection reset' }
            { InModuleScope PSLinear -Parameters @{ Path = (Join-Path $TestDrive 'notes.txt') } { param($Path) Invoke-LinearFileUpload -File (Get-Item -LiteralPath $Path) } } |
                Should -Throw -ErrorId 'PSLinear.UploadFailed*' -ExpectedMessage "*Could not upload 'notes.txt': connection reset*"
            Should -Invoke Send-LinearFileUpload -ModuleName PSLinear -Times 4 -Exactly
            Should -Invoke Start-Sleep -ModuleName PSLinear -Times 3 -Exactly
        }
    }

    Context 'Send-LinearFileUpload' {
        It 'PUTs the file with the signed headers, no credentials, and returns the status code' {
            # The mock keeps Invoke-WebRequest's parameters, so an unsupported parameter fails here.
            Mock -ModuleName PSLinear Invoke-WebRequest { [pscustomobject]@{ StatusCode = 201 } }
            $script:putPath = Join-Path $TestDrive 'put [1].txt'
            Set-Content -LiteralPath $script:putPath -Value 'x' -NoNewline
            $status = InModuleScope PSLinear -Parameters @{ Path = $script:putPath } {
                param($Path)
                Send-LinearFileUpload -Uri 'https://storage.example/put/put.txt' -Path $Path -ContentType 'text/plain' -Headers @{ 'Cache-Control' = 'public' }
            }
            $status | Should -Be 201
            Should -Invoke Invoke-WebRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Put' -and
                $Uri -eq 'https://storage.example/put/put.txt' -and
                $InFile -eq [WildcardPattern]::Escape($script:putPath) -and
                $ContentType -eq 'text/plain' -and
                $Headers['Cache-Control'] -eq 'public' -and
                -not $Headers.ContainsKey('Authorization') -and
                $SkipHttpErrorCheck
            }
        }
    }

    Context 'Format-LinearFileSize' {
        It 'formats <Bytes> bytes as <Text>' -ForEach @(
            @{ Bytes = 512; Text = '512 B' }
            @{ Bytes = 12288; Text = '12 KB' }
            @{ Bytes = 3565158; Text = '3.4 MB' }
        ) {
            InModuleScope PSLinear -Parameters @{ Bytes = $Bytes } { param($Bytes) Format-LinearFileSize -Bytes $Bytes } | Should -Be $Text
        }
    }
}
