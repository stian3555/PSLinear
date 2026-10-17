BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Set-LinearComment' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestCommentResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    Context 'Editing' {
        It 'changes the text and returns nothing' {
            Set-LinearComment -Id comment-1 -Body 'Edited' | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                (Get-RequestOperation $Body) -eq 'UpdateComment' -and $request.variables.id -eq 'comment-1' -and $request.variables.input.body -eq 'Edited'
            }
        }

        It 'returns the edited comment with -PassThru' {
            $comment = Set-LinearComment comment-1 -Body 'Edited' -PassThru
            $comment.Body | Should -Be 'Edited'
            $comment.EditedAt | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Resolving' {
        It 'resolves a thread by its first comment, looking up whether it is a reply' {
            Set-LinearComment -Id comment-1 -Resolved $true
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'GetComment'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                (Get-RequestOperation $Body) -eq 'ResolveComment' -and $request.variables.id -eq 'comment-1' -and -not $request.variables.ContainsKey('resolvingCommentId')
            }
        }

        It 'resolves the thread of a reply, recording the reply as the resolution' {
            $thread = Set-LinearComment -Id comment-2 -Resolved $true -PassThru
            $thread.Id | Should -Be 'comment-1'
            $thread.Resolved | Should -BeTrue
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $request = Get-RequestBody $Body
                (Get-RequestOperation $Body) -eq 'ResolveComment' -and $request.variables.id -eq 'comment-1' -and $request.variables.resolvingCommentId -eq 'comment-2'
            }
        }

        It 'uses piped comments without looking them up' {
            $comments = @(
                [pscustomobject]@{ PSTypeName = 'PSLinear.Comment'; Id = 'comment-1'; Target = 'ENG-1'; ParentId = $null }
                [pscustomobject]@{ PSTypeName = 'PSLinear.Comment'; Id = 'comment-2'; Target = 'ENG-1'; ParentId = 'comment-1' }
            )
            $comments | Set-LinearComment -Resolved $true
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'GetComment'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ResolveComment' -and (Get-RequestBody $Body).variables.id -eq 'comment-1'
            }
        }

        It 'reopens a thread through any of its comments' {
            $thread = Set-LinearComment -Id comment-2 -Resolved $false -PassThru
            $thread.Resolved | Should -BeFalse
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                (Get-RequestOperation $Body) -eq 'UnresolveComment' -and $request.variables.id -eq 'comment-1'
            }
        }

        It 'edits and resolves in one call, using the edited comment to find the thread' {
            Set-LinearComment -Id comment-2 -Body 'Done' -Resolved $true
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'GetComment'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateComment' }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ResolveComment' }
        }
    }

    Context 'Errors and -WhatIf' {
        It 'requires -Body or -Resolved' {
            { Set-LinearComment -Id comment-1 } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'sends no request with -WhatIf' {
            'comment-1', 'comment-2' | Set-LinearComment -Body 'x' -Resolved $true -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'writes one error for a missing comment and updates the rest' {
            $updated = @('missing', 'comment-1' | Set-LinearComment -Body 'x' -PassThru -ErrorAction SilentlyContinue -ErrorVariable commentErrors)
            $updated.Id | Should -Be @('comment-1')
            $commentErrors.Count | Should -Be 1
            $commentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.CommentUpdateFailed*'
        }

        It 'writes one error when the comment to resolve does not exist' {
            Set-LinearComment -Id missing -Resolved $true -ErrorAction SilentlyContinue -ErrorVariable commentErrors
            $commentErrors.Count | Should -Be 1
            $commentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.CommentNotFound*'
        }
    }
}
