BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Invoke-LinearRequest' {
    BeforeEach {
        $env:LINEAR_API_KEY = $null
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey' -MaxRetries 3
            $script:LinearRateLimit = $null
        }
        Mock -ModuleName PSLinear Start-Sleep { }
    }

    AfterAll {
        InModuleScope PSLinear { $script:LinearContext = $null }
    }

    Context 'Authentication header' {
        It 'sends a personal API key without the Bearer prefix' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest { New-LinearTestResponse -Data @{ ok = $true } }
            InModuleScope PSLinear { Invoke-LinearRequest -Query '{ viewer { id } }' } | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $Headers.Authorization -eq 'lin_api_test'
            }
        }

        It 'sends an OAuth token with the Bearer prefix' {
            InModuleScope PSLinear {
                $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'oauth-token') -AuthScheme 'OAuth'
            }
            Mock -ModuleName PSLinear Send-LinearHttpRequest { New-LinearTestResponse -Data @{ ok = $true } }
            InModuleScope PSLinear { Invoke-LinearRequest -Query '{ viewer { id } }' } | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                $Headers.Authorization -eq 'Bearer oauth-token'
            }
        }

        It 'identifies itself with a PSLinear user agent' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest { New-LinearTestResponse -Data @{ ok = $true } }
            InModuleScope PSLinear { Invoke-LinearRequest -Query '{ viewer { id } }' } | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter { $Headers['User-Agent'] -like 'PSLinear/*' }
        }
    }

    Context 'Request body' {
        It 'sends query and variables as JSON' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest { New-LinearTestResponse -Data @{ ok = $true } }
            InModuleScope PSLinear {
                Invoke-LinearRequest -Query 'query($id: String!) { issue(id: $id) { id } }' -Variables @{ id = 'ENG-1'; nested = @{ list = @('a') } }
            } | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                $request = Get-RequestBody -Body $Body
                $request.query -like 'query($id*' -and $request.variables.id -eq 'ENG-1' -and $request.variables.nested.list -is [array]
            }
        }

        It 'omits variables when none are given' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest { New-LinearTestResponse -Data @{ ok = $true } }
            InModuleScope PSLinear { Invoke-LinearRequest -Query '{ viewer { id } }' } | Out-Null
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
                -not (Get-RequestBody -Body $Body).ContainsKey('variables')
            }
        }
    }

    Context 'Successful responses' {
        It 'returns the data property' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest { New-LinearTestResponse -Data @{ viewer = @{ id = 'u1' } } }
            $data = InModuleScope PSLinear { Invoke-LinearRequest -Query '{ viewer { id } }' }
            $data.viewer.id | Should -Be 'u1'
        }

        It 'records rate-limit headers' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                New-LinearTestResponse -Data @{ ok = $true } -Headers @{
                    'X-RateLimit-Requests-Limit'       = '2500'
                    'X-RateLimit-Requests-Remaining'   = '2499'
                    'X-RateLimit-Requests-Reset'       = '1792224000000'
                    'X-RateLimit-Complexity-Limit'     = '3000000'
                    'X-RateLimit-Complexity-Remaining' = '2999000'
                    'X-RateLimit-Complexity-Reset'     = '1792224000000'
                    'X-Complexity'                     = '42'
                }
            }
            InModuleScope PSLinear { Invoke-LinearRequest -Query '{ viewer { id } }' } | Out-Null
            $rateLimit = Get-LinearRateLimit
            $rateLimit.RequestsRemaining | Should -Be 2499
            $rateLimit.ComplexityLimit | Should -Be 3000000
            $rateLimit.LastQueryComplexity | Should -Be 42
            $rateLimit.RequestsReset | Should -BeOfType [datetimeoffset]
            $rateLimit.RequestsReset.ToUnixTimeMilliseconds() | Should -Be 1792224000000
        }
    }

    Context 'Errors' {
        It 'throws when the response contains GraphQL errors, even with HTTP 200' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                New-LinearTestResponse -Data $null -Errors @(New-LinearTestError -Message 'Entity not found' -Code 'INVALID_INPUT' -Path 'issue')
            }
            { InModuleScope PSLinear { Invoke-LinearRequest -Query '{ issue(id: "x") { id } }' } } |
                Should -Throw -ExpectedMessage '*Entity not found (code: INVALID_INPUT, path: issue)*' -ErrorId 'PSLinear.GraphQLError*'
        }

        It 'combines several GraphQL errors into one message' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                New-LinearTestResponse -Errors @((New-LinearTestError -Message 'First'), (New-LinearTestError -Message 'Second'))
            }
            { InModuleScope PSLinear { Invoke-LinearRequest -Query '{ x }' } } | Should -Throw -ExpectedMessage '*First; Second*'
        }

        It 'reports authentication failures clearly and does not retry' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                New-LinearTestResponse -StatusCode 400 -Errors @(New-LinearTestError -Message 'Authentication required' -Code 'AUTHENTICATION_ERROR')
            }
            { InModuleScope PSLinear { Invoke-LinearRequest -Query '{ viewer { id } }' } } |
                Should -Throw -ErrorId 'PSLinear.AuthenticationFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
        }

        It 'throws on HTTP errors without a GraphQL body' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest { [pscustomobject]@{ StatusCode = 404; Headers = @{}; Content = 'Not Found' } }
            { InModuleScope PSLinear { Invoke-LinearRequest -Query '{ x }' } } | Should -Throw -ErrorId 'PSLinear.HttpError*'
        }

        It 'throws a clear error when not connected' {
            InModuleScope PSLinear { $script:LinearContext = $null }
            { InModuleScope PSLinear { Invoke-LinearRequest -Query '{ x }' } } |
                Should -Throw -ExpectedMessage '*Connect-Linear*' -ErrorId 'PSLinear.NotConnected*'
        }
    }

    Context 'Retries' {
        It 'retries a rate-limited request and then succeeds' {
            $script:attempts = 0
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                $script:attempts++
                if ($script:attempts -lt 3) {
                    return New-LinearTestResponse -StatusCode 400 -Errors @(New-LinearTestError -Message 'Rate limit exceeded' -Code 'RATELIMITED')
                }
                New-LinearTestResponse -Data @{ ok = $true }
            }
            $data = InModuleScope PSLinear { Invoke-LinearRequest -Query '{ x }' }
            $data.ok | Should -BeTrue
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 3 -Exactly
            Should -Invoke Start-Sleep -ModuleName PSLinear -Times 2 -Exactly
        }

        It 'gives up after MaxRetries and reports the rate limit' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                New-LinearTestResponse -StatusCode 400 -Errors @(New-LinearTestError -Message 'Rate limit exceeded' -Code 'RATELIMITED')
            }
            { InModuleScope PSLinear { Invoke-LinearRequest -Query '{ x }' } } | Should -Throw -ErrorId 'PSLinear.RateLimited*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 4 -Exactly
        }

        It 'retries server errors' {
            $script:attempts = 0
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                $script:attempts++
                if ($script:attempts -eq 1) { return [pscustomobject]@{ StatusCode = 503; Headers = @{}; Content = 'Unavailable' } }
                New-LinearTestResponse -Data @{ ok = $true }
            }
            (InModuleScope PSLinear { Invoke-LinearRequest -Query '{ x }' }).ok | Should -BeTrue
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly
        }

        It 'retries network failures and then reports a connection error' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest { throw [System.Net.Http.HttpRequestException]::new('No such host') }
            { InModuleScope PSLinear { Invoke-LinearRequest -Query '{ x }' } } |
                Should -Throw -ExpectedMessage '*No such host*' -ErrorId 'PSLinear.ConnectionFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 4 -Exactly
        }

        It 'does not retry when MaxRetries is 0' {
            InModuleScope PSLinear { $script:LinearContext.MaxRetries = 0 }
            Mock -ModuleName PSLinear Send-LinearHttpRequest { [pscustomobject]@{ StatusCode = 500; Headers = @{}; Content = 'Boom' } }
            { InModuleScope PSLinear { Invoke-LinearRequest -Query '{ x }' } } | Should -Throw
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
        }

        It 'throws server errors even with -IncludeErrors, so they are not mistaken for an expected error' {
            InModuleScope PSLinear { $script:LinearContext.MaxRetries = 0 }
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                New-LinearTestResponse -StatusCode 500 -Data $null -Errors @(New-LinearTestError -Message 'Internal error' -Code 'INTERNAL_ERROR')
            }
            { InModuleScope PSLinear { Invoke-LinearRequest -Query '{ issue(id: "ENG-1") { id } }' -IncludeErrors } } |
                Should -Throw -ExpectedMessage '*Internal error*' -ErrorId 'PSLinear.GraphQLError*'
        }
    }

    Context 'Mutations' {
        BeforeAll {
            $script:mutation = 'mutation CreateIssue($input: IssueCreateInput!) { issueCreate(input: $input) { success } }'
        }

        It 'does not send a mutation again after a server error, and says the outcome is unknown' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest { [pscustomobject]@{ StatusCode = 503; Headers = @{}; Content = 'Unavailable' } }
            { InModuleScope PSLinear -Parameters @{ Query = $script:mutation } { param($Query) Invoke-LinearRequest -Query $Query -IncludeErrors } } |
                Should -Throw -ExpectedMessage '*HTTP 503 for mutation CreateIssue*may or may not have made the change*' -ErrorId 'PSLinear.MutationOutcomeUnknown*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
            Should -Invoke Start-Sleep -ModuleName PSLinear -Times 0 -Exactly
        }

        It 'does not send a mutation again when the connection fails after it was sent' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                throw [System.Net.Http.HttpRequestException]::new('The response ended prematurely.', [System.IO.IOException]::new('Connection reset by peer'))
            }
            { InModuleScope PSLinear -Parameters @{ Query = $script:mutation } { param($Query) Invoke-LinearRequest -Query $Query } } |
                Should -Throw -ExpectedMessage '*during mutation CreateIssue (The response ended prematurely.)*' -ErrorId 'PSLinear.MutationOutcomeUnknown*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
        }

        It 'sends a mutation again when it never reached Linear' {
            $script:attempts = 0
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                $script:attempts++
                if ($script:attempts -eq 1) { throw [System.Net.Http.HttpRequestException]::new([System.Net.Http.HttpRequestError]::NameResolutionError, 'No such host') }
                if ($script:attempts -eq 2) {
                    throw [System.Net.Http.HttpRequestException]::new([System.Net.Http.HttpRequestError]::ConnectionError, 'Connection refused',
                        [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::ConnectionRefused))
                }
                New-LinearTestResponse -Data @{ issueCreate = @{ success = $true } }
            }
            $data = InModuleScope PSLinear -Parameters @{ Query = $script:mutation } { param($Query) Invoke-LinearRequest -Query $Query }
            $data.issueCreate.success | Should -BeTrue
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 3 -Exactly
        }

        It 'reports a connection error when a mutation never reached Linear after every retry' {
            Mock -ModuleName PSLinear Send-LinearHttpRequest { throw [System.Net.Http.HttpRequestException]::new([System.Net.Http.HttpRequestError]::NameResolutionError, 'No such host') }
            { InModuleScope PSLinear -Parameters @{ Query = $script:mutation } { param($Query) Invoke-LinearRequest -Query $Query } } |
                Should -Throw -ErrorId 'PSLinear.ConnectionFailed*'
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 4 -Exactly
        }

        It 'sends a rate-limited mutation again, because Linear refused it before running it' {
            $script:attempts = 0
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                $script:attempts++
                if ($script:attempts -eq 1) {
                    return New-LinearTestResponse -StatusCode 400 -Errors @(New-LinearTestError -Message 'Rate limit exceeded' -Code 'RATELIMITED') -Headers @{ 'Retry-After' = '2' }
                }
                New-LinearTestResponse -Data @{ issueCreate = @{ success = $true } }
            }
            $data = InModuleScope PSLinear -Parameters @{ Query = $script:mutation } { param($Query) Invoke-LinearRequest -Query $Query }
            $data.issueCreate.success | Should -BeTrue
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly
            Should -Invoke Start-Sleep -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 2000 }
        }

        It 'still retries the queries of a document that also defines a mutation, when the query is the one that runs' {
            $script:attempts = 0
            Mock -ModuleName PSLinear Send-LinearHttpRequest {
                $script:attempts++
                if ($script:attempts -eq 1) { return [pscustomobject]@{ StatusCode = 502; Headers = @{}; Content = 'Bad gateway' } }
                New-LinearTestResponse -Data @{ ok = $true }
            }
            $document = "mutation Rename { issueUpdate(id: `"ENG-1`", input: { title: `"x`" }) { success } }`nquery Read { viewer { id } }"
            (InModuleScope PSLinear -Parameters @{ Query = $document } { param($Query) Invoke-LinearRequest -Query $Query -OperationName 'Read' }).ok | Should -BeTrue
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly
        }
    }
}

Describe 'Get-LinearOperation' {
    It 'reads <Case>' -ForEach @(
        @{ Case = 'a shorthand query'; Document = '{ viewer { id } }'; OperationName = $null; Type = 'query'; Name = $null }
        @{ Case = 'a named query'; Document = 'query Viewer { viewer { id } }'; OperationName = $null; Type = 'query'; Name = 'Viewer' }
        @{ Case = 'a mutation with variables'; Document = 'mutation CreateIssue($input: IssueCreateInput!) { issueCreate(input: $input) { success } }'; OperationName = $null; Type = 'mutation'; Name = 'CreateIssue' }
        @{ Case = 'a mutation after a fragment'; Document = "fragment F on Issue { id }`nmutation M { issueUpdate(id: `"x`", input: {}) { issue { ...F } } }"; OperationName = $null; Type = 'mutation'; Name = 'M' }
        @{ Case = 'a mutation after a comment'; Document = "# mutation in a comment`n  mutation { x }"; OperationName = $null; Type = 'mutation'; Name = $null }
        @{ Case = 'a query with a field named mutation'; Document = 'query Q { a { mutation } }'; OperationName = $null; Type = 'query'; Name = 'Q' }
        @{ Case = 'a query whose string mentions a mutation'; Document = 'query Q { issues(filter: { title: { eq: "} mutation M {" } }) { nodes { id } } }'; OperationName = $null; Type = 'query'; Name = 'Q' }
        @{ Case = 'a query with an object default value'; Document = 'query Q($f: IssueFilter = { title: { eq: "x" } }) { issues(filter: $f) { nodes { id } } }'; OperationName = $null; Type = 'query'; Name = 'Q' }
        @{ Case = 'an anonymous mutation with a directive'; Document = 'mutation @deprecated { x }'; OperationName = $null; Type = 'mutation'; Name = $null }
        @{ Case = 'the operation given by name'; Document = "query A { a }`nmutation B { b }"; OperationName = 'B'; Type = 'mutation'; Name = 'B' }
        @{ Case = 'several operations without a name as a mutation'; Document = "query A { a }`nmutation B { b }"; OperationName = $null; Type = 'mutation'; Name = $null }
    ) {
        $operation = InModuleScope PSLinear -Parameters @{ Document = $Document; OperationName = $OperationName } {
            param($Document, $OperationName)
            Get-LinearOperation -Document $Document -OperationName $OperationName
        }
        $operation.Type | Should -Be $Type
        $operation.Name | Should -Be $Name
    }
}

