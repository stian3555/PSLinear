BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Add-LinearComment' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $request = Get-RequestBody -Body $Body
            $response = Get-LinearTestCommentResponse -Request $request
            if ($null -ne $response) { return $response }
            $response = Get-LinearTestAttachmentResponse -Request $request
            if ($null -ne $response) { return $response }
            Get-LinearTestLookupResponse -Request $request
        }
        Mock -ModuleName PSLinear Send-LinearFileUpload { 200 }
    }

    Context 'Request' {
        It 'comments on an issue and returns the comment' {
            $comment = Add-LinearComment -Issue ENG-1 -Body 'Deployed to staging.'
            $comment.PSObject.TypeNames | Should -Contain 'PSLinear.Comment'
            $comment.Body | Should -Be 'Deployed to staging.'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $commentInput = Get-RequestVariable $Body 'input'
                $null -ne $commentInput -and
                $commentInput['issueId'] -eq 'ENG-1' -and
                $commentInput['body'] -eq 'Deployed to staging.' -and
                $commentInput.Count -eq 2
            }
        }

        It 'takes the issue and body positionally, and accepts an issue URL' {
            Add-LinearComment 'https://linear.app/acme/issue/ENG-7/title' 'Looks good' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $commentInput = Get-RequestVariable $Body 'input'
                $null -ne $commentInput -and $commentInput['issueId'] -eq 'ENG-7' -and $commentInput['body'] -eq 'Looks good'
            }
        }

        It 'comments on a project given by name' {
            Add-LinearComment -Project Website -Body 'Kickoff on Monday' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $commentInput = Get-RequestVariable $Body 'input'
                $null -ne $commentInput -and $commentInput['projectId'] -eq 'project-web' -and -not $commentInput.ContainsKey('issueId')
            }
        }

        It 'comments on an initiative given by name or piped in' {
            (Add-LinearComment -Initiative 'Q1 growth' -Body 'Kickoff notes').Target | Should -Be 'Q1 growth'
            $initiative = [pscustomobject]@{ PSTypeName = 'PSLinear.Initiative'; Id = 'initiative-reliability'; Name = 'Platform reliability' }
            $initiative | Add-LinearComment -Body 'Scope agreed' | Out-Null
            foreach ($initiativeId in 'initiative-growth', 'initiative-reliability') {
                Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                    $commentInput = Get-RequestVariable $Body 'input'
                    $null -ne $commentInput -and $commentInput['initiativeId'] -eq $initiativeId -and
                    -not $commentInput.ContainsKey('projectId') -and -not $commentInput.ContainsKey('issueId')
                }
            }
        }

        It 'replies on the initiative of the comment replied to' {
            $comment = [pscustomobject]@{ PSTypeName = 'PSLinear.Comment'; Id = 'comment-i1'; Target = 'Q1 growth'; ParentId = $null; IssueId = $null; ProjectId = $null; InitiativeId = 'initiative-growth' }
            $comment | Add-LinearComment -Body 'Agreed' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $commentInput = Get-RequestVariable $Body 'input'
                $null -ne $commentInput -and $commentInput['parentId'] -eq 'comment-i1' -and $commentInput['initiativeId'] -eq 'initiative-growth'
            }
        }

        It 'sends nothing for an initiative with -WhatIf' {
            Add-LinearComment -Initiative 'Q1 growth' -Body 'x' -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'comments on every issue piped in' {
            $issues = @(
                [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-ENG-1'; Identifier = 'ENG-1' }
                [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-ENG-2'; Identifier = 'ENG-2' }
            )
            $issues | Add-LinearComment -Body 'Tracking in ENG-500.' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateComment'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestVariable $Body 'input.issueId') -eq 'issue-ENG-2'
            }
        }
    }

    Context 'Replies' {
        It 'replies to a comment, on the same issue' {
            $reply = Add-LinearComment -ReplyTo comment-1 -Body 'Agreed'
            $reply.ParentId | Should -Be 'comment-1'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $commentInput = Get-RequestVariable $Body 'input'
                $null -ne $commentInput -and
                $commentInput['parentId'] -eq 'comment-1' -and
                $commentInput['issueId'] -eq 'issue-ENG-1'
            }
        }

        It 'adds a reply to a reply to the same thread' {
            Add-LinearComment -ReplyTo comment-2 -Body 'Me too' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestVariable $Body 'input.parentId') -eq 'comment-1'
            }
        }

        It 'replies to piped comments without looking them up' {
            $comment = [pscustomobject]@{ PSTypeName = 'PSLinear.Comment'; Id = 'comment-p1'; Target = 'Website'; ParentId = $null; IssueId = $null; ProjectId = 'project-web' }
            $comment | Add-LinearComment -Body 'See you there' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $commentInput = Get-RequestVariable $Body 'input'
                $null -ne $commentInput -and $commentInput['parentId'] -eq 'comment-p1' -and $commentInput['projectId'] -eq 'project-web'
            }
        }

        It 'writes one error when the comment to reply to does not exist' {
            $reply = Add-LinearComment -ReplyTo missing -Body 'Hello?' -ErrorAction SilentlyContinue -ErrorVariable replyErrors
            $reply | Should -BeNullOrEmpty
            $replyErrors.Count | Should -Be 1
            $replyErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.CommentNotFound*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateComment'
            }
        }
    }

    Context 'Attachments' {
        BeforeEach {
            Set-Content -LiteralPath (Join-Path $TestDrive 'after.png') -Value 'png' -NoNewline
            Set-Content -LiteralPath (Join-Path $TestDrive 'trace.txt') -Value 'trace' -NoNewline
        }

        It 'uploads the files and adds them after the text, images shown and other files linked' {
            $comment = Add-LinearComment ENG-1 'After the fix:' -Attachment (Join-Path $TestDrive 'after.png'), (Join-Path $TestDrive 'trace.txt')
            $comment.Body | Should -Be "After the fix:`n`n![after.png](https://uploads.linear.app/asset/after.png)`n`n[trace.txt](https://uploads.linear.app/asset/trace.txt)"
            Should -Invoke Send-LinearFileUpload -ModuleName PSLinear -Times 2 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'RequestFileUpload' -and (Get-RequestVariable $Body 'makePublic') -eq $false
            }
        }

        It 'comments with only attachments' {
            (Add-LinearComment -Issue ENG-1 -Attachment (Join-Path $TestDrive 'after.png')).Body |
                Should -Be '![after.png](https://uploads.linear.app/asset/after.png)'
        }

        It 'uploads images to a public URL with -Public, with a warning' {
            Add-LinearComment -Issue ENG-1 -Attachment (Join-Path $TestDrive 'after.png') -Public -WarningVariable uploadWarnings -WarningAction SilentlyContinue | Out-Null
            $uploadWarnings.Count | Should -Be 1
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'RequestFileUpload' -and (Get-RequestVariable $Body 'makePublic') -eq $true
            }
        }

        It 'refuses to make non-images public, before sending anything' {
            { Add-LinearComment -Issue ENG-1 -Attachment (Join-Path $TestDrive 'trace.txt') -Public } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'needs a body or an attachment, and -Public needs an attachment' {
            { Add-LinearComment -Issue ENG-1 } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            { Add-LinearComment -Issue ENG-1 -Body 'x' -Public } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
        }

        It 'stops on a missing file before sending anything' {
            { Add-LinearComment -Issue ENG-1 -Body 'x' -Attachment (Join-Path $TestDrive 'nope.png') } | Should -Throw -ErrorId 'PSLinear.FileNotFound*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'uploads nothing with -WhatIf' {
            Add-LinearComment -Issue ENG-1 -Body 'x' -Attachment (Join-Path $TestDrive 'after.png') -WhatIf
            Should -Invoke Send-LinearFileUpload -ModuleName PSLinear -Times 0 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context '-WhatIf' {
        It 'sends no request, not even the project or comment lookups' {
            Add-LinearComment -Issue ENG-1 -Body 'x' -WhatIf
            Add-LinearComment -Project Website -Body 'x' -WhatIf
            Add-LinearComment -ReplyTo comment-2 -Body 'x' -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Errors' {
        It 'writes one error when Linear rejects the comment' {
            $comment = Add-LinearComment -Issue ENG-1 -Body 'reject' -ErrorAction SilentlyContinue -ErrorVariable commentErrors
            $comment | Should -BeNullOrEmpty
            $commentErrors.Count | Should -Be 1
            $commentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.CommentCreateFailed*'
            $commentErrors[0].Exception.Message | Should -BeLike 'Linear did not add the comment to ENG-1. Linear API error: Argument Validation Error*'
        }

        It 'stops on an unknown project' {
            { Add-LinearComment -Project Intranet -Body 'x' } | Should -Throw -ErrorId 'PSLinear.ProjectNotFound*'
        }

        It 'rejects objects that cannot have comments' {
            $team = [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-eng'; Key = 'ENG' }
            { $team | Add-LinearComment -Body 'x' } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
        }
    }
}
