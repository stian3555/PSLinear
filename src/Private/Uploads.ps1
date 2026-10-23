function Get-LinearContentType {
    <#
    .SYNOPSIS
        Returns the MIME type for a file name, from its extension. Unknown types are application/octet-stream.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $extension = [System.IO.Path]::GetExtension($Path).TrimStart('.').ToLowerInvariant()
    switch ($extension) {
        'png' { 'image/png' }
        { $_ -in 'jpg', 'jpeg' } { 'image/jpeg' }
        'gif' { 'image/gif' }
        'webp' { 'image/webp' }
        'svg' { 'image/svg+xml' }
        'ico' { 'image/x-icon' }
        'bmp' { 'image/bmp' }
        { $_ -in 'tif', 'tiff' } { 'image/tiff' }
        'pdf' { 'application/pdf' }
        'doc' { 'application/msword' }
        'docx' { 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }
        'xls' { 'application/vnd.ms-excel' }
        'xlsx' { 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }
        'ppt' { 'application/vnd.ms-powerpoint' }
        'pptx' { 'application/vnd.openxmlformats-officedocument.presentationml.presentation' }
        { $_ -in 'txt', 'log' } { 'text/plain' }
        { $_ -in 'md', 'markdown' } { 'text/markdown' }
        'csv' { 'text/csv' }
        'tsv' { 'text/tab-separated-values' }
        { $_ -in 'htm', 'html' } { 'text/html' }
        'css' { 'text/css' }
        'xml' { 'text/xml' }
        { $_ -in 'js', 'mjs', 'jsx' } { 'text/javascript' }
        { $_ -in 'ts', 'tsx' } { 'text/typescript' }
        'json' { 'application/json' }
        { $_ -in 'yml', 'yaml' } { 'text/yaml' }
        'toml' { 'text/toml' }
        { $_ -in 'sh', 'bash' } { 'text/x-shellscript' }
        { $_ -in 'ps1', 'psm1', 'psd1' } { 'text/plain' }
        'py' { 'text/x-python' }
        'zip' { 'application/zip' }
        'tar' { 'application/x-tar' }
        'gz' { 'application/gzip' }
        '7z' { 'application/x-7z-compressed' }
        'mp3' { 'audio/mpeg' }
        'wav' { 'audio/wav' }
        'ogg' { 'audio/ogg' }
        'm4a' { 'audio/mp4' }
        'mp4' { 'video/mp4' }
        'webm' { 'video/webm' }
        'mov' { 'video/quicktime' }
        'avi' { 'video/x-msvideo' }
        default { 'application/octet-stream' }
    }
}

function Resolve-LinearUploadFile {
    <#
    .SYNOPSIS
        Expands -Path values (wildcards allowed) to the files to upload, checking that each exists and is a file.
    .NOTES
        Sends no request, so it is safe before ShouldProcess. Throws an ErrorRecord
        (PSLinear.FileNotFound) that callers rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Path
    )

    foreach ($value in $Path) {
        # A path that exists as written is used as is, so file names with [ ] work; anything
        # else is expanded as a wildcard pattern.
        $files = @(
            if (Test-Path -LiteralPath $value -PathType Leaf) {
                Get-Item -LiteralPath $value -Force
            }
            else {
                Resolve-Path -Path $value -ErrorAction SilentlyContinue |
                    ForEach-Object { Get-Item -LiteralPath $_.ProviderPath -Force } |
                    Where-Object { $_ -is [System.IO.FileInfo] }
            }
        )
        if ($files.Count -eq 0) {
            throw (New-LinearErrorRecord -Message "File '$value' was not found." -ErrorId 'PSLinear.FileNotFound' -Category ObjectNotFound -TargetObject $value)
        }
        foreach ($file in $files) { $file }
    }
}

function Test-LinearPublicImage {
    <#
    .SYNOPSIS
        Returns $true for the raster image types Linear can serve from a public URL.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $ContentType
    )

    $ContentType -in 'image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/bmp', 'image/tiff'
}