Describe 'Test-LinearRequestNotSent' {
    It 'returns <Expected> for <Case>' -ForEach @(
        @{ Case = 'a name that did not resolve'; Exception = [System.Net.Http.HttpRequestException]::new([System.Net.Http.HttpRequestError]::NameResolutionError, 'x'); Expected = $true }
        @{ Case = 'a connection that could not be made'; Exception = [System.Net.Http.HttpRequestException]::new([System.Net.Http.HttpRequestError]::ConnectionError, 'x'); Expected = $true }
        @{ Case = 'a failed TLS handshake'; Exception = [System.Net.Http.HttpRequestException]::new([System.Net.Http.HttpRequestError]::SecureConnectionError, 'x'); Expected = $true }
        @{ Case = 'a refused socket inside another exception'; Exception = [System.Exception]::new('x', [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::ConnectionRefused)); Expected = $true }
        @{ Case = 'a response that ended early'; Exception = [System.Net.Http.HttpRequestException]::new([System.Net.Http.HttpRequestError]::ResponseEnded, 'x'); Expected = $false }
        @{ Case = 'a connection reset during the request'; Exception = [System.Net.Http.HttpRequestException]::new('x', [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::ConnectionReset)); Expected = $false }
        @{ Case = 'a timeout'; Exception = [System.Threading.Tasks.TaskCanceledException]::new('x'); Expected = $false }
    ) {
        InModuleScope PSLinear -Parameters @{ Exception = $Exception } { param($Exception) Test-LinearRequestNotSent -Exception $Exception } | Should -Be $Expected
    }
}

