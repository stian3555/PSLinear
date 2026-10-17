function Get-LinearAttachment {
    <#
    .SYNOPSIS
        Gets the attachments of Linear issues.

    .DESCRIPTION
        Returns the attachments listed in an issue's sidebar: uploaded files, linked URLs and
        links created by integrations such as GitHub or Slack (see the Source property), oldest
        first. Give issues by identifier (ENG-123), UUID or URL, pipe them in, or use -Id for
        specific attachments.

        A missing issue or attachment writes a non-terminating error and the remaining input is
        still processed.

    .PARAMETER Issue
        One or more issue identifiers (ENG-123), UUIDs or issue URLs.

    .PARAMETER InputObject
        PSLinear.Issue objects, typically from Get-LinearIssue.

    .PARAMETER Id
        One or more attachment ids.

    .EXAMPLE
        Get-LinearAttachment ENG-123

        Lists an issue's attachments.

    .EXAMPLE
        Get-LinearIssue -Assignee me -All | Get-LinearAttachment | Where-Object Source -EQ 'github'

        Lists the GitHub links on your issues.

    .INPUTS
        System.String
        PSLinear.Issue

    .OUTPUTS
        PSLinear.Attachment

    .LINK
        Add-LinearAttachment

    .LINK
        Remove-LinearAttachment
    #>
    [CmdletBinding(DefaultParameterSetName = 'Issue')]
    [OutputType('PSLinear.Attachment')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'Issue')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Issue,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Issue')]
        [object[]] $InputObject,

        [Parameter(Mandatory, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($attachmentId in $Id) {
                $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'GetAttachment') -Variables @{ id = $attachmentId } -IncludeErrors
                $attachment = Get-LinearNestedValue -InputObject $result.Data -Name 'attachment'
                if ($null -eq $attachment) {
                    $message = Format-LinearFailureMessage -Message "Attachment '$attachmentId' was not found." -Errors $result.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.AttachmentNotFound' -Category ObjectNotFound -TargetObject $attachmentId))
                    continue
                }
                ConvertTo-LinearAttachment -InputObject $attachment
            }
            return
        }

        $targets = if ($PSCmdlet.ParameterSetName -eq 'Issue') { Get-LinearIssueTarget -Id $Issue } else { Get-LinearIssueTarget -InputObject $InputObject }
        foreach ($target in $targets) {
            $result = Invoke-LinearPagedRequest -Query (Get-LinearGraphQLDocument -Name 'ListIssueAttachments') -ConnectionPath 'issue.attachments' `
                -Variables @{ id = $target.Id } -Limit 0 -IncludeErrors
            if ($result.Errors.Count -gt 0) {
                $message = Format-LinearFailureMessage -Message "Issue '$($target.Name)' was not found." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.IssueNotFound' -Category ObjectNotFound -TargetObject $target.Name))
                continue
            }
            $attachments = @($result.Nodes | ConvertTo-LinearAttachment | Sort-Object -Property CreatedAt)
            foreach ($attachment in $attachments) { $attachment }
        }
    }
}
