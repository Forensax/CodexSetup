Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Failures = New-Object System.Collections.Generic.List[string]

function Join-RepoPath {
    param([Parameter(Mandatory)][string]$Path)
    return (Join-Path $RepoRoot $Path)
}

function Add-Failure {
    param([Parameter(Mandatory)][string]$Message)
    $script:Failures.Add($Message)
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        Add-Failure $Message
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )
    if ($Text -notmatch $Pattern) {
        Add-Failure $Message
    }
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )
    if ($Text -match $Pattern) {
        Add-Failure $Message
    }
}

function New-TestMsix {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PackageName
    )

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'app/resources') -Force | Out-Null

    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities" IgnorableNamespaces="uap rescap">
  <Identity Name="$PackageName" ProcessorArchitecture="x64" Version="26.608.1337.0" Publisher="CN=TEST" />
  <Properties>
    <DisplayName>Codex</DisplayName>
    <PublisherDisplayName>OpenAI</PublisherDisplayName>
    <Logo>assets/icon.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Resources>
    <Resource Language="en-US" />
  </Resources>
  <Applications>
    <Application Id="App" Executable="app/Codex.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="Codex" Description="Codex" Square44x44Logo="assets/Square44x44Logo.png" Square150x150Logo="assets/Square150x150Logo.png" BackgroundColor="#3143FF" />
    </Application>
  </Applications>
</Package>
"@

    Set-Content -LiteralPath (Join-Path $root 'AppxManifest.xml') -Value $manifest -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root 'app/Codex.exe') -Value 'fake binary' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'app/resources/icon.ico') -Value 'fake icon' -Encoding ASCII

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($root, $Path)
    Remove-Item -LiteralPath $root -Recurse -Force
}

function Test-RequiredFilesExist {
    $paths = @(
        'README.md',
        '.gitignore',
        'installer/Codex.nsi',
        'scripts/resolve-msix-url.ps1',
        'scripts/prepare-payload.ps1',
        'scripts/build-installer.ps1',
        'scripts/test-installer-ci.ps1',
        '.github/workflows/release.yml'
    )

    foreach ($path in $paths) {
        Assert-True (Test-Path -LiteralPath (Join-RepoPath $path)) "Missing required file: $path"
    }
}

function Test-ReadmeContent {
    $path = Join-RepoPath 'README.md'
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Failure 'README.md must exist'
        return
    }

    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    Assert-Contains $text '# Codex Windows' 'README must have a project title'
    Assert-Contains $text '[\u4e00-\u9fff]' 'README must contain Chinese text'
    Assert-Contains $text '\u6bcf\u5c0f\u65f6|1\s*\u5c0f\u65f6|\u4e00\u5c0f\u65f6' 'README must document the hourly version check'
    Assert-Contains $text '\u6ca1\u6709\u65b0\u7248\u672c' 'README must document that scheduled runs stop when no new version exists'
    Assert-Contains $text 'zlib' 'README must document the zlib speed/size compression compromise'
    Assert-Contains $text 'Portable|portable' 'README must document the portable build artifact'
    Assert-Contains $text 'CodexPortable-x64-' 'README must name the portable ZIP artifact'
}

function Test-PreparePayloadScript {
    $script = Join-RepoPath 'scripts/prepare-payload.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        Add-Failure 'scripts/prepare-payload.ps1 must exist before payload behavior can be tested'
        return
    }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $msix = Join-Path $temp 'OpenAI.Codex_26.608.1337.0_x64__2p2nqsd0c76g0.Msix'
        $payload = Join-Path $temp 'payload'
        $metadataPath = Join-Path $temp 'metadata.json'
        New-TestMsix -Path $msix -PackageName 'OpenAI.Codex'

        & $script -MsixPath $msix -OutputDir $payload -MetadataPath $metadataPath | Out-Null

        Assert-True (Test-Path -LiteralPath (Join-Path $payload 'Codex.exe')) 'prepare-payload must extract app/Codex.exe to the payload root'
        Assert-True (Test-Path -LiteralPath (Join-Path $payload 'resources/icon.ico')) 'prepare-payload must preserve nested resources under payload root'
        Assert-True (Test-Path -LiteralPath $metadataPath) 'prepare-payload must write metadata JSON'

        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        Assert-True ($metadata.PackageName -eq 'OpenAI.Codex') 'metadata PackageName must be OpenAI.Codex'
        Assert-True ($metadata.Version -eq '26.608.1337.0') 'metadata Version must come from AppxManifest.xml'
        Assert-True ($metadata.Architecture -eq 'x64') 'metadata Architecture must come from AppxManifest.xml'
        Assert-True ($metadata.EntryPoint -eq 'app/Codex.exe') 'metadata EntryPoint must come from AppxManifest.xml'
        Assert-True (-not [string]::IsNullOrWhiteSpace($metadata.MsixSha256)) 'metadata must include the MSIX SHA256'
        Assert-True (-not [string]::IsNullOrWhiteSpace($metadata.SignatureStatus)) 'metadata must include the Authenticode signature status'

        $badMsix = Join-Path $temp 'Wrong.Package_1.0.0.0_x64__test.Msix'
        New-TestMsix -Path $badMsix -PackageName 'Wrong.Package'
        $rejected = $false
        try {
            & $script -MsixPath $badMsix -OutputDir (Join-Path $temp 'bad-payload') -MetadataPath (Join-Path $temp 'bad.json') | Out-Null
        } catch {
            $rejected = $true
        }
        Assert-True $rejected 'prepare-payload must reject packages whose Identity Name is not OpenAI.Codex'
    } finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Recurse -Force
        }
    }
}

