function Add-LinearAttachment {
    <#
    .SYNOPSIS
        Uploads files to a Linear issue, or links a URL to it.

    .DESCRIPTION
        With -Path, uploads each file to Linear and attaches it to the issue, where it is listed
        in the issue's sidebar. Uploads are private: only members of the workspace can open them.
        With -Public, images (PNG, JPEG, GIF, WebP, BMP, TIFF) are uploaded to a public URL that
        anyone with the link can open without signing in; a warning says so.

        With -Url, links a URL to the issue. When the workspace has a matching integration (for
        example GitHub, Slack or Zendesk), Linear creates a rich attachment for it.

        With -Url -NoRichLink, creates the attachment with exactly the title, subtitle and
        metadata you give, in one request, without involving integrations. The URL identifies the
        attachment: adding the same URL to the same issue again updates that attachment instead
        of adding another one, so automation can run the same command every time it syncs.

        To show an image inside a comment rather than in the sidebar, use
        Add-LinearComment -Attachment instead.

        The issue is checked before anything is uploaded, so a missing issue writes a
        non-terminating error and leaves no stray upload behind. With -WhatIf nothing is sent.

    .PARAMETER Issue
        The issue identifier (ENG-123), UUID or URL. Binds from the Identifier property of piped
        PSLinear.Issue objects.

    .PARAMETER Path
        One or more files to upload. Wildcards are supported.

    .PARAMETER Url
        A URL to link to the issue.

    .PARAMETER Title
        The attachment title. Defaults to the file name, for -Url to a title Linear picks, and
        for -Url -NoRichLink to the URL. Only one file can be given a title.

    .PARAMETER Subtitle
        The attachment subtitle, shown under the title.

    .PARAMETER Comment
        Also adds a comment, in Markdown, linked to the attachment.

    .PARAMETER Public
        Uploads images to a public URL instead of a private one.

    .PARAMETER NoRichLink
        With -Url, creates the attachment in one request with the title, subtitle and metadata
        given, instead of letting the workspace's integrations turn the link into a rich
        attachment. A later call with the same URL and issue updates that attachment: it sets
        the title (the URL when -Title is left out), and the subtitle and metadata when they are
        given; -Metadata then replaces all of the metadata. To change some metadata values and
        keep the others, use Set-LinearAttachment -AddMetadata.

    .PARAMETER Metadata
        Your own data to store on the attachment, as a hashtable of string, number and boolean
        values, for example @{ build = '1.4.2'; runId = 8812; nightly = $true }. For -Url the
        link is created first and the subtitle and metadata set right after, so integrations
        still get their rich links; your metadata then replaces whatever the integration stored
        on the link. With -NoRichLink everything is sent in one request.

    .EXAMPLE
        Add-LinearAttachment ENG-123 ./screenshot.png

        Uploads a screenshot and attaches it to an issue.

    .EXAMPLE
        Add-LinearAttachment -Issue ENG-123 -Path ./logs/*.log -Comment 'Logs from the failed run.'

        Attaches every log file and adds a comment about them.

    .EXAMPLE
        Add-LinearAttachment -Issue ENG-123 -Url https://github.com/acme/app/pull/42 -Title 'Fix PR'

        Links a pull request to an issue.

    .EXAMPLE
        Add-LinearAttachment ENG-123 -Url 'https://monitor.example/alerts/42' -Title 'Alert 42' -Subtitle 'Firing' -Metadata @{ alertId = 42; managed = $true } -NoRichLink

        Creates an attachment that a sync job owns, or updates it when the issue already has an
        attachment with this URL.

    .EXAMPLE
        Add-LinearAttachment ENG-123 ./report.html -Metadata @{ pipeline = 'nightly'; failures = 3 }

        Attaches a test report with metadata that scripts can read back from Get-LinearAttachment.

    .EXAMPLE
        Get-LinearIssue ENG-123 | Add-LinearAttachment -Path ./spec.pdf -Subtitle 'Version 2' -WhatIf

        Shows what would be uploaded, without sending anything.

    .INPUTS
        PSLinear.Issue

    .OUTPUTS
        PSLinear.Attachment

    .LINK
        Get-LinearAttachment

    .LINK
        Add-LinearComment
    #>
    [CmdletBinding(DefaultParameterSetName = 'File', SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PSLinear.Attachment')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('Identifier')]
        [ValidateNotNullOrEmpty()]
        [string] $Issue,

        [Parameter(Mandatory, Position = 1, ParameterSetName = 'File')]
        [SupportsWildcards()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path,

        [Parameter(Mandatory, ParameterSetName = 'Url')]
        [ValidateNotNullOrEmpty()]
        [string] $Url,

        [ValidateNotNullOrEmpty()]
        [string] $Title,

        [ValidateNotNullOrEmpty()]
        [string] $Subtitle,

        [Parameter(ParameterSetName = 'File')]
        [ValidateNotNullOrEmpty()]
        [string] $Comment,

        [Parameter(ParameterSetName = 'File')]
        [switch] $Public,

        [Parameter(ParameterSetName = 'Url')]
        [switch] $NoRichLink,

        [ValidateNotNull()]
        [System.Collections.IDictionary] $Metadata
    )

    begin {
        try {
            $metadataInput = if ($PSBoundParameters.ContainsKey('Metadata')) { ConvertTo-LinearAttachmentMetadataInput -Metadata $Metadata } else { $null }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }

    process {
        $issueName = ConvertTo-LinearIssueIdentifier -Value $Issue

        if ($PSCmdlet.ParameterSetName -eq 'Url' -and $NoRichLink) {
            if (-not $PSCmdlet.ShouldProcess($issueName, "Create or update the attachment for '$Url'")) {
                return
            }
            # attachmentCreate takes everything in one request, and updates the issue's attachment
            # with the same URL instead of adding another one.
            $attachmentInput = @{
                issueId = $issueName
                url     = $Url
                title   = if ($Title) { $Title } else { $Url }
            }
            if ($Subtitle) { $attachmentInput['subtitle'] = $Subtitle }
            if ($null -ne $metadataInput) { $attachmentInput['metadata'] = $metadataInput }
            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateAttachment') -Variables @{ input = $attachmentInput } -IncludeErrors
            $attachment = Get-LinearNestedValue -InputObject $result.Data -Name 'attachmentCreate.attachment'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'attachmentCreate.success') -or $null -eq $attachment) {
                $message = Format-LinearFailureMessage -Message "Linear did not attach '$Url' to $issueName." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.AttachmentCreateFailed' -Category WriteError -TargetObject $issueName))
                return
            }
            ConvertTo-LinearAttachment -InputObject $attachment
            return
        }

        if ($PSCmdlet.ParameterSetName -eq 'Url') {
            if (-not $PSCmdlet.ShouldProcess($issueName, "Attach link '$Url'")) {
                return
            }
            $variables = @{ issueId = $issueName; url = $Url }
            if ($Title) { $variables['title'] = $Title }
            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'LinkAttachmentUrl') -Variables $variables -IncludeErrors
            $attachment = Get-LinearNestedValue -InputObject $result.Data -Name 'attachmentLinkURL.attachment'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'attachmentLinkURL.success') -or $null -eq $attachment) {
                $message = Format-LinearFailureMessage -Message "Linear did not link '$Url' to $issueName." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.AttachmentCreateFailed' -Category WriteError -TargetObject $issueName))
                return
            }
            if ($null -ne $metadataInput -or $Subtitle) {
                # attachmentLinkURL takes no subtitle or metadata, so set them on the new link.
                $updateInput = @{ title = $attachment.title }
                if ($Subtitle) { $updateInput['subtitle'] = $Subtitle }
                if ($null -ne $metadataInput) { $updateInput['metadata'] = $metadataInput }
                $update = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'UpdateAttachment') `
                    -Variables @{ id = $attachment.id; input = $updateInput } -IncludeErrors
                $updated = Get-LinearNestedValue -InputObject $update.Data -Name 'attachmentUpdate.attachment'
                if (-not (Get-LinearNestedValue -InputObject $update.Data -Name 'attachmentUpdate.success') -or $null -eq $updated) {
                    $missing = if ($Subtitle -and $null -ne $metadataInput) { 'subtitle and metadata' } elseif ($Subtitle) { 'subtitle' } else { 'metadata' }
                    $message = Format-LinearFailureMessage -Message "Linked '$Url' to $issueName, but Linear did not store the $missing." -Errors $update.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.AttachmentUpdateFailed' -Category WriteError -TargetObject $attachment.id))
                }
                else {
                    $attachment = $updated
                }
            }
            ConvertTo-LinearAttachment -InputObject $attachment
            return
        }

        try {
            $files = @(Resolve-LinearUploadFile -Path $Path)
            if ($Title -and $files.Count -gt 1) {
                throw (New-LinearErrorRecord -Message "-Title names one attachment, but -Path matched $($files.Count) files. Leave -Title out to use the file names." `
                        -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument)
            }
            if ($Public) {
                foreach ($file in $files) {
                    $contentType = Get-LinearContentType -Path $file.Name
                    if (-not (Test-LinearPublicImage -ContentType $contentType)) {
                        throw (New-LinearErrorRecord -Message "'$($file.Name)' is $contentType; only PNG, JPEG, GIF, WebP, BMP and TIFF images can be uploaded to a public URL." `
                                -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument -TargetObject $file.FullName)
                    }
                }
            }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $issueId = $null
        foreach ($file in $files) {
            $visibility = if ($Public) { 'public' } else { 'private' }
            if (-not $PSCmdlet.ShouldProcess($issueName, "Upload '$($file.Name)' ($(Format-LinearFileSize -Bytes $file.Length), $visibility) and attach it")) {
                continue
            }

            if ($null -eq $issueId) {
                $lookup = Get-LinearIssueReference -Id $issueName
                if ($null -eq $lookup.Issue) {
                    $message = Format-LinearFailureMessage -Message "Issue '$issueName' was not found." -Errors $lookup.Errors
                    $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.IssueNotFound' -Category ObjectNotFound -TargetObject $issueName))
                    return
                }
                $issueId = $lookup.Issue.id
            }

            if ($Public) {
                Write-Warning "'$($file.Name)' is uploaded to a public URL that anyone with the link can open without signing in."
            }
            try {
                $upload = Invoke-LinearFileUpload -File $file -Public:$Public
            }
            catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }

            $attachmentInput = @{
                issueId = $issueId
                title   = if ($Title) { $Title } else { $file.Name }
                url     = $upload.AssetUrl
            }
            if ($Subtitle) { $attachmentInput['subtitle'] = $Subtitle }
            if ($Comment) { $attachmentInput['commentBody'] = $Comment }
            if ($null -ne $metadataInput) { $attachmentInput['metadata'] = $metadataInput }

            $result = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'CreateAttachment') -Variables @{ input = $attachmentInput } -IncludeErrors
            $attachment = Get-LinearNestedValue -InputObject $result.Data -Name 'attachmentCreate.attachment'
            if (-not (Get-LinearNestedValue -InputObject $result.Data -Name 'attachmentCreate.success') -or $null -eq $attachment) {
                $message = Format-LinearFailureMessage -Message "Linear did not attach '$($file.Name)' to $issueName." -Errors $result.Errors
                $PSCmdlet.WriteError((New-LinearErrorRecord -Message $message -ErrorId 'PSLinear.AttachmentCreateFailed' -Category WriteError -TargetObject $file.FullName))
                continue
            }
            ConvertTo-LinearAttachment -InputObject $attachment
        }
    }
}
