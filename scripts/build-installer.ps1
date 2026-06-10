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
$releaseNotesPath = Join-Path $outFullPath 'release-notes.md'
$checksumsPath = Join-Path $outFullPath 'checksums.txt'

if (Test-Path -LiteralPath $installerPath) {
    Remove-Item -LiteralPath $installerPath -Force
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

$installerHash = Get-FileHash -Algorithm SHA256 -LiteralPath $installerPath
$msixHash = Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedMsix

@(
    "$($installerHash.Hash)  $(Split-Path -Leaf $installerPath)"
    "$($msixHash.Hash)  $(Split-Path -Leaf $resolvedMsix)"
) | Set-Content -LiteralPath $checksumsPath -Encoding UTF8

$signingText = if ($Unsigned) {
    'This installer is intentionally unsigned for this build. Windows may show SmartScreen or unknown publisher warnings.'
} else {
    'No code signing step was configured by this packaging project.'
}

$notes = @"
# Codex $effectiveVersion Windows Installer

This release repackages the Microsoft Store MSIX payload into a traditional all-machine NSIS installer.

- Install scope: all-machine
- Default install directory: `%ProgramFiles%\Codex`
- Installer signing: unsigned
- MSIX package identity: $($metadata.PackageName)
- MSIX architecture: $($metadata.Architecture)
- MSIX entry point: $($metadata.EntryPoint)
- MSIX Authenticode status: $($metadata.SignatureStatus)
- MSIX SHA256: $($msixHash.Hash)
- Installer SHA256: $($installerHash.Hash)

$signingText

The installer creates a Start Menu shortcut, an uninstall entry, and the `codex:` URL protocol registration. It does not register spreadsheet file associations.
"@

$notes | Set-Content -LiteralPath $releaseNotesPath -Encoding UTF8

[PSCustomObject]@{
    Version          = $effectiveVersion
    InstallerPath    = $installerPath
    ChecksumsPath    = $checksumsPath
    ReleaseNotesPath = $releaseNotesPath
    MetadataPath     = $metadataPath
    PayloadDir       = $payloadDir
}
