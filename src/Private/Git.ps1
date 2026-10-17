function Invoke-LinearGit {
    <#
    .SYNOPSIS
        Runs git with the given arguments in the current location and returns its exit code and output.
    .DESCRIPTION
        Returns [pscustomobject]@{ ExitCode; Output }, where Output holds the lines git wrote to
        standard output and standard error. This is the only place the module starts git, so
        tests can mock it.
    .NOTES
        Throws an ErrorRecord (PSLinear.GitNotFound) when git is not installed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Argument
    )

    $git = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) {
        throw (New-LinearErrorRecord -Message 'git was not found. Install git, or use -NoBranch.' `
                -ErrorId 'PSLinear.GitNotFound' -Category ObjectNotFound -TargetObject 'git')
    }
    $output = & $git.Source @Argument 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = [string[]]@($output | ForEach-Object { "$_" })
    }
}

function Get-LinearGitBranch {
    <#
    .SYNOPSIS
        Returns the name of the git branch checked out in the current location.
    .NOTES
        Throws an ErrorRecord (PSLinear.NotInGitRepository or PSLinear.DetachedHead) that callers
        rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $result = Invoke-LinearGit -Argument 'rev-parse', '--abbrev-ref', 'HEAD'
    if ($result.ExitCode -ne 0) {
        throw (New-LinearErrorRecord -Message "$((Get-Location).Path) is not in a git repository: $($result.Output -join ' ')" `
                -ErrorId 'PSLinear.NotInGitRepository' -Category ObjectNotFound -TargetObject (Get-Location).Path)
    }
    $branch = "$($result.Output | Select-Object -First 1)".Trim()
    if ($branch -eq 'HEAD') {
        throw (New-LinearErrorRecord -Message 'No branch is checked out (detached HEAD), so there is no issue to find.' `
                -ErrorId 'PSLinear.DetachedHead' -Category InvalidOperation -TargetObject $branch)
    }
    $branch
}

function Test-LinearGitRepository {
    <#
    .SYNOPSIS
        Returns whether the current location is inside a git working tree.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $result = Invoke-LinearGit -Argument 'rev-parse', '--is-inside-work-tree'
    $result.ExitCode -eq 0 -and "$($result.Output | Select-Object -First 1)".Trim() -eq 'true'
}

function Find-LinearIssueIdentifier {
    <#
    .SYNOPSIS
        Finds the issue identifier in a git branch name, such as ENG-123 in ada/eng-123-fix-login.
    .DESCRIPTION
        Only identifiers with the key of a team in the workspace count, so 'release-2' in
        'release-2-eng-123' is skipped. Returns the identifier in upper case, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Branch
    )

    $keys = @(Get-LinearTeamCache | Where-Object { $null -ne $_ } | ForEach-Object Key)
    foreach ($candidate in [regex]::Matches($Branch, '(?i)(?<![a-z0-9])([a-z][a-z0-9]*)-(\d+)(?![0-9])')) {
        if ($keys -contains $candidate.Groups[1].Value) {
            return '{0}-{1}' -f $candidate.Groups[1].Value.ToUpperInvariant(), $candidate.Groups[2].Value
        }
    }
    $null
}
