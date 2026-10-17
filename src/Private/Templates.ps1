function Get-LinearTemplateCache {
    <#
    .SYNOPSIS
        Returns every template in the workspace (issue, project and document templates), cached for a few minutes.
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.Template')]
    param(
        [switch] $Refresh
    )

    if ($Refresh -or $null -eq $script:LinearTemplateCache -or [datetime]::UtcNow -ge $script:LinearTemplateCacheExpires) {
        $data = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'ListTemplates')
        $script:LinearTemplateCache = @(Get-LinearNestedValue -InputObject $data -Name 'templates' | ConvertTo-LinearTemplate | Sort-Object -Property Type, Name)
        $script:LinearTemplateCacheExpires = [datetime]::UtcNow.Add($script:CacheLifetime)
    }
    $script:LinearTemplateCache
}

function Resolve-LinearTemplateId {
    <#
    .SYNOPSIS
        Resolves a template name or id to the id of a template that a team can use for one entity type.
    .DESCRIPTION
        Workspace templates and the team's own templates of -Type (issue by default) are
        considered. When a team template and a workspace template share a name, the team's wins.
    .NOTES
        Throws an ErrorRecord (PSLinear.TemplateNotFound or PSLinear.AmbiguousTemplate) that
        callers rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $TeamId,

        [Parameter(Mandatory)]
        [string] $Template,

        [string] $Type = 'issue'
    )

    if (Test-LinearGuid -Value $Template) { return $Template }

    $available = @()
    foreach ($refresh in $false, $true) {
        $available = @(Get-LinearTemplateCache -Refresh:$refresh | Where-Object {
                $null -ne $_ -and $_.Type -eq $Type -and ($null -eq $_.TeamId -or $_.TeamId -eq $TeamId)
            })
        $match = @($available | Where-Object Name -EQ $Template)
        if ($match.Count -gt 1) {
            $teamOwn = @($match | Where-Object { $null -ne $_.TeamId })
            if ($teamOwn.Count -eq 1) { $match = $teamOwn }
        }
        if ($match.Count -eq 1) { return $match[0].Id }
        if ($match.Count -gt 1) {
            throw (New-LinearErrorRecord -Message "Template '$Template' is ambiguous. Use the template id instead: $(($match | ForEach-Object Id) -join ', ')." `
                    -ErrorId 'PSLinear.AmbiguousTemplate' -Category InvalidArgument -TargetObject $Template)
        }
    }

    $scope = if ($TeamId) { " for team $(Get-LinearTeamKey -TeamId $TeamId)" } else { '' }
    throw (New-LinearErrorRecord -Message "No $Type template named '$Template'$scope. Valid templates: $(Format-LinearValueList -Value ($available | ForEach-Object Name))." `
            -ErrorId 'PSLinear.TemplateNotFound' -Category ObjectNotFound -TargetObject $Template)
}
