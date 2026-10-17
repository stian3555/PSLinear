#Requires -Version 7.4
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Module state. Everything here lives for the lifetime of the session.
# ---------------------------------------------------------------------------
$script:LinearContext = $null
$script:LinearRateLimit = $null
$script:LinearTeamCache = $null
$script:LinearTeamCacheExpires = [datetime]::MinValue
$script:LinearUserCache = $null
$script:LinearUserCacheExpires = [datetime]::MinValue
$script:LinearProjectCache = $null
$script:LinearProjectCacheExpires = [datetime]::MinValue
# Per-team caches, keyed by team id: @{ Items = <objects>; Expires = <UTC datetime> }.
$script:LinearWorkflowStateCache = @{}
$script:LinearLabelCache = @{}
$script:LinearCycleCache = @{}
# Keyed by project id.
$script:LinearMilestoneCache = @{}
$script:LinearTemplateCache = $null
$script:LinearTemplateCacheExpires = [datetime]::MinValue
$script:LinearProjectStatusCache = $null
$script:LinearProjectStatusCacheExpires = [datetime]::MinValue
$script:LinearProjectLabelCache = $null
$script:LinearProjectLabelCacheExpires = [datetime]::MinValue
$script:LinearDocumentCache = @{}

$script:ModuleVersion = $ExecutionContext.SessionState.Module.Version
$script:UserAgent = 'PSLinear/{0} PowerShell/{1}' -f $script:ModuleVersion, $PSVersionTable.PSVersion
$script:DefaultEndpoint = 'https://api.linear.app/graphql'
$script:DefaultPageSize = 50
$script:MaxPageSize = 100
$script:CacheLifetime = [timespan]::FromMinutes(10)
# Error messages for unknown names list at most this many valid values.
$script:MaxListedValues = 30

# Workflow state categories in the order Linear shows them.
$script:WorkflowStateTypeOrder = @{
    triage    = 0
    backlog   = 1
    unstarted = 2
    started   = 3
    completed = 4
    canceled  = 5
    duplicate = 6
}

# Project status categories in the order Linear shows them.
$script:ProjectStatusTypeOrder = @{
    backlog   = 0
    planned   = 1
    started   = 2
    paused    = 3
    completed = 4
    canceled  = 5
}

# Health values of project and initiative updates, as the API spells them.
$script:HealthMap = @{
    OnTrack  = 'onTrack'
    AtRisk   = 'atRisk'
    OffTrack = 'offTrack'
}

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
$teamCommands = @(
    'Get-LinearCycle', 'Get-LinearIssue', 'Get-LinearLabel', 'Get-LinearProject', 'Get-LinearTemplate', 'Get-LinearWorkflowState'
    'New-LinearIssue', 'New-LinearProject', 'Set-LinearIssue', 'Set-LinearProject'
)
Register-ArgumentCompleter -CommandName $teamCommands -ParameterName 'Team' -ScriptBlock $teamCompleter
foreach ($parameterName in 'AddTeam', 'RemoveTeam') {
    Register-ArgumentCompleter -CommandName 'Set-LinearProject' -ParameterName $parameterName -ScriptBlock $teamCompleter
}
