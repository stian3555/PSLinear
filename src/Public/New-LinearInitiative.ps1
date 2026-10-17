function New-LinearInitiative {
    <#
    .SYNOPSIS
        Creates a Linear initiative.

    .DESCRIPTION
        Creates an initiative and returns it. Names are resolved to ids for you: the owner, the
        lead team and initiative labels. An unknown name stops the command with an error that
        lists the valid values. With -WhatIf nothing is sent, not even the name lookups.

        To add projects to the new initiative, use Set-LinearInitiative -AddProject.

    .PARAMETER Name
        The initiative name.

    .PARAMETER Description
        A short summary, shown under the initiative name. Use -Content for the full write-up.

    .PARAMETER Content
        The initiative's content, in Markdown.

    .PARAMETER Owner
        The owner, who usually posts the status updates: 'me', an email address, a user id, or
        the user's full name or display name.

    .PARAMETER LeadTeam
        The team that leads the initiative: a team key, name or id. Linear derives the
        initiative's visibility from it. This needs Linear's team initiatives feature, which not
        every plan includes; without it, Linear refuses the initiative. Supports tab completion
        once connected.

    .PARAMETER Status
        Proposed, Planned, Active, Completed or Canceled.

    .PARAMETER Priority
        None, Urgent, High, Medium or Low, or the number 0 to 4 (0 None, 1 Urgent, 4 Low).

    .PARAMETER TargetDate
        The planned completion date. Only the date part is used.

    .PARAMETER Label
        Initiative label names or ids. Initiative labels are separate from issue and project
        labels.

    .EXAMPLE
        New-LinearInitiative 'Q1 growth' -Owner me -Status Planned -TargetDate 2027-03-31

        Creates a planned initiative with an owner and a target date.

    .EXAMPLE
        New-LinearInitiative 'Platform reliability' -LeadTeam ENG -Priority High | Set-LinearInitiative -AddProject 'Incident tooling', 'On-call'

        Creates an initiative and adds two projects to it.

    .INPUTS
        None

    .OUTPUTS
        PSLinear.Initiative

    .LINK
        Get-LinearInitiative

    .LINK
        Set-LinearInitiative

    .LINK
        Remove-LinearInitiative
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PSLinear.Initiative')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [string] $Description,

        [string] $Content,

        [ValidateNotNullOrEmpty()]
        [string] $Owner,

        [ValidateNotNullOrEmpty()]
        [string] $LeadTeam,

        [ValidateSet('Proposed', 'Planned', 'Active', 'Completed', 'Canceled')]
        [string] $Status,

        [ArgumentCompletions('None', 'Urgent', 'High', 'Medium', 'Low')]
        [ValidatePattern('^(?:None|Urgent|High|Medium|Low|[0-4])$', ErrorMessage = "'{0}' is not a priority. Use None, Urgent, High, Medium, Low, or 0 to 4.")]
        [string] $Priority,

        [datetime] $TargetDate,

        [ValidateNotNullOrEmpty()]
        [string[]] $Label
    )

    $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters `
        -Name 'Description', 'Content', 'Owner', 'LeadTeam', 'Status', 'Priority', 'TargetDate', 'Label'
    $action = if ($changes) { "Create initiative '$Name' ($changes)" } else { "Create initiative '$Name'" }
    if (-not $PSCmdlet.ShouldProcess('workspace', $action)) {
        return
    }

    try {
        $initiativeInput = @{ name = $Name }
        if ($PSBoundParameters.ContainsKey('Description')) { $initiativeInput['description'] = $Description }
        if ($PSBoundParameters.ContainsKey('Content')) { $initiativeInput['content'] = $Content }
        if ($Owner) { $initiativeInput['ownerId'] = Resolve-LinearUserId -User $Owner }
        if ($LeadTeam) { $initiativeInput['leadTeamId'] = Resolve-LinearTeamId -Team $LeadTeam }
        if ($Status) { $initiativeInput['status'] = $Status }
        if ($Priority) { $initiativeInput['priority'] = ConvertTo-LinearPriority -Priority $Priority }
        if ($PSBoundParameters.ContainsKey('TargetDate')) { $initiativeInput['targetDate'] = ConvertTo-LinearTimelessDate -Date $TargetDate }
        if ($Label) { $initiativeInput['labelIds'] = @(Resolve-LinearInitiativeLabelId -Label $Label) }
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateInitiative') -Variables @{ input = $initiativeInput } -IncludeErrors
    $initiative = Get-LinearNestedValue -InputObject $result.Data -Name 'initiativeCreate.initiative'
    if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'initiativeCreate.success') -or $null -eq $initiative) {
        $message = Format-LinearFailureMessage -Message "Linear did not create initiative '$Name'." -Errors $result.Errors
        $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.InitiativeCreateFailed' -Category WriteError -TargetObject $Name))
        return
    }
    # So that -Initiative finds the new initiative by name right away.
    Reset-LinearInitiativeCache
    ConvertTo-LinearInitiative -InputObject $initiative
}