function Test-BuildInstallerScript {
    $script = Join-RepoPath 'scripts/build-installer.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        Add-Failure 'scripts/build-installer.ps1 must exist before build behavior can be tested'
        return
    }

    $text = Get-Content -LiteralPath $script -Raw -Encoding UTF8
    Assert-Contains $text 'CodexPortable-x64-\$effectiveVersion\.zip' 'build script must create a versioned portable ZIP path'
    Assert-Contains $text 'CreateFromDirectory\(\s*\$payloadDir,\s*\$portablePath' 'build script must zip the extracted payload directory for portable builds'
    Assert-Contains $text '\$portableHash\s*=\s*Get-FileHash' 'build script must calculate the portable ZIP SHA256'
    Assert-Contains $text '\$portableHash\.Hash\)\s+ \$\(Split-Path -Leaf \$portablePath\)' 'checksums.txt must include the portable ZIP hash'
    Assert-Contains $text 'PortablePath\s*=\s*\$portablePath' 'build script result must expose PortablePath to the workflow'
    Assert-Contains $text 'CodexPortable-x64-' 'release notes must mention the portable ZIP artifact'
    Assert-Contains $text '# Codex Windows \$effectiveVersion' 'release notes must use the concise Codex Windows title'
    Assert-Contains $text 'ConvertFromUtf32\(0x1F4E6\)' 'release notes must define the package emoji by code point'
    Assert-Contains $text 'ConvertFromUtf32\(0x2705\)' 'release notes must define the checksum emoji by code point'
    Assert-Contains $text 'ConvertFromUtf32\(0x26A0\)' 'release notes must define the warning emoji by code point'
    Assert-Contains $text '## \$packageEmoji \u4E0B\u8F7D' 'release notes must include the download emoji section'
    Assert-Contains $text '## \$checkEmoji \u6821\u9A8C' 'release notes must include the checksum emoji section'
    Assert-Contains $text '## \$warningEmoji \u6CE8\u610F' 'release notes must include the warning emoji section'
    Assert-Contains $text '\u5B89\u88C5\u7248' 'release notes must describe the installer in Chinese'
    Assert-Contains $text '\u4FBF\u643A\u7248' 'release notes must describe the portable build in Chinese'
    Assert-Contains $text 'EXE SHA256: \$\(\$installerHash\.Hash\)' 'release notes must include the installer SHA256'
    Assert-Contains $text 'ZIP SHA256: \$\(\$portableHash\.Hash\)' 'release notes must include the portable ZIP SHA256'
    Assert-NotContains $text 'MSIX package identity' 'release notes must omit verbose MSIX metadata'
}

