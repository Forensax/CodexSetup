[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InstallerPath,

    [string]$ExpectedVersion,

    [switch]$AllowLocalInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:CI -ne 'true' -and -not $AllowLocalInstall) {
    throw 'Refusing to run installer verification outside CI. This script performs a real install/uninstall; pass -AllowLocalInstall only when you intentionally want that.'
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Wait-Until {
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][string]$FailureMessage,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) {
            return
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    throw $FailureMessage
}

function Assert-NoSpreadsheetAssociations {
    $extensions = @('.csv', '.tsv', '.xls', '.xlsm', '.xlsx')
    foreach ($extension in $extensions) {
        $openWithList = "HKLM:\Software\Classes\$extension\OpenWithList\Codex.exe"
        $codexShell = "HKLM:\Software\Classes\$extension\shell\OpenWithCodex"

        Assert-True (-not (Test-Path -LiteralPath $openWithList)) "Unexpected Codex OpenWithList registration for $extension"
        Assert-True (-not (Test-Path -LiteralPath $codexShell)) "Unexpected Codex shell registration for $extension"

        $openWithProgids = "HKLM:\Software\Classes\$extension\OpenWithProgids"
        if (Test-Path -LiteralPath $openWithProgids) {
            $item = Get-Item -LiteralPath $openWithProgids
            foreach ($name in $item.GetValueNames()) {
                Assert-True ($name -notmatch 'Codex') "Unexpected Codex OpenWithProgids value '$name' for $extension"
            }
        }
    }
}

$resolvedInstaller = (Resolve-Path -LiteralPath $InstallerPath).ProviderPath
$principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
Assert-True ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'Installer verification requires an elevated Windows runner.'

$installDir = Join-Path $env:ProgramFiles 'Codex'
$codexExe = Join-Path $installDir 'Codex.exe'
$uninstaller = Join-Path $installDir 'Uninstall.exe'
$commonPrograms = [Environment]::GetFolderPath('CommonPrograms')
$startMenuShortcut = Join-Path $commonPrograms 'Codex\Codex.lnk'
$commonDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
$desktopShortcut = Join-Path $commonDesktop 'Codex.lnk'
$uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex'
$protocolKey = 'HKLM:\Software\Classes\codex'
$protocolCommandKey = 'HKLM:\Software\Classes\codex\shell\open\command'

$installed = $false
try {
    $installProcess = Start-Process -FilePath $resolvedInstaller -ArgumentList '/S' -Wait -PassThru
    Assert-True ($installProcess.ExitCode -eq 0) "Silent install failed with exit code $($installProcess.ExitCode)."
    $installed = $true

    Assert-True (Test-Path -LiteralPath $codexExe) "Codex.exe was not installed at $codexExe"
    Assert-True (Test-Path -LiteralPath $startMenuShortcut) "Start Menu shortcut was not created at $startMenuShortcut"
    Assert-True (Test-Path -LiteralPath $desktopShortcut) "Desktop shortcut was not created at $desktopShortcut"
    Assert-True (Test-Path -LiteralPath $uninstallKey) "Uninstall registry key was not created: $uninstallKey"
    Assert-True (Test-Path -LiteralPath $protocolKey) "codex: protocol registry key was not created: $protocolKey"
    Assert-True (Test-Path -LiteralPath $protocolCommandKey) "codex: protocol open command was not created: $protocolCommandKey"

    $uninstallProperties = Get-ItemProperty -LiteralPath $uninstallKey
    Assert-True (-not [string]::IsNullOrWhiteSpace($uninstallProperties.UninstallString)) 'UninstallString is missing from uninstall registry key.'
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion)) {
        Assert-True ($uninstallProperties.DisplayVersion -eq $ExpectedVersion) "DisplayVersion '$($uninstallProperties.DisplayVersion)' did not match expected '$ExpectedVersion'."
    }

    $protocolCommand = (Get-Item -LiteralPath $protocolCommandKey).GetValue('')
    Assert-True ($protocolCommand -like "*$codexExe*") "codex: protocol command does not point to installed Codex.exe: $protocolCommand"

    Assert-NoSpreadsheetAssociations
} finally {
    if ($installed -and (Test-Path -LiteralPath $uninstaller)) {
        $uninstallProcess = Start-Process -FilePath $uninstaller -ArgumentList '/S' -Wait -PassThru
        if ($uninstallProcess.ExitCode -ne 0) {
            throw "Silent uninstall failed with exit code $($uninstallProcess.ExitCode)."
        }

        Wait-Until -Condition { -not (Test-Path -LiteralPath $installDir) } -FailureMessage "Install directory still exists after uninstall: $installDir"
        Wait-Until -Condition { -not (Test-Path -LiteralPath $desktopShortcut) } -FailureMessage "Desktop shortcut still exists after uninstall: $desktopShortcut"
        Wait-Until -Condition { -not (Test-Path -LiteralPath $uninstallKey) } -FailureMessage "Uninstall registry key still exists after uninstall: $uninstallKey"
        Wait-Until -Condition { -not (Test-Path -LiteralPath $protocolKey) } -FailureMessage "codex: protocol registry key still exists after uninstall: $protocolKey"
    }
}

Write-Host 'CI installer install/uninstall verification passed.'
