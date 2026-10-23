function Set-LinearAttachment {
    <#
    .SYNOPSIS
        Changes the title, subtitle or metadata of Linear issue attachments.

    .DESCRIPTION
        Updates attachments given by id or piped in from Get-LinearAttachment. Linear needs the
        title on every update, so when -Title is not given the current title is kept (looked up
        for attachments given by id). Nothing is returned unless you use -PassThru.

        A missing attachment, or a change Linear rejects, writes a non-terminating error and the
        remaining attachments are still processed.

    .PARAMETER Id
        One or more attachment ids.

    .PARAMETER InputObject
        PSLinear.Attachment objects, typically from Get-LinearAttachment.

    .PARAMETER Title
        The new title.

    .PARAMETER Subtitle
        The new subtitle. An empty string removes it.

    .PARAMETER Metadata
        New metadata for the attachment, as a hashtable of string, number and boolean values. It
        replaces the attachment's metadata; @{} removes it. To change some values and keep the
        rest, use -AddMetadata and -RemoveMetadata instead.

    .PARAMETER AddMetadata
        Metadata values to add or change, as a hashtable of string, number and boolean values.
        The attachment's other metadata is kept, including what integrations store. The current
        metadata is read just before the update, so a change made by someone else in between is
        lost.

    .PARAMETER RemoveMetadata
        Names of metadata values to remove, keeping the others.

    .PARAMETER PassThru
        Returns the updated attachments.

    .EXAMPLE
        Get-LinearAttachment ENG-123 | Where-Object Title -EQ 'screenshot.png' | Set-LinearAttachment -Title 'Login error'

        Renames an attachment.

    .EXAMPLE
        Set-LinearAttachment -Id 3f2a9c1e-0000-4000-8000-000000000000 -Subtitle '' -PassThru

        Removes an attachment's subtitle and returns it.

    .EXAMPLE
        Get-LinearAttachment ENG-123 | Where-Object { $_.Metadata.pipeline -eq 'nightly' } | Set-LinearAttachment -Metadata @{ pipeline = 'nightly'; failures = 0 }

        Updates the metadata of the attachments a nightly pipeline added.

    .EXAMPLE
        Get-LinearAttachment ENG-123 | Where-Object Url -Like 'https://monitor.example/*' | Set-LinearAttachment -AddMetadata @{ resolved = $true } -RemoveMetadata 'snoozedUntil'

        Marks the monitoring attachments as resolved and removes one value, keeping the rest of
        their metadata.

    .INPUTS
        System.String
        PSLinear.Attachment

    .OUTPUTS
        PSLinear.Attachment

    .LINK
        Get-LinearAttachment
    #>
    [CmdletBinding(DefaultParameterSetName = 'ById', SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('PSLinear.Attachment')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'ById')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Id,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'ByObject')]
        [PSTypeName('PSLinear.Attachment')]
        [object[]] $InputObject,

        [ValidateNotNullOrEmpty()]
        [string] $Title,

        [AllowEmptyString()]
        [string] $Subtitle,

        [ValidateNotNull()]
        [System.Collections.IDictionary] $Metadata,

        [ValidateNotNull()]
        [System.Collections.IDictionary] $AddMetadata,

        [ValidateNotNullOrEmpty()]
        [string[]] $RemoveMetadata,

        [switch] $PassThru
    )

    begin {
        $changes = Format-LinearChangeList -BoundParameters $PSBoundParameters -Name 'Title', 'Subtitle', 'Metadata', 'AddMetadata', 'RemoveMetadata'
        if (-not $changes) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message 'Specify -Title, -Subtitle, -Metadata, -AddMetadata, -RemoveMetadata or a combination.' `
                        -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }
        $mergeMetadata = $PSBoundParameters.ContainsKey('AddMetadata') -or $PSBoundParameters.ContainsKey('RemoveMetadata')
        if ($mergeMetadata -and $PSBoundParameters.ContainsKey('Metadata')) {
            $PSCmdlet.ThrowTerminatingError((New-LinearErrorRecord -Message 'Use either -Metadata, which replaces all metadata, or -AddMetadata and -RemoveMetadata, not both.' `
                        -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument))
        }
        try {
            $metadataInput = if ($PSBoundParameters.ContainsKey('Metadata')) { ConvertTo-LinearAttachmentMetadataInput -Metadata $Metadata } else { $null }
            $addMetadataInput = if ($PSBoundParameters.ContainsKey('AddMetadata')) { ConvertTo-LinearAttachmentMetadataInput -Metadata $AddMetadata } else { @{} }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }

    process {
        $targets = if ($PSCmdlet.ParameterSetName -eq 'ById') {
            foreach ($attachmentId in $Id) { [pscustomobject]@{ Id = $attachmentId; Name = "attachment $attachmentId"; Title = $null } }
        }
        else {
            foreach ($attachment in $InputObject) {
                $currentTitle = Get-LinearNestedValue -InputObject $attachment -Name 'Title'
                $issue = Get-LinearNestedValue -InputObject $attachment -Name 'Issue'
                [pscustomobject]@{ Id = $attachment.Id; Name = "attachment '$currentTitle'$(if ($issue) { " on $issue" })"; Title = $currentTitle }
            }
        }

        foreach ($target in $targets) {
            if (-not $PSCmdlet.ShouldProcess($target.Name, "Update attachment ($changes)")) {
                continue
            }

            # Linear needs the title on every update, so keep the current one when only the subtitle
            # changes. Merging metadata always reads the attachment, so it starts from the latest values.
            $current = $null
            if ($mergeMetadata -or (-not $Title -and -not $target.Title)) {
                $lookup = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'GetAttachment') -Variables @{ id = $target.Id } -IncludeErrors
                $current = ConvertTo-LinearAttachment -InputObject (Get-LinearNestedValue -InputObject $lookup.Data -Name 'attachment')
                if ($null -eq $current) {
                    $message = Format-LinearFailureMessage -Message "Attachment '$($target.Id)' was not found." -Errors $lookup.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.AttachmentNotFound' -Category ObjectNotFound -TargetObject $target.Id))
                    continue
                }
            }
            $newTitle = if ($Title) { $Title } elseif ($null -ne $current) { $current.Title } else { $target.Title }

            $attachmentInput = @{ title = $newTitle }
            if ($PSBoundParameters.ContainsKey('Subtitle')) {
                $attachmentInput['subtitle'] = if ($Subtitle) { $Subtitle } else { $null }
            }
            if ($null -ne $metadataInput) { $attachmentInput['metadata'] = $metadataInput }
            if ($mergeMetadata) {
                $merged = $current.Metadata
                foreach ($name in $RemoveMetadata) { $merged.Remove($name) }
                foreach ($key in $addMetadataInput.Keys) { $merged[$key] = $addMetadataInput[$key] }
                $attachmentInput['metadata'] = $merged
            }
            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'UpdateAttachment') `
                -Variables @{ id = $target.Id; input = $attachmentInput } -IncludeErrors
            $updated = Get-LinearNestedValue -InputObject $result.Data -Name 'attachmentUpdate.attachment'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'attachmentUpdate.success') -or $null -eq $updated) {
                $message = Format-LinearFailureMessage -Message "Linear did not update $($target.Name)." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.AttachmentUpdateFailed' -Category WriteError -TargetObject $target.Id))
                continue
            }
            if ($PassThru) {
                ConvertTo-LinearAttachment -InputObject $updated
            }
        }
    }
}
