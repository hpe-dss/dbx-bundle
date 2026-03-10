[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$DatabricksCliVersion,
    [string]$DbxReleaseVersion = $(if ($env:DBX_RELEASE_VERSION) { $env:DBX_RELEASE_VERSION } else { 'v1.0.1' }),
    [string]$DbxRepo = $(if ($env:DBX_REPO) { $env:DBX_REPO } else { 'hpe-dss/dbx-bundle' }),
    [switch]$UsePyenv,
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This script is supported only on Windows.'
}

function Log([string]$Message) {
    Write-Host "==> $Message"
}

$normalizedTag = $DbxReleaseVersion.Trim()
if (-not $normalizedTag.StartsWith('v')) {
    $normalizedTag = "v$normalizedTag"
}

$assetName = "dbx-$normalizedTag.zip"
$checksumsName = 'SHA256SUMS'
$releaseBaseUrl = "https://github.com/$DbxRepo/releases/download/$normalizedTag"
$archiveUrl = "$releaseBaseUrl/$assetName"
$checksumsUrl = "$releaseBaseUrl/$checksumsName"

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("dbx-bootstrap-" + [Guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $tmpRoot $assetName
$checksumsPath = Join-Path $tmpRoot $checksumsName
$extractDir = Join-Path $tmpRoot 'src'

New-Item -ItemType Directory -Path $tmpRoot, $extractDir -Force | Out-Null

try {
    Log "Downloading $DbxRepo $normalizedTag"
    Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -UseBasicParsing
    Invoke-WebRequest -Uri $checksumsUrl -OutFile $checksumsPath -UseBasicParsing

    Log 'Verifying SHA-256 checksum'
    $expectedLine = Get-Content -LiteralPath $checksumsPath | Where-Object { $_ -match "^\s*[0-9a-fA-F]{64}\s+$([regex]::Escape($assetName))\s*$" } | Select-Object -First 1
    if (-not $expectedLine) {
        throw "Expected checksum for $assetName was not found in $checksumsName."
    }

    $expectedHash = ((($expectedLine.Trim()) -split '\s+')[0]).ToLowerInvariant()
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "Checksum verification failed for $assetName."
    }

    Log 'Extracting package'
    Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force

    $installScriptPath = Join-Path $extractDir "dbx-$normalizedTag/install.ps1"
    if (Test-Path -LiteralPath $installScriptPath -PathType Leaf) {
        $installScript = Get-Item -LiteralPath $installScriptPath
    }
    else {
        $installScript = Get-ChildItem -Path $extractDir -Filter 'install.ps1' -File -Recurse | Select-Object -First 1
    }

    if (-not $installScript) {
        throw 'install.ps1 not found inside downloaded package.'
    }

    Log "Running installer from $normalizedTag"
    $installParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($DatabricksCliVersion)) {
        $installParams['DatabricksCliVersion'] = $DatabricksCliVersion
    }
    if ($UsePyenv) {
        $installParams['UsePyenv'] = $true
    }
    if ($Clean) {
        $installParams['Clean'] = $true
    }

    & $installScript.FullName @installParams
}
finally {
    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force
    }
}
