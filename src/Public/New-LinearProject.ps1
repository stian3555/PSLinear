function New-LinearProject {
    <#
    .SYNOPSIS
        Creates a Linear project.

    .DESCRIPTION
        Creates a project for one or more teams and returns it. Names are resolved to ids for you:
        teams, the lead and members, the status, project labels and the template. An unknown name
        stops the command with an error that lists the valid values. With -WhatIf nothing is
        sent, not even the name lookups.

        Without -Status, Linear puts the project in the workspace's default status (usually
        Backlog or Planned).

    .PARAMETER Name
        The project name.

    .PARAMETER Team
        One or more teams the project belongs to: team keys, names or ids. Supports tab
        completion once connected.

    .PARAMETER Description
        A short summary, shown under the project name. Use -Content for the full write-up.

    .PARAMETER Content
        The project's content, in Markdown: the long description on the project's overview page.

    .PARAMETER Lead
        The project lead: 'me', an email address, a user id, or the user's full name or display
        name. Linear also makes the lead a member.

    .PARAMETER Member
        Project members, given like -Lead.

    .PARAMETER Status
        The project status: a status name (In Progress), a status type (backlog, planned,
        started, paused, completed, canceled) that picks the first status of that type, or a
        status id.

    .PARAMETER Priority
        None, Urgent, High, Medium or Low, or the number 0 to 4 (0 None, 1 Urgent, 4 Low).

    .PARAMETER StartDate
        The planned start date. Only the date part is used.

    .PARAMETER TargetDate
        The planned completion date. Only the date part is used.

    .PARAMETER Label
        Project label names or ids. Project labels are separate from issue labels.

    .PARAMETER Template
        A project template, by name or id, from the first team's or the workspace's templates.
        Values you give in other parameters override the template's.

    .EXAMPLE
        New-LinearProject 'Website relaunch' -Team ENG -Lead me -TargetDate 2026-12-01

        Creates a project with a lead and a target date.

    .EXAMPLE
        New-LinearProject 'Incident tooling' -Team ENG, OPS -Status planned -Priority High -Label Infrastructure -Description 'Faster on-call.'

        Creates a planned project shared by two teams.

    .EXAMPLE
        New-LinearProject 'Q1 launch' -Team ENG -Template Kickoff -WhatIf

        Shows what would be created, without sending anything.

    .INPUTS
        None

    .OUTPUTS
        PSLinear.Project

    .LINK
        Get-LinearProject

    .LINK
        Set-LinearProject

    .LINK
        Remove-LinearProject
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PSLinear.Project')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Team,

        [string] $Description,

        [string] $Content,

        [ValidateNotNullOrEmpty()]
        [string] $Lead,

        [ValidateNotNullOrEmpty()]
        [string[]] $Member,

        [ValidateNotNullOrEmpty()]
        [string] $Status,

        [ArgumentCompletions('None', 'Urgent', 'High', 'Medium', 'Low')]
        [ValidatePattern('^(?:None|Urgent|High|Medium|Low|[0-4])$', ErrorMessage = "'{0}' is not a priority. Use None, Urgent, High, Medium, Low, or 0 to 4.")]
        [string] $Priority,

        [datetime] $StartDate,

        [datetime] $TargetDate,

        [ValidateNotNullOrEmpty()]
        [string[]] $Label,

        [ValidateNotNullOrEmpty()]
        [string] $Template
    )

    $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters `
        -Name 'Description', 'Content', 'Lead', 'Member', 'Status', 'Priority', 'StartDate', 'TargetDate', 'Label', 'Template'
    $action = if ($changes) { "Create project '$Name' ($changes)" } else { "Create project '$Name'" }
    if (-not $PSCmdlet.ShouldProcess("team $($Team -join ', ')", $action)) {
        return
    }

    try {
        $teamIds = @(foreach ($value in $Team) { Resolve-LinearTeamId -Team $value })
        $projectInput = @{ name = $Name; teamIds = $teamIds }
        if ($PSBoundParameters.ContainsKey('Description')) { $projectInput['description'] = $Description }
        if ($PSBoundParameters.ContainsKey('Content')) { $projectInput['content'] = $Content }
        if ($Lead) { $projectInput['leadId'] = Resolve-LinearUserId -User $Lead }
        if ($Member) { $projectInput['memberIds'] = @(foreach ($user in $Member) { Resolve-LinearUserId -User $user }) }
        if ($Status) { $projectInput['statusId'] = Resolve-LinearProjectStatusId -Status $Status }
        if ($Priority) { $projectInput['priority'] = ConvertTo-LinearPriority -Priority $Priority }
        if ($PSBoundParameters.ContainsKey('StartDate')) { $projectInput['startDate'] = ConvertTo-LinearTimelessDate -Date $StartDate }
        if ($PSBoundParameters.ContainsKey('TargetDate')) { $projectInput['targetDate'] = ConvertTo-LinearTimelessDate -Date $TargetDate }
        if ($Label) { $projectInput['labelIds'] = @(Resolve-LinearProjectLabelId -Label $Label) }
        if ($Template) { $projectInput['templateId'] = Resolve-LinearTemplateId -TeamId $teamIds[0] -Template $Template -Type 'project' }
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateProject') -Variables @{ input = $projectInput } -IncludeErrors
    $project = Get-LinearNestedValue -InputObject $result.Data -Name 'projectCreate.project'
    if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'projectCreate.success') -or $null -eq $project) {
        $message = Format-LinearFailureMessage -Message "Linear did not create project '$Name'." -Errors $result.Errors
        $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.ProjectCreateFailed' -Category WriteError -TargetObject $Name))
        return
    }
    # So that -Project finds the new project by name right away.
    Reset-LinearProjectCache
    ConvertTo-LinearProject -InputObject $project
}
