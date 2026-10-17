function Remove-LinearAttachment {
    <#
    .SYNOPSIS
        Removes attachments from Linear issues.

    .DESCRIPTION
        Removes attachments, given by id or piped in from Get-LinearAttachment, from their
        issues. An uploaded file stays reachable at its URL for anyone who already has the link.
        The command asks for confirmation for each attachment; use -Confirm:$false to skip that,
        or -WhatIf to see what would happen without sending anything.

        A missing attachment, or one Linear refuses to remove, writes a non-terminating error and
        the remaining attachments are still processed. Nothing is returned.

    .PARAMETER Id
        One or more attachment ids.

    .PARAMETER InputObject
        PSLinear.Attachment objects, typically from Get-LinearAttachment.

    .EXAMPLE
        Get-LinearAttachment ENG-123 | Where-Object Title -Like '*.log' | Remove-LinearAttachment

        Removes the log files attached to an issue, asking for each.

    .EXAMPLE
        Remove-LinearAttachment -Id 3f2a9c1e-0000-4000-8000-000000000000 -Confirm:$false

        Removes one attachment without asking.

    .INPUTS
        System.String
        PSLinear.Attachment

    .OUTPUTS
        None

    .LINK
        Get-LinearAttachment
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Attachment')]
        [object[]] $InputObject
    )

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($attachmentId in $Id) { [pscustomobject]@{ Id = $attachmentId; Name = "attachment $attachmentId" } }
        }
        else {
            foreach ($attachment in $InputObject) {
                $title = Get-LinearNestedValue -InputObject $attachment -Name 'Title'
                $issue = Get-LinearNestedValue -InputObject $attachment -Name 'Issue'
                [pscustomobject]@{ Id = $attachment.Id; Name = "attachment '$title'$(if ($issue) { " on $issue" })" }
            }
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, 'Remove attachment')) {
                continue
            }
            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'DeleteAttachment') -Variables @{ id = $target.Id } -IncludeErrors
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'attachmentDelete.success')) {
                $message = Format-LinearFailureMessage -Message "Linear did not remove $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.AttachmentDeleteFailed' -Category WriteError -TargetObject $target.Id))
            }
        }
    }
}
