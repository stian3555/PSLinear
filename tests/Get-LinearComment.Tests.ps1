BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Get-LinearComment' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $request = Get-RequestBody -Body $Body
            $response = Get-LinearTestCommentResponse -Request $request
            if ($null -ne $response) { return $response }
            Get-LinearTestLookupResponse -Request $request
        }
    }

    Context 'Issue comments' {
        It 'returns the comments thread by thread, replies under their first comment' {
            $comments = @(Get-LinearComment ENG-1)
            $comments.Id | Should -Be @('comment-3', 'comment-1', 'comment-2', 'comment-4')
            $comments.ThreadId | Should -Be @('comment-3', 'comment-1', 'comment-1', 'comment-4')
            $comments[0].PSObject.TypeNames | Should -Contain 'PSLinear.Comment'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $request = Get-RequestBody $Body
                (Get-RequestOperation $Body) -eq 'ListIssueComments' -and $request.variables.id -eq 'ENG-1'
            }
        }

        It 'flattens author, thread and resolution' {
            $comments = @(Get-LinearComment ENG-1)
            $bot, $first, $reply, $null = $comments
            $bot.Author | Should -Be 'GitHub'
            $bot.Resolved | Should -BeTrue
            $bot.ResolvedBy | Should -Be 'Ada Lovelace'
            $first.Author | Should -Be 'Ada Lovelace'
            $first.AuthorId | Should -Be 'user-ada'
            $first.Target | Should -Be 'ENG-1'
            $first.IsReply | Should -BeFalse
            $first.Resolved | Should -BeFalse
            $reply.IsReply | Should -BeTrue
            $reply.ParentId | Should -Be 'comment-1'
        }

        It 'accepts an issue URL' {
            @(Get-LinearComment 'https://linear.app/acme/issue/ENG-1/some-title').Count | Should -Be 4
        }

        It 'takes identifiers and issue objects from the pipeline' {
            @('ENG-1', 'ENG-2' | Get-LinearComment).Count | Should -Be 4
            $issue = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-ENG-1'; Identifier = 'ENG-1' }
            @($issue | Get-LinearComment).Count | Should -Be 4
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                (Get-RequestVariable $Body 'id') -eq 'issue-ENG-1'
            }
        }

        It 'writes one error for a missing issue and lists the rest' {
            $comments = @('ENG-404', 'ENG-1' | Get-LinearComment -ErrorAction SilentlyContinue -ErrorVariable commentErrors)
            $comments.Count | Should -Be 4
            $commentErrors.Count | Should -Be 1
            $commentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.IssueNotFound*'
            $commentErrors[0].Exception.Message | Should -BeLike "Issue 'ENG-404' was not found. Linear API error: Entity not found*"
        }
    }

    Context 'Initiative comments' {
        It 'resolves the initiative by name and filters comments by its id' {
            $comment = Get-LinearComment -Initiative 'Q1 growth'
            $comment.Id | Should -Be 'comment-i1'
            $comment.Target | Should -Be 'Q1 growth'
            $comment.InitiativeId | Should -Be 'initiative-growth'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListComments' -and
                (Get-RequestVariable $Body 'filter.initiative.id.eq') -eq 'initiative-growth' -and
                $null -eq (Get-RequestVariable $Body 'filter.project')
            }
        }

        It 'takes initiative objects from the pipeline' {
            $initiative = [pscustomobject]@{ PSTypeName = 'PSLinear.Initiative'; Id = 'initiative-growth'; Name = 'Q1 growth' }
            ($initiative | Get-LinearComment).Id | Should -Be 'comment-i1'
        }

        It 'stops on an unknown initiative and lists the valid ones' {
            { Get-LinearComment -Initiative Moonshot } |
                Should -Throw -ErrorId 'PSLinear.InitiativeNotFound*' -ExpectedMessage '*Platform reliability, Q1 growth*'
        }
    }

    Context 'Project comments' {
        It 'resolves the project by name and filters comments by its id' {
            (Get-LinearComment -Project Website).Id | Should -Be 'comment-p1'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestVariable $Body 'filter.project.id.eq') -eq 'project-web'
            }
        }

        It 'accepts a project slug id or URL' {
            (Get-LinearComment -Project 'a1b2c3d4e5f6').Id | Should -Be 'comment-p1'
            (Get-LinearComment -Project 'https://linear.app/acme/project/website-a1b2c3d4e5f6/overview').Id | Should -Be 'comment-p1'
        }

        It 'takes project objects from the pipeline' {
            $project = [pscustomobject]@{ PSTypeName = 'PSLinear.Project'; Id = 'project-web'; Name = 'Website' }
            ($project | Get-LinearComment).Target | Should -Be 'Website'
        }

        It 'stops on an unknown project and lists the valid ones' {
            { Get-LinearComment -Project Intranet } | Should -Throw -ErrorId 'PSLinear.ProjectNotFound*' -ExpectedMessage '*Mobile App, Website*'
        }
    }

    Context 'By id' {
        It 'gets specific comments and writes one error for a missing one' {
            $comments = @(Get-LinearComment -Id 'comment-2', 'missing', 'comment-p1' -ErrorAction SilentlyContinue -ErrorVariable commentErrors)
            $comments.Id | Should -Be @('comment-2', 'comment-p1')
            $commentErrors.Count | Should -Be 1
            $commentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.CommentNotFound*'
        }
    }

    It 'rejects objects that cannot have comments' {
        $team = [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-eng'; Key = 'ENG' }
        { $team | Get-LinearComment } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
    }
}
