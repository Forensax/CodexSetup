[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MsixPath,

    [string]$OutDir = 'dist',

    [string]$Version,

    [switch]$Unsigned
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$prepareScript = Join-Path $PSScriptRoot 'prepare-payload.ps1'
$nsisScript = Join-Path $RepoRoot 'installer/Codex.nsi'

function Get-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Find-MakeNsis {
    $command = Get-Command makensis.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        $command = Get-Command makensis -ErrorAction SilentlyContinue
    }
    if ($null -ne $command) {
        return $command.Source
    }

    $knownPaths = @(
        "${env:ProgramFiles(x86)}\NSIS\makensis.exe",
        "${env:ProgramFiles}\NSIS\makensis.exe"
    )
    foreach ($path in $knownPaths) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }

    throw 'makensis.exe was not found. Install NSIS, or run the GitHub Actions workflow which installs NSIS before building.'
}

if (-not (Test-Path -LiteralPath $prepareScript)) {
    throw "Missing prepare script: $prepareScript"
}
if (-not (Test-Path -LiteralPath $nsisScript)) {
    throw "Missing NSIS script: $nsisScript"
}

$resolvedMsix = (Resolve-Path -LiteralPath $MsixPath).ProviderPath
$outFullPath = Get-FullPath $OutDir
$makensis = Find-MakeNsis

if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    $buildRoot = Join-Path $env:RUNNER_TEMP 'codex-installer-build'
} else {
    $buildRoot = Join-Path $RepoRoot '.build'
}
$payloadDir = Join-Path $buildRoot 'payload'
$metadataPath = Join-Path $buildRoot 'metadata.json'

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
New-Item -ItemType Directory -Path $outFullPath -Force | Out-Null

$metadata = & $prepareScript -MsixPath $resolvedMsix -OutputDir $payloadDir -MetadataPath $metadataPath

if (-not [string]::IsNullOrWhiteSpace($Version) -and $metadata.Version -ne $Version) {
    throw "Expected Codex version '$Version' but MSIX manifest contains '$($metadata.Version)'."
}

$effectiveVersion = $metadata.Version
$installerPath = Join-Path $outFullPath "CodexSetup-x64-$effectiveVersion.exe"
$portablePath = Join-Path $outFullPath "CodexPortable-x64-$effectiveVersion.zip"
$releaseNotesPath = Join-Path $outFullPath 'release-notes.md'
$checksumsPath = Join-Path $outFullPath 'checksums.txt'

if (Test-Path -LiteralPath $installerPath) {
    Remove-Item -LiteralPath $installerPath -Force
}
if (Test-Path -LiteralPath $portablePath) {
    Remove-Item -LiteralPath $portablePath -Force
}

$makensisArgs = @(
    '/V3',
    '/WX',
    "/DAPP_VERSION=$effectiveVersion",
    "/DPAYLOAD_DIR=$payloadDir",
    "/DOUTPUT_EXE=$installerPath",
    $nsisScript
)

& $makensis @makensisArgs
if ($LASTEXITCODE -ne 0) {
    throw "makensis failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $installerPath)) {
    throw "NSIS completed but installer was not created: $installerPath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $payloadDir,
    $portablePath,
    [System.IO.Compression.CompressionLevel]::Fastest,
    $false
)
if (-not (Test-Path -LiteralPath $portablePath)) {
    throw "Portable ZIP was not created: $portablePath"
}

$installerHash = Get-FileHash -Algorithm SHA256 -LiteralPath $installerPath
$portableHash = Get-FileHash -Algorithm SHA256 -LiteralPath $portablePath
$msixHash = Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedMsix

@(
    "$($installerHash.Hash)  $(Split-Path -Leaf $installerPath)"
    "$($portableHash.Hash)  $(Split-Path -Leaf $portablePath)"
    "$($msixHash.Hash)  $(Split-Path -Leaf $resolvedMsix)"
) | Set-Content -LiteralPath $checksumsPath -Encoding UTF8

$signingText = if ($Unsigned) {
    '当前构建未签名，Windows 可能显示 SmartScreen 或未知发布者提示。'
} else {
    '当前构建未配置代码签名步骤。'
}

$packageEmoji = [char]::ConvertFromUtf32(0x1F4E6)
$desktopEmoji = [char]::ConvertFromUtf32(0x1F5A5) + [char]::ConvertFromUtf32(0xFE0F)
$luggageEmoji = [char]::ConvertFromUtf32(0x1F9F3)
$checkEmoji = [char]::ConvertFromUtf32(0x2705)
$warningEmoji = [char]::ConvertFromUtf32(0x26A0) + [char]::ConvertFromUtf32(0xFE0F)

$notes = @"
# Codex Windows $effectiveVersion

## $packageEmoji 下载
- $desktopEmoji 安装版：`CodexSetup-x64-$effectiveVersion.exe`
- $luggageEmoji 便携版：`CodexPortable-x64-$effectiveVersion.zip`

## $checkEmoji 校验
- EXE SHA256: $($installerHash.Hash)
- ZIP SHA256: $($portableHash.Hash)

## $warningEmoji 注意
- 安装版需要管理员权限，会写入开始菜单、卸载项和 `codex:` 协议。
- 便携版解压即用，不写注册表、不创建快捷方式。
- $signingText
"@

$notes | Set-Content -LiteralPath $releaseNotesPath -Encoding UTF8

[PSCustomObject]@{
    Version          = $effectiveVersion
    InstallerPath    = $installerPath
    PortablePath     = $portablePath
    ChecksumsPath    = $checksumsPath
    ReleaseNotesPath = $releaseNotesPath
    MetadataPath     = $metadataPath
    PayloadDir       = $payloadDir
}
