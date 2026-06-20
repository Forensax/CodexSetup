[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MsixPath,

    [Parameter(Mandatory)]
    [string]$OutputDir,

    [string]$IconAssetsDir,

    [string]$MetadataPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-SafeOutputDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = Get-FullPath $Path
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($fullPath) -or $fullPath -eq $root -or $fullPath.Length -lt 8) {
        throw "Refusing to clear unsafe output directory: $fullPath"
    }
    return $fullPath
}

function Get-ZipEntryText {
    param(
        [Parameter(Mandatory)]$Zip,
        [Parameter(Mandatory)][string]$EntryName
    )

    $entry = $Zip.GetEntry($EntryName)
    if ($null -eq $entry) {
        $entry = $Zip.Entries |
            Where-Object { $_.FullName.Replace('\', '/') -eq $EntryName } |
            Select-Object -First 1
    }
    if ($null -eq $entry) {
        throw "MSIX is missing required entry: $EntryName"
    }

    $stream = $entry.Open()
    try {
        $reader = [System.IO.StreamReader]::new($stream)
        try {
            return $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Select-ManifestNode {
    param(
        [Parameter(Mandatory)][xml]$Xml,
        [Parameter(Mandatory)][string]$XPath
    )

    $node = $Xml.SelectSingleNode($XPath)
    if ($null -eq $node) {
        throw "AppxManifest.xml is missing required node: $XPath"
    }
    return $node
}

$resolvedMsix = Resolve-Path -LiteralPath $MsixPath
$resolvedMsixPath = $resolvedMsix.ProviderPath
$outputFullPath = Assert-SafeOutputDirectory $OutputDir
$iconAssetsFullPath = $null

if (-not [string]::IsNullOrWhiteSpace($IconAssetsDir)) {
    $iconAssetsFullPath = Assert-SafeOutputDirectory $IconAssetsDir
}

if (Test-Path -LiteralPath $outputFullPath) {
    Remove-Item -LiteralPath $outputFullPath -Recurse -Force
}
New-Item -ItemType Directory -Path $outputFullPath -Force | Out-Null

if ($null -ne $iconAssetsFullPath) {
    if (Test-Path -LiteralPath $iconAssetsFullPath) {
        Remove-Item -LiteralPath $iconAssetsFullPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $iconAssetsFullPath -Force | Out-Null
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [System.IO.Compression.ZipFile]::OpenRead($resolvedMsixPath)
try {
    $manifestText = Get-ZipEntryText -Zip $zip -EntryName 'AppxManifest.xml'
    [xml]$manifest = $manifestText

    $identity = Select-ManifestNode -Xml $manifest -XPath '/*[local-name()="Package"]/*[local-name()="Identity"]'
    $application = Select-ManifestNode -Xml $manifest -XPath '/*[local-name()="Package"]/*[local-name()="Applications"]/*[local-name()="Application"]'
    $properties = Select-ManifestNode -Xml $manifest -XPath '/*[local-name()="Package"]/*[local-name()="Properties"]'
    $targetFamily = Select-ManifestNode -Xml $manifest -XPath '/*[local-name()="Package"]/*[local-name()="Dependencies"]/*[local-name()="TargetDeviceFamily"]'

    $packageName = [string]$identity.GetAttribute('Name')
    $architecture = [string]$identity.GetAttribute('ProcessorArchitecture')
    $version = [string]$identity.GetAttribute('Version')
    $publisher = [string]$identity.GetAttribute('Publisher')
    $entryPoint = [string]$application.GetAttribute('Executable')

    if ($packageName -ne 'OpenAI.Codex') {
        throw "Unexpected package identity '$packageName'. Expected 'OpenAI.Codex'."
    }
    if ($architecture -ne 'x64') {
        throw "Unexpected package architecture '$architecture'. Expected 'x64'."
    }
    if ($entryPoint -ne 'app/Codex.exe') {
        throw "Unexpected application executable '$entryPoint'. Expected 'app/Codex.exe'."
    }
    $codexEntry = $zip.GetEntry('app/Codex.exe')
    if ($null -eq $codexEntry) {
        $codexEntry = $zip.Entries |
            Where-Object { $_.FullName.Replace('\', '/') -eq 'app/Codex.exe' } |
            Select-Object -First 1
    }
    if ($null -eq $codexEntry) {
        throw "MSIX payload is missing app/Codex.exe."
    }

    foreach ($entry in $zip.Entries) {
        $normalizedEntryName = $entry.FullName.Replace('\', '/')
        if ($normalizedEntryName.EndsWith('/')) {
            continue
        }

        $targetRoot = $null
        $relative = $null
        if ($normalizedEntryName.StartsWith('app/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $targetRoot = $outputFullPath
            $relative = $normalizedEntryName.Substring(4).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        } elseif (
            $null -ne $iconAssetsFullPath -and
            $normalizedEntryName.StartsWith('assets/', [System.StringComparison]::OrdinalIgnoreCase) -and
            $normalizedEntryName.EndsWith('.png', [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            $targetRoot = $iconAssetsFullPath
            $relative = $normalizedEntryName.Substring(7).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        } else {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($relative)) {
            continue
        }

        $targetPath = Get-FullPath (Join-Path $targetRoot $relative)
        $outputPrefix = $targetRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $targetPath.StartsWith($outputPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Blocked unsafe zip entry path: $($entry.FullName)"
        }

        $targetDir = Split-Path -Parent $targetPath
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

        $sourceStream = $entry.Open()
        try {
            $targetStream = [System.IO.File]::Create($targetPath)
            try {
                $sourceStream.CopyTo($targetStream)
            } finally {
                $targetStream.Dispose()
            }
        } finally {
            $sourceStream.Dispose()
        }
    }
} finally {
    $zip.Dispose()
}

$hash = Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedMsixPath
$signature = Get-AuthenticodeSignature -FilePath $resolvedMsixPath

$metadata = [PSCustomObject]@{
    PackageName            = $packageName
    Version                = $version
    Architecture           = $architecture
    Publisher              = $publisher
    EntryPoint             = $entryPoint
    DisplayName            = [string]$properties.DisplayName
    PublisherDisplayName   = [string]$properties.PublisherDisplayName
    MinVersion             = [string]$targetFamily.GetAttribute('MinVersion')
    MaxVersionTested       = [string]$targetFamily.GetAttribute('MaxVersionTested')
    MsixPath               = $resolvedMsixPath
    MsixSha256             = $hash.Hash
    SignatureStatus        = [string]$signature.Status
    SignatureStatusMessage = [string]$signature.StatusMessage
    PayloadDir             = $outputFullPath
    IconAssetsDir          = $iconAssetsFullPath
    GeneratedAtUtc         = [DateTime]::UtcNow.ToString('o')
}

if (-not [string]::IsNullOrWhiteSpace($MetadataPath)) {
    $metadataFullPath = Get-FullPath $MetadataPath
    $metadataDir = Split-Path -Parent $metadataFullPath
    if (-not [string]::IsNullOrWhiteSpace($metadataDir)) {
        New-Item -ItemType Directory -Path $metadataDir -Force | Out-Null
    }
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metadataFullPath -Encoding UTF8
}

$metadata
