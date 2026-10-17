function Get-LinearInitiative {
    <#
    .SYNOPSIS
        Gets initiatives in the Linear workspace.

    .DESCRIPTION
        Returns the workspace's initiatives, sorted by name, with their status, health, owner,
        projects, labels and target date. Use -Name to filter; wildcards are supported. A name
        without wildcards that matches no initiative writes a non-terminating error. -Status
        narrows the list further.

        Use -Id, or pipe in initiatives, to get the full initiative: its content, every project
        and label, and its sub-initiatives. Lists leave Content and SubInitiatives empty and show
        at most 20 projects and labels per initiative.

        The list also refreshes the cache that other commands use to resolve -Initiative.

    .PARAMETER Name
        One or more initiative names. Wildcards are supported.

    .PARAMETER Status
        Only initiatives with these statuses: Proposed, Planned, Active, Completed or Canceled.

    .PARAMETER IncludeArchived
        Also returns archived initiatives.

    .PARAMETER Id
        One or more initiative ids, slug ids (the hex suffix of an initiative URL) or initiative
        URLs. Returns the full initiatives.

    .PARAMETER InputObject
        PSLinear.Initiative objects, typically from Get-LinearInitiative. Returns them again in
        full.

    .EXAMPLE
        Get-LinearInitiative

        Lists the initiatives.

    .EXAMPLE
        Get-LinearInitiative -Status Active | Where-Object Health -NE 'OnTrack'

        Lists the active initiatives that are not on track.

    .EXAMPLE
        Get-LinearInitiative 'Q1 growth' | Get-LinearInitiative | Select-Object -ExpandProperty Projects

        Lists every project in an initiative.

    .INPUTS
        System.String
        PSLinear.Initiative

    .OUTPUTS
        PSLinear.Initiative

    .LINK
        New-LinearInitiative

    .LINK
        Set-LinearInitiative

    .LINK
        Get-LinearInitiativeUpdate
    #>
    [CmdletBinding(DefaultParameterSetName = 'List')]
    [OutputType('PSLinear.Initiative')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ParameterSetName = 'List')]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name,

        [Parameter(ParameterSetName = 'List')]
        [ValidateSet('Proposed', 'Planned', 'Active', 'Completed', 'Canceled')]
        [string[]] $Status,

        [Parameter(ParameterSetName = 'List')]
        [switch] $IncludeArchived,

        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Initiative')]
        [object[]] $InputObject
    )

    begin {
        $requestedNames = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'List') {
            if ($Name) { $requestedNames.AddRange([string[]]$Name) }
            return
        }

        $references = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($value in $Id) { ConvertFrom-LinearInitiativeUrl -Value $value }
        }
        else {
            foreach ($initiative in $InputObject) { $initiative.Id }
        }
        foreach ($reference in $references) {
            $result = Get-LinearInitiativeDetail -Id $reference
            if ($null -eq $result.Initiative) {
                $message = Format-LinearFailureMessage -Message "Initiative '$reference' was not found." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.InitiativeNotFound' -Category ObjectNotFound -TargetObject $reference))
                continue
            }
            ConvertTo-LinearInitiative -InputObject $result.Initiative
        }
    }

    end {
        if ($PSCmdlet.ParameterSetName -ne 'List') { return }

        $initiatives = if ($IncludeArchived) { @(Get-LinearInitiativeList -IncludeArchived) } else { @(Get-LinearInitiativeCache -Refresh) }
        if ($Status) {
            $initiatives = @($initiatives | Where-Object { $null -ne $_ -and $_.Status -in $Status })
        }

        if ($requestedNames.Count -eq 0) {
            foreach ($initiative in $initiatives) { $initiative }
            return
        }

        $selection = Select-LinearObjectByName -InputObject $initiatives -Name $requestedNames -Property 'Name'
        foreach ($missing in $selection.Missing) {
            $PSCmdlet.WriteError((New-LinearErrorRecord -Message "Initiative '$missing' was not found." `
                        -ErrorId 'PSLinear.InitiativeNotFound' -Category ObjectNotFound -TargetObject $missing))
        }
        foreach ($initiative in $selection.Selected) { $initiative }
    }
}
