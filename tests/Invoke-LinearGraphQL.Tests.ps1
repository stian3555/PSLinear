BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Invoke-LinearGraphQL' {
    BeforeEach {
        InModuleScope PSLinear {
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest { New-LinearTestResponse -Data @{ viewer = @{ id = 'u1' } } }
    }

    It 'runs a query and returns data' {
        (Invoke-LinearGraphQL -Query '{ viewer { id } }').viewer.id | Should -Be 'u1'
    }

    It 'passes variables and the operation name' {
        Invoke-LinearGraphQL -Query 'query A($id: String!) { issue(id: $id) { id } }' -Variables @{ id = 'ENG-1' } -OperationName 'A' | Out-Null
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -ParameterFilter {
            $request = Get-RequestBody $Body
            $request.variables.id -eq 'ENG-1' -and $request.operationName -eq 'A'
        }
    }

    It 'reads the document from a file' {
        $path = Join-Path $TestDrive 'Viewer.graphql'
        Set-Content -Path $path -Value '{ viewer { id } }'
        (Invoke-LinearGraphQL -Path $path).viewer.id | Should -Be 'u1'
    }

    It 'accepts the query from the pipeline' {
        ('{ viewer { id } }' | Invoke-LinearGraphQL).viewer.id | Should -Be 'u1'
    }

    It 'does not send a mutation with -WhatIf' {
        Invoke-LinearGraphQL -Query 'mutation Rename { issueUpdate(id: "ENG-1", input: { title: "x" }) { success } }' -WhatIf
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
    }

    It 'detects mutations after comments and whitespace' {
        $mutation = "# rename an issue`n`n  mutation { issueUpdate(id: `"ENG-1`", input: { title: `"x`" }) { success } }"
        Invoke-LinearGraphQL -Query $mutation -WhatIf
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly
    }

    It 'runs queries even with -WhatIf, because they change nothing' {
        Invoke-LinearGraphQL -Query '{ viewer { id } }' -WhatIf | Out-Null
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
    }
}