function Invoke-LinearFileUpload {
    <#
    .SYNOPSIS
        Uploads a local file to Linear's storage and returns where it ended up.
    .DESCRIPTION
        Asks Linear for a signed upload URL (fileUpload), then PUTs the file there with the
        headers Linear returns. Network failures, HTTP 429 and 5xx are retried with backoff, like
        Invoke-LinearRequest. Uploads are private (readable by workspace members) unless -Public,
        which only images support.

        Returns [pscustomobject]@{ FileName; ContentType; Size; AssetUrl; Public; Markdown }, where
        Markdown embeds the file in a comment: images as ![name](url), other files as [name](url).
    .NOTES
        Throws an ErrorRecord (PSLinear.UploadFailed or PSLinear.InvalidArgument) that callers
        rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo] $File,

        [switch] $Public
    )

    $contentType = Get-LinearContentType -Path $File.Name
    if ($Public -and -not (Test-LinearPublicImage -ContentType $contentType)) {
        throw (New-LinearErrorRecord -Message "'$($File.Name)' is $contentType; only PNG, JPEG, GIF, WebP, BMP and TIFF images can be uploaded to a public URL." `
                -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument -TargetObject $File.FullName)
    }
    if ($File.Length -gt [int]::MaxValue) {
        throw (New-LinearErrorRecord -Message "'$($File.Name)' is too large to upload." -ErrorId 'PSLinear.UploadFailed' -Category LimitsExceeded -TargetObject $File.FullName)
    }

    $variables = @{
        contentType = $contentType
        filename    = $File.Name
        size        = [int]$File.Length
        makePublic  = [bool]$Public
    }
    $data = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'RequestFileUpload') -Variables $variables
    $target = Get-LinearNestedValue -InputObject $data -Name 'fileUpload.uploadFile'
    if (-not (Get-LinearNestedValue -InputObject $data -Name 'fileUpload.success') -or $null -eq $target) {
        throw (New-LinearErrorRecord -Message "Linear did not provide an upload URL for '$($File.Name)'." `
                -ErrorId 'PSLinear.UploadFailed' -Category WriteError -TargetObject $File.FullName)
    }

    # Linear's signed headers must be sent as given. A content-type among them replaces ours.
    $uploadContentType = $contentType
    $headers = @{}
    foreach ($header in @(Get-LinearNestedValue -InputObject $target -Name 'headers')) {
        if ($null -eq $header) { continue }
        $value = ([string]$header.value).Trim()
        if ($header.key -eq 'Content-Type') { $uploadContentType = $value } else { $headers[$header.key] = $value }
    }

    $maxRetries = (Get-LinearContext).MaxRetries
    for ($attempt = 1; ; $attempt++) {
        $failure = $null
        try {
            $statusCode = Send-LinearFileUpload -Uri $target.uploadUrl -Path $File.FullName -ContentType $uploadContentType -Headers $headers
        }
        catch {
            $statusCode = 0
            $failure = $_.Exception.Message
        }
        if ($statusCode -ge 200 -and $statusCode -lt 300) { break }

        $isTransient = $statusCode -eq 0 -or $statusCode -eq 429 -or $statusCode -ge 500
        if ($isTransient -and $attempt -le $maxRetries) {
            $delay = Get-LinearRetryDelay -Attempt $attempt
            Write-Verbose "Uploading '$($File.Name)' failed ($(if ($failure) { $failure } else { "HTTP $statusCode" })). Retrying in $delay ms (retry $attempt of $maxRetries)."
            Start-Sleep -Milliseconds $delay
            continue
        }
        $reason = if ($failure) { $failure } else { "the storage service returned HTTP $statusCode" }
        throw (New-LinearErrorRecord -Message "Could not upload '$($File.Name)': $reason." -ErrorId 'PSLinear.UploadFailed' -Category WriteError -TargetObject $File.FullName)
    }

    $linkText = $File.Name -replace '([\[\]\\])', '\$1'
    $markdown = if ($contentType.StartsWith('image/')) { "![$linkText]($($target.assetUrl))" } else { "[$linkText]($($target.assetUrl))" }
    [pscustomobject]@{
        FileName    = $File.Name
        ContentType = $contentType
        Size        = $File.Length
        AssetUrl    = $target.assetUrl
        Public      = [bool]$Public
        Markdown    = $markdown
    }
}

function ConvertTo-LinearAttachmentMetadataInput {
    <#
    .SYNOPSIS
        Checks attachment metadata given as a hashtable and returns it for the API.
    .DESCRIPTION
        Metadata is an object of string, number and boolean values. Keys become strings; a value
        of any other type (a date, a nested object, a list or null) is refused before anything is
        sent.
    .NOTES
        Throws an ErrorRecord (PSLinear.InvalidArgument) that callers rethrow with $PSCmdlet.ThrowTerminatingError.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary] $Metadata
    )

    $numberTypes = [byte], [sbyte], [int16], [uint16], [int], [uint32], [long], [uint64], [single], [double], [decimal]
    $result = @{}
    foreach ($entry in $Metadata.GetEnumerator()) {
        $value = $entry.Value
        $isAllowed = $value -is [string] -or $value -is [bool] -or $null -ne ($numberTypes | Where-Object { $value -is $_ } | Select-Object -First 1)
        if (-not $isAllowed) {
            $typeName = if ($null -eq $value) { 'null' } else { $value.GetType().Name }
            throw (New-LinearErrorRecord -Message "Metadata value '$($entry.Key)' is $typeName; metadata values can be strings, numbers and booleans." `
                    -ErrorId 'PSLinear.InvalidArgument' -Category InvalidArgument -TargetObject $entry.Key)
        }
        $result[[string]$entry.Key] = $value
    }
    $result
}

function Format-LinearFileSize {
    <#
    .SYNOPSIS
        Formats a byte count for messages: 512 B, 12 KB, 3.4 MB.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [long] $Bytes
    )

    $culture = [cultureinfo]::InvariantCulture
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return ([math]::Round($Bytes / 1KB)).ToString($culture) + ' KB' }
    ([math]::Round($Bytes / 1MB, 1)).ToString($culture) + ' MB'
}
