BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Document commands' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $request = Get-RequestBody -Body $Body
            $lookup = Get-LinearTestLookupResponse -Request $request
            if ($lookup) { return $lookup }
            $response = Get-LinearTestDocumentResponse -Request $request
            if ($null -ne $response) { return $response }
            Get-LinearTestCommentResponse -Request $request
        }
    }

    Context 'Get-LinearDocument' {
        It 'lists every document, most recently updated first, as typed objects without content' {
            $documents = @(Get-LinearDocument)
            $documents.Id | Should -Be @('doc-notes', 'doc-plan', 'doc-handbook', 'doc-goals')
            $plan = $documents[1]
            $plan.PSObject.TypeNames | Should -Contain 'PSLinear.Document'
            $plan.Title | Should -Be 'Launch plan'
            $plan.Container | Should -Be 'Website'
            $plan.ContainerType | Should -Be 'Project'
            $plan.ProjectId | Should -Be 'project-web'
            $plan.Owner | Should -Be 'Ada Lovelace'
            $plan.UpdatedBy | Should -Be 'Grace Hopper'
            $plan.DocumentContentId | Should -Be 'content-plan'
            $plan.Content | Should -BeNullOrEmpty
            $documents[0].ContainerType | Should -Be 'Issue'
            $documents[0].Container | Should -Be 'ENG-1'
            # Linear no longer reports a document's team.
            $documents[2].Container | Should -BeNullOrEmpty
            $documents[2].ContainerType | Should -BeNullOrEmpty
            $documents[2].PSObject.Properties.Name | Should -Not -Contain 'TeamId'
            $documents[3].ContainerType | Should -Be 'Initiative'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListDocuments' -and $null -eq (Get-RequestVariable $Body 'filter') -and (Get-RequestVariable $Body 'includeArchived') -eq $false
            }
        }

        It 'filters by issue identifier, project, initiative and team' {
            (Get-LinearDocument -Issue ENG-1).Id | Should -Be 'doc-notes'
            (Get-LinearDocument -Issue 'https://linear.app/acme/issue/ENG-1/some-title').Id | Should -Be 'doc-notes'
            (Get-LinearDocument -Project Website).Id | Should -Be 'doc-plan'
            (Get-LinearDocument -Initiative 'Q1 growth').Id | Should -Be 'doc-goals'
            (Get-LinearDocument -Team OPS).Id | Should -Be 'doc-handbook'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListDocuments' -and (Get-RequestVariable $Body 'filter.issue.id.eq') -eq 'ENG-1'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestVariable $Body 'filter.project.id.eq') -eq 'project-web'
            }
        }

        It 'combines several containers with and' {
            @(Get-LinearDocument -Project Website -Team OPS) | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListDocuments' -and @(Get-RequestVariable $Body 'filter.and').Count -eq 2
            }
        }

        It 'includes archived documents with -IncludeArchived' {
            (Get-LinearDocument -Project Website -IncludeArchived).Id | Should -Be @('doc-plan', 'doc-old')
        }

        It 'filters by title with wildcards and reports titles that match nothing' {
            (Get-LinearDocument -Title '*plan').Id | Should -Be 'doc-plan'
            $documents = @(Get-LinearDocument -Title 'Launch plan', 'Roadmap' -ErrorAction SilentlyContinue -ErrorVariable documentErrors)
            $documents.Id | Should -Be @('doc-plan')
            $documentErrors.Count | Should -Be 1
            $documentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.DocumentNotFound*'
        }

        It 'returns only the most recent documents with -First, after matching titles' {
            @(Get-LinearDocument -First 2).Id | Should -Be @('doc-notes', 'doc-plan')
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestVariable $Body 'first') -eq 2 }
            @(Get-LinearDocument -Title '*o*' -First 1).Id | Should -Be @('doc-notes')
        }

        It 'gets the full document by id, slug id or URL' {
            foreach ($value in 'doc-plan', '419202a9d18c', 'https://linear.app/acme/document/launch-plan-419202a9d18c') {
                $document = Get-LinearDocument -Id $value
                $document.Id | Should -Be 'doc-plan'
                $document.Content | Should -Be "# Launch`nSteps"
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'GetDocument' -and (Get-RequestVariable $Body 'id') -eq '419202a9d18c'
            }
        }

        It 'writes one error for a missing document and returns the others' {
            $documents = @(Get-LinearDocument -Id 'doc-plan', 'nope' -ErrorAction SilentlyContinue -ErrorVariable documentErrors)
            $documents.Id | Should -Be @('doc-plan')
            $documentErrors.Count | Should -Be 1
            $documentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.DocumentNotFound*'
        }

        It 'returns piped documents in full, and lists the documents of piped containers' {
            (Get-LinearDocument -Project Website | Get-LinearDocument).Content | Should -Be "# Launch`nSteps"
            $project = [pscustomobject]@{ PSTypeName = 'PSLinear.Project'; Id = 'project-web'; Name = 'Website' }
            $issue = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-uuid-ENG-1'; Identifier = 'ENG-1' }
            $team = [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-ops'; Key = 'OPS' }
            @($project, $issue, $team | Get-LinearDocument).Id | Should -Be @('doc-plan', 'doc-notes', 'doc-handbook')
        }

        It 'stops for piped objects that cannot hold documents' {
            $comment = [pscustomobject]@{ PSTypeName = 'PSLinear.Comment'; Id = 'comment-1' }
            { $comment | Get-LinearDocument } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage 'Documents belong to an issue, a project, an initiative or a team.*'
        }

        It 'stops with the valid names for an unknown project' {
            { Get-LinearDocument -Project Intranet } | Should -Throw -ErrorId 'PSLinear.ProjectNotFound*'
        }
    }

    Context 'New-LinearDocument' {
        It 'creates a document in a project given by name' {
            $document = New-LinearDocument 'Spec' -Project Website -Content "# Spec`nDetails" -Owner grace
            $document.PSObject.TypeNames | Should -Contain 'PSLinear.Document'
            $document.Title | Should -Be 'Spec'
            $document.Container | Should -Be 'Website'
            $document.Owner | Should -Be 'Grace Hopper'
            $document.Content | Should -Be "# Spec`nDetails"
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateDocument' -and
                (Get-RequestVariable $Body 'input.title') -eq 'Spec' -and
                (Get-RequestVariable $Body 'input.projectId') -eq 'project-web' -and
                (Get-RequestVariable $Body 'input.content') -eq "# Spec`nDetails" -and
                (Get-RequestVariable $Body 'input.ownerId') -eq 'user-grace'
            }
        }

        It 'creates a document in an issue' {
            (New-LinearDocument 'Notes' -Issue ENG-7).Container | Should -Be 'ENG-7'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestVariable $Body 'input.issueId') -eq 'ENG-7' }
        }

        It 'refuses teams and initiatives, which Linear no longer accepts, before sending anything' {
            $team = [pscustomobject]@{ PSTypeName = 'PSLinear.Team'; Id = 'team-ops'; Key = 'OPS' }
            $initiative = [pscustomobject]@{ PSTypeName = 'PSLinear.Initiative'; Id = 'initiative-growth'; Name = 'Q1 growth' }
            { $team | New-LinearDocument 'Handbook' } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' `
                -ExpectedMessage "Linear's API no longer creates documents in teams or initiatives, so team OPS cannot hold a new document. Use an issue or a project."
            { $initiative | New-LinearDocument 'Goals' } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage "*so initiative 'Q1 growth' cannot hold*"
            { New-LinearDocument 'Handbook' -Team OPS } | Should -Throw -ErrorId 'NamedParameterNotFound*'
            { New-LinearDocument 'Goals' -Initiative 'Q1 growth' } | Should -Throw -ErrorId 'NamedParameterNotFound*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'stops for piped objects that cannot hold documents, before sending anything' {
            $comment = [pscustomobject]@{ PSTypeName = 'PSLinear.Comment'; Id = 'comment-1' }
            { $comment | New-LinearDocument 'Notes' } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*' `
                -ExpectedMessage 'Documents are created in an issue or a project. Pipe in PSLinear.Issue or PSLinear.Project objects.'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'creates a document in a piped container without looking it up' {
            $issue = [pscustomobject]@{ PSTypeName = 'PSLinear.Issue'; Id = 'issue-uuid-ENG-2'; Identifier = 'ENG-2' }
            ($issue | New-LinearDocument 'Notes' 'Text').Container | Should -Be 'ENG-2'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestVariable $Body 'input.issueId') -eq 'issue-uuid-ENG-2' -and (Get-RequestVariable $Body 'input.content') -eq 'Text'
            }
        }

        It 'sends no content when -Content is not given' {
            $null = New-LinearDocument 'Empty' -Issue ENG-7
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateDocument' -and -not (Get-RequestBody $Body).variables.input.Contains('content')
            }
        }

        It 'sends nothing with -WhatIf' {
            New-LinearDocument 'Never' -Project Website -Owner me -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'writes one error when Linear rejects the document' {
            New-LinearDocument 'reject' -Project Website -ErrorAction SilentlyContinue -ErrorVariable documentErrors | Should -BeNullOrEmpty
            $documentErrors.Count | Should -Be 1
            $documentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.DocumentCreateFailed*'
        }

        It 'stops for an unknown container name' {
            { New-LinearDocument 'Bad' -Project Intranet } | Should -Throw -ErrorId 'PSLinear.ProjectNotFound*'
        }
    }

    Context 'Set-LinearDocument' {
        It 'changes the title, content and owner and returns nothing' {
            Set-LinearDocument -Id doc-plan -Title 'Launch plan v2' -Content '' -Owner grace | Should -BeNullOrEmpty
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateDocument' -and
                (Get-RequestVariable $Body 'id') -eq 'doc-plan' -and
                (Get-RequestVariable $Body 'input.title') -eq 'Launch plan v2' -and
                (Get-RequestVariable $Body 'input.content') -eq '' -and
                (Get-RequestVariable $Body 'input.ownerId') -eq 'user-grace'
            }
        }

        It 'returns the updated document with -PassThru, and accepts slug ids and URLs' {
            (Set-LinearDocument '419202a9d18c' -Title 'Plan' -PassThru).Title | Should -Be 'Plan'
            Set-LinearDocument 'https://linear.app/acme/document/on-call-handbook-ed54ff6c360e' -Title 'Handbook'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateDocument' -and (Get-RequestVariable $Body 'id') -eq 'ed54ff6c360e'
            }
        }

        It 'moves documents to another container' {
            $moved = Set-LinearDocument -Id doc-plan -Issue ENG-9 -PassThru
            $moved.ContainerType | Should -Be 'Issue'
            $moved.ProjectId | Should -BeNullOrEmpty
            Get-LinearDocument -Team OPS | Set-LinearDocument -Project 'Mobile App'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'UpdateDocument' -and (Get-RequestVariable $Body 'id') -eq 'doc-handbook' -and
                (Get-RequestVariable $Body 'input.projectId') -eq 'project-mobile'
            }
            { Set-LinearDocument -Id doc-plan -Team OPS } | Should -Throw -ErrorId 'NamedParameterNotFound*'
        }

        It 'clears the owner' {
            Set-LinearDocument -Id doc-plan -Clear Owner
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $documentInput = (Get-RequestBody $Body).variables['input']
                $documentInput.Contains('ownerId') -and $null -eq $documentInput['ownerId']
            }
        }

        It 'updates piped documents and writes one error for a missing one' {
            Get-LinearDocument | Set-LinearDocument -Title 'Renamed'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 4 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'UpdateDocument' }
            'nope', 'doc-plan' | Set-LinearDocument -Title 'x' -ErrorAction SilentlyContinue -ErrorVariable documentErrors
            $documentErrors.Count | Should -Be 1
            $documentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.DocumentUpdateFailed*'
        }

        It 'rejects conflicting parameters, or no change at all, before sending anything' {
            { Set-LinearDocument -Id doc-plan -Issue ENG-1 -Project Website } |
                Should -Throw -ErrorId 'PSLinear.InvalidArgument*' -ExpectedMessage 'Use either -Issue or -Project, not both.'
            { Set-LinearDocument -Id doc-plan -Clear Owner -Owner me } | Should -Throw -ExpectedMessage 'Use either -Clear Owner or -Owner, not both.'
            { Set-LinearDocument -Id doc-plan } | Should -Throw -ErrorId 'PSLinear.InvalidArgument*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'sends nothing with -WhatIf' {
            Set-LinearDocument -Id doc-plan -Title 'x' -Project Website -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Remove-LinearDocument' {
        It 'moves documents to the trash, by id, slug id and piped' {
            Remove-LinearDocument -Id doc-plan -Confirm:$false | Should -BeNullOrEmpty
            Remove-LinearDocument 'https://linear.app/acme/document/on-call-handbook-ed54ff6c360e' -Confirm:$false
            Get-LinearDocument -Team OPS | Remove-LinearDocument -Confirm:$false
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'DeleteDocument' -and (Get-RequestVariable $Body 'id') -eq 'ed54ff6c360e'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 3 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'DeleteDocument' }
        }

        It 'writes one error for a missing document and goes on' {
            Remove-LinearDocument 'nope', 'doc-plan' -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable documentErrors
            $documentErrors.Count | Should -Be 1
            $documentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.DocumentDeleteFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'DeleteDocument' }
        }

        It 'sends nothing with -WhatIf' {
            Remove-LinearDocument -Id doc-plan -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
        }
    }

    Context 'Comments on documents' {
        It 'lists a document''s comments thread by thread' {
            $comments = @(Get-LinearComment -Document '419202a9d18c')
            $comments.Id | Should -Be @('comment-d1', 'comment-d2')
            $comments[0].Target | Should -Be 'Launch plan'
            $comments[0].DocumentId | Should -Be 'doc-plan'
            $comments[0].DocumentContentId | Should -Be 'content-plan'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'ListDocumentComments' -and (Get-RequestVariable $Body 'id') -eq '419202a9d18c'
            }
        }

        It 'lists the comments of piped documents and writes one error for a missing document' {
            @(Get-LinearDocument -Project Website | Get-LinearComment).Count | Should -Be 2
            Get-LinearComment -Document nope -ErrorAction SilentlyContinue -ErrorVariable commentErrors
            $commentErrors.Count | Should -Be 1
            $commentErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.DocumentNotFound*'
        }

        It 'comments on a document given by URL, attaching to its content' {
            $comment = Add-LinearComment -Document 'https://linear.app/acme/document/launch-plan-419202a9d18c' -Body 'Looks good'
            $comment.DocumentId | Should -Be 'doc-plan'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'CreateComment' -and (Get-RequestVariable $Body 'input.documentContentId') -eq 'content-plan'
            }
        }

        It 'comments on piped documents without looking them up, and replies on the same document' {
            $document = [pscustomobject]@{ PSTypeName = 'PSLinear.Document'; Id = 'doc-plan'; Title = 'Launch plan'; DocumentContentId = 'content-plan' }
            $document | Add-LinearComment -Body 'Piped' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
            $comment = [pscustomobject]@{ PSTypeName = 'PSLinear.Comment'; Id = 'comment-d1'; Target = 'Launch plan'; ParentId = $null; IssueId = $null; ProjectId = $null; InitiativeId = $null; DocumentContentId = 'content-plan' }
            $comment | Add-LinearComment -Body 'Reply' | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestVariable $Body 'input.parentId') -eq 'comment-d1' -and (Get-RequestVariable $Body 'input.documentContentId') -eq 'content-plan'
            }
        }

        It 'stops for a missing document, and sends nothing with -WhatIf' {
            { Add-LinearComment -Document nope -Body 'x' } | Should -Throw -ErrorId 'PSLinear.DocumentNotFound*'
            Add-LinearComment -Document doc-plan -Body 'x' -WhatIf
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'CreateComment' }
        }
    }
}
