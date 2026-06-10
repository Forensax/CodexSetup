[CmdletBinding()]
param(
    [string]$ProductId = '9PLM9XGG6VKS',
    [string]$PackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0',
    [ValidateSet('Retail', 'RP', 'WIF', 'WIS', 'Fast', 'Slow')]
    [string]$Ring = 'Retail',
    [string]$Lang = 'en-US',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-RgAdguardRequest {
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Value
    )

    $body = @{
        type = $Type
        url  = $Value
        ring = $Ring
        lang = $Lang
    }

    Invoke-WebRequest `
        -Uri 'https://store.rg-adguard.net/api/GetFiles' `
        -Method Post `
        -Body $body `
        -ContentType 'application/x-www-form-urlencoded' `
        -Headers @{
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) CodexInstallerBuilder/1.0'
            'Referer'    = 'https://store.rg-adguard.net/'
        } `
        -UseBasicParsing `
        -TimeoutSec 60
}

function Select-CodexMsixPackage {
    param([Parameter(Mandatory)][string]$Html)

    $decoded = [System.Net.WebUtility]::HtmlDecode($Html)

    $anchorMatches = [regex]::Matches(
        $decoded,
        '<a\s+[^>]*href="(?<url>https?://[^"]+)"[^>]*>\s*(?<name>OpenAI\.Codex_[^<]+_x64__2p2nqsd0c76g0\.Msix)\s*</a>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $candidates = foreach ($match in $anchorMatches) {
        $url = $match.Groups['url'].Value
        $fileName = [System.Net.WebUtility]::HtmlDecode($match.Groups['name'].Value)
        $versionMatch = [regex]::Match($fileName, 'OpenAI\.Codex_(?<version>\d+(?:\.\d+){3})_x64__2p2nqsd0c76g0\.Msix', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($versionMatch.Success) {
            [PSCustomObject]@{
                Url     = $url
                Version = [version]$versionMatch.Groups['version'].Value
                FileName = $fileName
            }
        }
    }

    if ($null -eq $candidates -or @($candidates).Count -eq 0) {
        $urlMatches = [regex]::Matches(
            $decoded,
            'https?://[^\s"''<>]+OpenAI\.Codex_[^\s"''<>]+_x64__2p2nqsd0c76g0\.Msix(?:\?[^\s"''<>]*)?',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        $candidates = foreach ($match in $urlMatches) {
            $url = $match.Value
            $fileName = [System.IO.Path]::GetFileName(([System.Uri]$url).AbsolutePath)
            $unescapedName = [System.Uri]::UnescapeDataString($fileName)
            $versionMatch = [regex]::Match($unescapedName, 'OpenAI\.Codex_(?<version>\d+(?:\.\d+){3})_x64__2p2nqsd0c76g0\.Msix', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($versionMatch.Success) {
                [PSCustomObject]@{
                    Url     = $url
                    Version = [version]$versionMatch.Groups['version'].Value
                    FileName = $unescapedName
                }
            }
        }
    }

    if ($null -eq $candidates -or @($candidates).Count -eq 0) {
        $fileMatches = [regex]::Matches(
            $decoded,
            'OpenAI\.Codex_(?<version>\d+(?:\.\d+){3})_x64__2p2nqsd0c76g0\.Msix',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($fileMatches.Count -gt 0) {
            $available = ($fileMatches | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ', '
            throw "Found Codex MSIX filenames but could not find their download hrefs: $available"
        }
    }

    $selected = $candidates | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $selected) {
        return $null
    }
    return [PSCustomObject]@{
        Url      = [string]$selected.Url
        Version  = [string]$selected.Version
        FileName = [string]$selected.FileName
    }
}

function Select-CodexMsixUrl {
    param([Parameter(Mandatory)][string]$Html)

    $package = Select-CodexMsixPackage -Html $Html
    if ($null -eq $package) {
        return $null
    }
    return $package.Url
}

$attempts = @(
    @{ Type = 'ProductId'; Value = $ProductId },
    @{ Type = 'PackageFamilyName'; Value = $PackageFamilyName }
)

$errors = New-Object System.Collections.Generic.List[string]
foreach ($attempt in $attempts) {
    try {
        $response = Invoke-RgAdguardRequest -Type $attempt.Type -Value $attempt.Value
        $package = Select-CodexMsixPackage -Html $response.Content
        if ($null -ne $package -and -not [string]::IsNullOrWhiteSpace($package.Url)) {
            if ($Json) {
                $package | ConvertTo-Json -Compress
            } else {
                Write-Output $package.Url
            }
            exit 0
        }
        $errors.Add("$($attempt.Type) returned no matching OpenAI.Codex x64 MSIX link.")
    } catch {
        $errors.Add("$($attempt.Type) failed: $($_.Exception.Message)")
    }
}

$message = @(
    'Could not resolve the Codex MSIX URL automatically from store.rg-adguard.net.'
    'This endpoint is third-party and may reject automation or change response shape.'
    'Retry the GitHub workflow with the msix_url input set to a direct OpenAI.Codex x64 Retail MSIX URL.'
    'Attempt details:'
    ($errors | ForEach-Object { "- $_" })
) -join [Environment]::NewLine

throw $message