function Test-ResolveMsixUrlParser {
    $script = Join-RepoPath 'scripts/resolve-msix-url.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        Add-Failure 'scripts/resolve-msix-url.ps1 must exist before rg-adguard parser behavior can be tested'
        return
    }

    $scriptText = Get-Content -LiteralPath $script -Raw
    Assert-Contains $scriptText 'function\s+Select-CodexMsixUrl' 'resolve-msix-url must expose Select-CodexMsixUrl for parser testing'
    Assert-Contains $scriptText '\[switch\]\$Json' 'resolve-msix-url must support -Json output for scheduled version checks'
    Assert-Contains $scriptText 'function\s+Select-CodexMsixPackage' 'resolve-msix-url must expose Select-CodexMsixPackage for version-aware parsing'

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $harness = Join-Path $temp 'parser-harness.ps1'
        $moduleText = $scriptText -replace '(?s)\$attempts\s*=\s*@\(.+$', ''
        $fixture = @(
            '<table class="tftable">'
            '  <tr><td><a href="http://dl.delivery.mp.microsoft.com/filestreamingservice/files/blockmap" rel="noreferrer">OpenAI.Codex_26.608.1337.0_x64__2p2nqsd0c76g0.BlockMap</a></td></tr>'
            '  <tr><td><a href="http://dl.delivery.mp.microsoft.com/filestreamingservice/files/old" rel="noreferrer">OpenAI.Codex_26.607.1200.0_x64__2p2nqsd0c76g0.Msix</a></td></tr>'
            '  <tr><td><a href="http://dl.delivery.mp.microsoft.com/filestreamingservice/files/latest" rel="noreferrer">OpenAI.Codex_26.608.1337.0_x64__2p2nqsd0c76g0.Msix</a></td></tr>'
            '  <tr><td><a href="http://dl.delivery.mp.microsoft.com/filestreamingservice/files/arm64" rel="noreferrer">OpenAI.Codex_26.608.1337.0_arm64__2p2nqsd0c76g0.Msix</a></td></tr>'
            '</table>'
        ) -join [Environment]::NewLine
        @(
            $moduleText
            "`$html = @'"
            $fixture
            "'@"
            'Select-CodexMsixUrl -Html $html'
        ) | Set-Content -LiteralPath $harness -Encoding UTF8

        $selected = & powershell -NoProfile -ExecutionPolicy Bypass -File $harness
        Assert-True ($selected -eq 'http://dl.delivery.mp.microsoft.com/filestreamingservice/files/latest') 'resolve-msix-url must select the latest x64 MSIX href when rg-adguard uses filename as anchor text'

        $jsonHarness = Join-Path $temp 'parser-json-harness.ps1'
        @(
            $moduleText
            "`$html = @'"
            $fixture
            "'@"
            'Select-CodexMsixPackage -Html $html | ConvertTo-Json -Compress'
        ) | Set-Content -LiteralPath $jsonHarness -Encoding UTF8

        $package = (& powershell -NoProfile -ExecutionPolicy Bypass -File $jsonHarness) | ConvertFrom-Json
        Assert-True ($package.Url -eq 'http://dl.delivery.mp.microsoft.com/filestreamingservice/files/latest') 'resolve-msix-url JSON package must include the selected URL'
        Assert-True ($package.Version -eq '26.608.1337.0') 'resolve-msix-url JSON package must include the selected version'
        Assert-True ($package.FileName -eq 'OpenAI.Codex_26.608.1337.0_x64__2p2nqsd0c76g0.Msix') 'resolve-msix-url JSON package must include the selected file name'
    } finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Recurse -Force
        }
    }
}

function Test-NsisScriptContent {
    $path = Join-RepoPath 'installer/Codex.nsi'
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Failure 'installer/Codex.nsi must exist before NSIS content can be tested'
        return
    }

    $text = Get-Content -LiteralPath $path -Raw
    Assert-Contains $text '(?m)^\s*RequestExecutionLevel\s+admin\b' 'NSIS installer must require admin elevation'
    Assert-Contains $text ([regex]::Escape('InstallDir "$PROGRAMFILES64\Codex"')) 'NSIS installer must default to %ProgramFiles%\Codex'
    Assert-Contains $text ([regex]::Escape('WriteRegStr HKLM "Software\Classes\codex" "URL Protocol" ""')) 'NSIS installer must register codex: URL protocol'
    Assert-Contains $text 'WriteUninstaller' 'NSIS installer must generate an uninstaller'
    Assert-Contains $text 'CreateShortCut\s+"\$SMPROGRAMS\\Codex\\Codex\.lnk"' 'NSIS installer must create an all-users Start Menu shortcut'
    Assert-Contains $text '!insertmacro\s+MUI_LANGUAGE\s+"SimpChinese"' 'NSIS installer must use Simplified Chinese UI language'
    Assert-Contains $text '(?m)^\s*SetCompressor\s+zlib\s*$' 'NSIS installer must use zlib as the speed/size compression compromise'
    Assert-NotContains $text '(?m)^\s*SetCompressor\s+/SOLID\s+lzma\s*$' 'NSIS installer must not use slow solid LZMA compression'
    Assert-NotContains $text '(?m)^\s*SetCompress\s+off\s*$' 'NSIS installer must not disable compression when using the speed/size compromise'

    foreach ($extension in @('\.csv', '\.tsv', '\.xls', '\.xlsm', '\.xlsx')) {
        Assert-NotContains $text $extension "NSIS installer must not register spreadsheet file association pattern $extension"
    }
}

