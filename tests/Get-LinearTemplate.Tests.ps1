BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Get-LinearTemplate' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            Get-LinearTestLookupResponse -Request (Get-RequestBody -Body $Body)
        }
    }

    It 'lists every template, sorted by type and name, as typed objects' {
        $templates = @(Get-LinearTemplate)
        ($templates | ForEach-Object { '{0}:{1}:{2}' -f $_.Type, $_.Name, $_.Team }) |
            Should -Be @('document:RFC:', 'issue:Bug report:', 'issue:Bug report:ENG', 'issue:Incident:OPS', 'project:Kickoff:')
        $templates[0].PSObject.TypeNames | Should -Contain 'PSLinear.Template'
    }

    It 'lists the issue templates a team can use' {
        (Get-LinearTemplate -Type Issue -Team ENG).Id | Should -Be @('template-bug', 'template-eng-bug')
    }

    It 'filters by name with wildcards and reports names that match nothing' {
        (Get-LinearTemplate -Name 'Kick*').Id | Should -Be 'template-kickoff'
        $templates = @(Get-LinearTemplate -Name 'RFC', 'Nope' -ErrorAction SilentlyContinue -ErrorVariable templateErrors)
        $templates.Id | Should -Be @('template-rfc')
        $templateErrors.Count | Should -Be 1
        $templateErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.TemplateNotFound*'
    }

    It 'exposes the content a template fills in' {
        (Get-LinearTemplate -Name 'Bug report' -Team ENG | Where-Object Team -EQ 'ENG').Content | Should -Be '## Repro'
    }
}