Describe 'Get-LinearRetryDelay' {
    It 'backs off exponentially' {
        InModuleScope PSLinear {
            (Get-LinearRetryDelay -Attempt 1) | Should -BeGreaterOrEqual 1000
            (Get-LinearRetryDelay -Attempt 1) | Should -BeLessThan 1250
            (Get-LinearRetryDelay -Attempt 3) | Should -BeGreaterOrEqual 4000
        }
    }

    It 'honours Retry-After' {
        InModuleScope PSLinear {
            Get-LinearRetryDelay -Attempt 1 -Headers @{ 'Retry-After' = '7' } | Should -Be 7000
        }
    }

    It 'never waits longer than a minute for Retry-After' {
        InModuleScope PSLinear {
            Get-LinearRetryDelay -Attempt 1 -Headers @{ 'Retry-After' = '3600' } | Should -Be 60000
        }
    }
}

Describe 'Invoke-LinearPagedRequest' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $request = Get-RequestBody -Body $Body
            $start = if ($request.variables.after) { [int]$request.variables.after } else { 0 }
            $size = [int]$request.variables.first
            $end = [math]::Min($start + $size, 230)
            $nodes = @(for ($i = $start; $i -lt $end; $i++) { @{ id = "item-$i" } })
            New-LinearTestResponse -Data @{ items = (New-LinearTestConnection -Nodes $nodes -HasNextPage ($end -lt 230) -EndCursor "$end") }
        }
    }

    It 'stops at the limit' {
        $result = InModuleScope PSLinear { @(Invoke-LinearPagedRequest -Query 'q' -ConnectionPath 'items' -Limit 10) }
        $result.Count | Should -Be 10
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter { (Get-RequestBody $Body).variables.first -eq 10 }
    }

    It 'follows endCursor until the end when the limit is 0' {
        $result = InModuleScope PSLinear { @(Invoke-LinearPagedRequest -Query 'q' -ConnectionPath 'items' -Limit 0) }
        $result.Count | Should -Be 230
        $result[-1].id | Should -Be 'item-229'
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 3 -Exactly
    }

    It 'never asks for more than the maximum page size' {
        InModuleScope PSLinear { Invoke-LinearPagedRequest -Query 'q' -ConnectionPath 'items' -Limit 150 } | Out-Null
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter { (Get-RequestBody $Body).variables.first -eq 100 } -Times 1 -Exactly
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter { (Get-RequestBody $Body).variables.first -eq 50 } -Times 1 -Exactly
    }

    It 'stops requesting pages when the pipeline stops early' {
        InModuleScope PSLinear { Invoke-LinearPagedRequest -Query 'q' -ConnectionPath 'items' -Limit 0 | Select-Object -First 3 } | Out-Null
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
    }

    It 'supports nested connection paths' {
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            New-LinearTestResponse -Data @{ team = @{ issues = (New-LinearTestConnection -Nodes @(@{ id = 'a' }, @{ id = 'b' })) } }
        }
        $result = InModuleScope PSLinear { @(Invoke-LinearPagedRequest -Query 'q' -ConnectionPath 'team.issues') }
        $result.id | Should -Be @('a', 'b')
    }
}
