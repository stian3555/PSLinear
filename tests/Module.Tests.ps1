BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $modulePath = Get-PSLinearTestModulePath
    Import-Module $modulePath -Force
    $script:publicCommands = @(Get-Command -Module PSLinear -CommandType Function | ForEach-Object {
            @{ Name = $_.Name; Command = $_ }
        })
    $script:graphQLOperations = @((Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'src' 'GraphQL') -Filter '*.graphql' -File).BaseName)
    $confirmImpacts = @{ Add = 'Low'; New = 'Low'; Set = 'Medium'; Remove = 'High' }
    $script:stateChangingCommands = @(Get-Command -Module PSLinear -CommandType Function | Where-Object { $confirmImpacts.ContainsKey($_.Verb) } | ForEach-Object {
            @{ Name = $_.Name; Command = $_; Impact = $confirmImpacts[$_.Verb] }
        })
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:modulePath = Get-PSLinearTestModulePath
    Import-Module $script:modulePath -Force
    $script:manifest = Import-PowerShellDataFile -Path $script:modulePath
}

Describe 'Module manifest' {
    It 'is valid' {
        { Test-ModuleManifest -Path $script:modulePath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'has the metadata PowerShell Gallery needs' {
        $script:manifest.Description | Should -Not -BeNullOrEmpty
        $script:manifest.Author | Should -Not -BeNullOrEmpty
        $script:manifest.PrivateData.PSData.Tags | Should -Contain 'Linear'
        $script:manifest.PrivateData.PSData.LicenseUri | Should -Not -BeNullOrEmpty
        $script:manifest.PrivateData.PSData.ProjectUri | Should -Not -BeNullOrEmpty
    }

    It 'exports exactly the functions in the Public folder' {
        $sourceRoot = Join-Path $PSScriptRoot '..' 'src' 'Public'
        $expected = (Get-ChildItem -Path $sourceRoot -Filter '*.ps1').BaseName | Sort-Object
        $script:manifest.FunctionsToExport | Sort-Object | Should -Be $expected
        (Get-Command -Module PSLinear -CommandType Function).Name | Sort-Object | Should -Be $expected
    }

    It 'does not export private helpers' {
        Get-Command -Module PSLinear -Name 'Invoke-LinearRequest' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'Public command <Name>' -ForEach $script:publicCommands {
    BeforeAll {
        $script:help = Get-Help -Name $Name -Full
    }

    It 'uses an approved verb' {
        $Command.Verb | Should -BeIn (Get-Verb).Verb
    }

    It 'uses the Linear noun prefix' {
        $Command.Noun | Should -BeLike 'Linear*'
    }

    It 'has a synopsis and a description' {
        $script:help.Synopsis | Should -Not -BeNullOrEmpty
        # Without comment-based help, PowerShell generates a synopsis that starts with the syntax.
        $script:help.Synopsis.Trim() | Should -Not -BeLike "$Name *"
        ($script:help.Description.Text -join '') | Should -Not -BeNullOrEmpty
    }

    It 'has at least one example' {
        @($script:help.Examples.Example).Count | Should -BeGreaterThan 0
    }

    It 'documents every parameter' {
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        $parameters = $Command.Parameters.Keys | Where-Object { $_ -notin $common }
        foreach ($parameter in $parameters) {
            $documented = $script:help.Parameters.Parameter | Where-Object Name -EQ $parameter
            ($documented.Description.Text -join '') | Should -Not -BeNullOrEmpty -Because "parameter -$parameter should be documented"
        }
    }

    It 'declares an output type' {
        $Command.OutputType | Should -Not -BeNullOrEmpty
    }
}

Describe 'State-changing command <Name>' -ForEach $script:stateChangingCommands {
    It 'supports -WhatIf and -Confirm with ConfirmImpact <Impact>' {
        $binding = $Command.ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        $binding.SupportsShouldProcess | Should -BeTrue
        $binding.ConfirmImpact | Should -Be $Impact
    }
}

Describe 'GraphQL documents' {
    It 'names every fragment file after the fragment it defines' {
        InModuleScope PSLinear {
            foreach ($name in $script:GraphQLFragments.Keys) {
                $script:GraphQLFragments[$name] | Should -Match "fragment\s+$name\s+on\s+"
            }
        }
    }

    It 'assembles <_> with all fragments it uses' -ForEach $script:graphQLOperations {
        InModuleScope PSLinear -Parameters @{ Name = $_ } {
            param($Name)
            $document = Get-LinearGraphQLDocument -Name $Name
            $spreads = [regex]::Matches($document, '(?<!\.)\.\.\.\s*(?!on\b)([_A-Za-z]\w*)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
            foreach ($spread in $spreads) {
                $document | Should -Match "fragment\s+$spread\s+on\s+"
            }
        }
    }

    It 'throws for an unknown operation' {
        InModuleScope PSLinear {
            { Get-LinearGraphQLDocument -Name 'DoesNotExist' } | Should -Throw '*Unknown GraphQL operation*'
        }
    }
}
