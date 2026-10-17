#Requires -Version 7.4
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Module state. Everything here lives for the lifetime of the session.
# ---------------------------------------------------------------------------
$script:LinearContext = $null
$script:LinearRateLimit = $null
$script:LinearTeamCache = $null
$script:LinearTeamCacheExpires = [datetime]::MinValue
$script:LinearDocumentCache = @{}

$script:ModuleVersion = $ExecutionContext.SessionState.Module.Version
$script:UserAgent = 'PSLinear/{0} PowerShell/{1}' -f $script:ModuleVersion, $PSVersionTable.PSVersion
$script:DefaultEndpoint = 'https://api.linear.app/graphql'
$script:DefaultPageSize = 50
$script:MaxPageSize = 100
$script:TeamCacheLifetime = [timespan]::FromMinutes(10)

# Linear priority values (0-4) and their labels.
$script:PriorityMap = [ordered]@{
    None   = 0
    Urgent = 1
    High   = 2
    Medium = 3
    Low    = 4
}

# ---------------------------------------------------------------------------
# GraphQL documents. Operations live in GraphQL/*.graphql, reusable fragments
# in GraphQL/Fragments/*.graphql (file name must equal the fragment name).
# ---------------------------------------------------------------------------
$script:GraphQLOperations = @{}
$script:GraphQLFragments = @{}
$graphQLRoot = Join-Path -Path $PSScriptRoot -ChildPath 'GraphQL'
foreach ($file in Get-ChildItem -LiteralPath $graphQLRoot -Filter '*.graphql' -File -Recurse) {
    $target = if ($file.Directory.Name -eq 'Fragments') { $script:GraphQLFragments } else { $script:GraphQLOperations }
    $target[$file.BaseName] = Get-Content -LiteralPath $file.FullName -Raw
}

#region Functions
# During development the functions are dot-sourced from Private/ and Public/.
# build.ps1 replaces this region with the inlined function definitions.
foreach ($folder in 'Private', 'Public') {
    $folderPath = Join-Path -Path $PSScriptRoot -ChildPath $folder
    foreach ($file in Get-ChildItem -LiteralPath $folderPath -Filter '*.ps1' -File) {
        . $file.FullName
    }
}
#endregion Functions

# ---------------------------------------------------------------------------
# Argument completers. These run inside the module scope, so they can use
# private helpers. A completer must never throw or prompt.
# ---------------------------------------------------------------------------
$teamCompleter = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    $null = $commandName, $parameterName, $commandAst, $fakeBoundParameters
    try {
        if (-not (Test-LinearConnection)) { return }
        foreach ($team in Get-LinearTeamCache) {
            if ($team.Key -like "$wordToComplete*" -or $team.Name -like "$wordToComplete*") {
                [System.Management.Automation.CompletionResult]::new($team.Key, $team.Key, 'ParameterValue', $team.Name)
            }
        }
    }
    catch {
        Write-Debug "Team completion failed: $($_.Exception.Message)"
    }
}
Register-ArgumentCompleter -CommandName 'Get-LinearIssue' -ParameterName 'Team' -ScriptBlock $teamCompleter