function Test-CiScriptGuard {
    $path = Join-RepoPath 'scripts/test-installer-ci.ps1'
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Failure 'scripts/test-installer-ci.ps1 must exist before CI install guard can be tested'
        return
    }

    $text = Get-Content -LiteralPath $path -Raw
    Assert-Contains $text '\$env:CI\s+-ne\s+''true''' 'CI installer test script must refuse to run outside CI by default'
    Assert-Contains $text 'Start-Process' 'CI installer test script must install via Start-Process'
    Assert-Contains $text 'UninstallString' 'CI installer test script must verify the uninstall registry entry'
    Assert-Contains $text 'Software\\Classes\\codex' 'CI installer test script must verify codex: protocol registration'

    foreach ($extension in @('\.csv', '\.tsv', '\.xls', '\.xlsm', '\.xlsx')) {
        Assert-Contains $text $extension "CI script must explicitly assert no file association for $extension"
    }
}

function Test-WorkflowContent {
    $path = Join-RepoPath '.github/workflows/release.yml'
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Failure '.github/workflows/release.yml must exist before workflow content can be tested'
        return
    }

    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    Assert-Contains $text 'name:\s*[\u4e00-\u9fff]+ Codex Windows [\u4e00-\u9fff]+' 'release workflow name must be Chinese'
    Assert-Contains $text 'cron:\s*''0 \* \* \* \*''' 'release workflow must check for Codex updates every hour'
    Assert-Contains $text 'workflow_dispatch:' 'release workflow must support manual workflow_dispatch'
    Assert-Contains $text 'msix_url:' 'release workflow must expose an optional msix_url input'
    Assert-Contains $text 'draft:' 'release workflow must expose a draft input'
    Assert-Contains $text 'runs-on:\s+windows-' 'release workflow must run on a Windows runner'
    Assert-Contains $text 'scripts/build-installer\.ps1' 'release workflow must call scripts/build-installer.ps1'
    Assert-Contains $text 'scripts/test-installer-ci\.ps1' 'release workflow must call scripts/test-installer-ci.ps1'
    Assert-Contains $text 'gh\s+@releaseArgs' 'release workflow must publish assets with gh release create arguments'
    Assert-Contains $text 'PORTABLE_PATH=\$\(.*PortablePath' 'release workflow must export the portable ZIP path from the build result'
    Assert-Contains $text '\$\{\{ env\.PORTABLE_PATH \}\}' 'release workflow must upload the portable ZIP as a workflow artifact'
    Assert-Contains $text 'portableAsset\s*=\s*"\$env:PORTABLE_PATH#CodexPortable-x64-\$env:VERSION\.zip"' 'release workflow must publish the portable ZIP as a release asset'
    Assert-NotContains $text 'checksumsAsset\s*=\s*"\$env:CHECKSUMS_PATH#checksums\.txt"' 'release workflow must not publish checksums.txt as a GitHub Release asset'
    Assert-Contains $text 'releases/tags/\$tag' 'release workflow must check existing releases through the GitHub Releases API'
    Assert-Contains $text '\$releaseResponse\.StatusCode\s+-eq\s+200' 'release workflow must treat HTTP 200 as an existing release'
    Assert-Contains $text '\$releaseResponse\.StatusCode\s+-ne\s+404' 'release workflow must treat HTTP 404 as a new release and only fail on other status codes'
    Assert-NotContains $text 'gh\s+release\s+view\s+\$tag' 'release workflow must not use gh release view for expected missing-release checks'
    Assert-Contains $text 'SHOULD_BUILD=false' 'release workflow must stop scheduled runs when no new Codex version is available'
    Assert-Contains $text 'resolve-msix-url\.ps1[^\r\n]+-Json' 'release workflow must use JSON resolver output for automatic version checks'
    Assert-Contains $text '\$makeNsis\s*=\s*Get-Command\s+makensis\.exe' 'release workflow must resolve makensis.exe before verifying NSIS'
    Assert-NotContains $text '(?m)^\s*makensis\s+/VERSION\s*$' 'release workflow must not call bare makensis /VERSION before PATH updates take effect'
}

Test-RequiredFilesExist
Test-ReadmeContent
Test-BuildInstallerScript
Test-PreparePayloadScript
Test-ResolveMsixUrlParser
Test-NsisScriptContent
Test-CiScriptGuard
Test-WorkflowContent

if ($Failures.Count -gt 0) {
    foreach ($failure in $Failures) {
        Write-Error $failure -ErrorAction Continue
    }
    throw "$($Failures.Count) packaging test(s) failed"
}

Write-Host 'All packaging tests passed.'
