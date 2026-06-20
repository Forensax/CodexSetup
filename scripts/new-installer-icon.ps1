[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AssetsDir,

    [Parameter(Mandatory)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PngDimension {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $signature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
    if ($Bytes.Length -lt 24) {
        throw 'PNG file is too small to contain an IHDR chunk.'
    }
    for ($index = 0; $index -lt $signature.Length; $index++) {
        if ($Bytes[$index] -ne $signature[$index]) {
            throw 'File does not have a valid PNG signature.'
        }
    }

    $width = [uint32](
        ([uint32]$Bytes[16] -shl 24) -bor
        ([uint32]$Bytes[17] -shl 16) -bor
        ([uint32]$Bytes[18] -shl 8) -bor
        [uint32]$Bytes[19]
    )
    $height = [uint32](
        ([uint32]$Bytes[20] -shl 24) -bor
        ([uint32]$Bytes[21] -shl 16) -bor
        ([uint32]$Bytes[22] -shl 8) -bor
        [uint32]$Bytes[23]
    )

    [PSCustomObject]@{ Width = $width; Height = $height }
}

$resolvedAssetsDir = (Resolve-Path -LiteralPath $AssetsDir).ProviderPath
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
$preferredFiles = @(
    Get-ChildItem -LiteralPath $resolvedAssetsDir -File -Filter '*.png' |
        Where-Object {
            $_.Name -eq 'icon.png' -or
            $_.Name -match '^Square44x44Logo\.targetsize-\d+_altform-unplated\.png$'
        }
)

if ($preferredFiles.Count -eq 0) {
    $preferredFiles = @(
        Get-ChildItem -LiteralPath $resolvedAssetsDir -File -Filter '*.png' |
            Where-Object { $_.Name -match '^Square(44x44|150x150)Logo(?:\.scale-\d+)?\.png$' }
    )
}

$imagesBySize = @{}
foreach ($file in $preferredFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $dimension = Get-PngDimension -Bytes $bytes
    if ($dimension.Width -ne $dimension.Height -or $dimension.Width -lt 1 -or $dimension.Width -gt 256) {
        continue
    }

    $size = [int]$dimension.Width
    $isManifestIcon = $file.Name -eq 'icon.png'
    if (-not $imagesBySize.ContainsKey($size) -or $isManifestIcon) {
        $imagesBySize[$size] = [PSCustomObject]@{
            Size = $size
            Bytes = $bytes
            Source = $file.FullName
        }
    }
}

$images = @($imagesBySize.Values | Sort-Object Size)
if ($images.Count -eq 0) {
    throw "No suitable square PNG app icons up to 256px were found in: $resolvedAssetsDir"
}

$outputDir = Split-Path -Parent $outputFullPath
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$stream = [System.IO.File]::Create($outputFullPath)
try {
    $writer = [System.IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$images.Count)

        $imageOffset = 6 + (16 * $images.Count)
        foreach ($image in $images) {
            $dimensionByte = if ($image.Size -eq 256) { 0 } else { $image.Size }
            $writer.Write([byte]$dimensionByte)
            $writer.Write([byte]$dimensionByte)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$image.Bytes.Length)
            $writer.Write([uint32]$imageOffset)
            $imageOffset += $image.Bytes.Length
        }

        foreach ($image in $images) {
            $writer.Write($image.Bytes)
        }
    } finally {
        $writer.Dispose()
    }
} finally {
    $stream.Dispose()
}

[PSCustomObject]@{
    OutputPath = $outputFullPath
    ImageCount = $images.Count
    Sizes = @($images | ForEach-Object Size)
    Sources = @($images | ForEach-Object Source)
}
