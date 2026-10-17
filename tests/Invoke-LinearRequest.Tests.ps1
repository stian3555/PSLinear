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
