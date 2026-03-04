[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Version,
    [string]$InstallBinDir = $(if ($env:INSTALL_BIN_DIR) { $env:INSTALL_BIN_DIR } else { Join-Path $HOME '.local/bin' }),
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This script is supported only on Windows.'
}

$tagsUrl = 'https://github.com/databricks/cli/tags'
$githubTagsApiUrl = 'https://api.github.com/repos/databricks/cli/tags?per_page=100'
$profileBlockStart = '# >>> databricks cli path >>>'
$profileBlockEnd = '# <<< databricks cli path <<<'

function Log([string]$Message) {
    Write-Host "==> $Message"
}

function Fail([string]$Message) {
    throw $Message
}

function Normalize-Version([string]$InputVersion) {
    return $InputVersion.Trim().TrimStart('v')
}

function Parse-SemVer([string]$Value) {
    $normalized = Normalize-Version $Value
    if ($normalized -notmatch '^\d+\.\d+\.\d+$') {
        return $null
    }
    return [version]$normalized
}

function Resolve-LatestVersionFromTagsPage {
    $html = Invoke-WebRequest -Uri $tagsUrl -UseBasicParsing
    $matches = [regex]::Matches($html.Content, 'v(\d+\.\d+\.\d+)')
    foreach ($m in $matches) {
        return $m.Groups[1].Value
    }
    return $null
}

function Resolve-LatestVersionFromApi {
    $versions = Get-SemverTagsFromApi
    if ($versions.Count -eq 0) {
        return $null
    }
    return ($versions | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
}

function Resolve-TargetVersion {
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        return (Normalize-Version $Version)
    }

    $latest = Resolve-LatestVersionFromTagsPage
    if ([string]::IsNullOrWhiteSpace($latest)) {
        $latest = Resolve-LatestVersionFromApi
    }
    if ([string]::IsNullOrWhiteSpace($latest)) {
        Fail 'Could not resolve latest Databricks CLI version from tags.'
    }
    return $latest
}

function Detect-Os {
    return 'windows'
}

function Detect-Arch {
    $archRaw = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
        $env:PROCESSOR_ARCHITEW6432
    }
    else {
        $env:PROCESSOR_ARCHITECTURE
    }

    if ([string]::IsNullOrWhiteSpace($archRaw)) {
        Fail 'Could not detect Windows processor architecture.'
    }

    $arch = $archRaw.ToLowerInvariant()
    switch ($arch) {
        'amd64' { return 'amd64' }
        'arm64' { return 'arm64' }
        default { Fail "Unsupported architecture: $archRaw" }
    }
}

function Get-InstalledVersion {
    $cmd = Get-Command databricks -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }

    $raw = ''
    try {
        $raw = & databricks version 2>$null
    }
    catch {
        try {
            $raw = & databricks -v 2>$null
        }
        catch {
            return $null
        }
    }

    if ($raw -match '(\d+\.\d+\.\d+)') {
        return $Matches[1]
    }
    return $null
}

function Get-SemverTagsFromApi {
    $tags = Invoke-RestMethod -Uri $githubTagsApiUrl
    $versions = @()
    foreach ($tag in $tags) {
        if ($tag.name -match '^v\d+\.\d+\.\d+$') {
            $versions += $tag.name.TrimStart('v')
        }
    }
    return $versions
}

function Persist-PathInProfile([string]$PathToAdd) {
    $profileFile = $PROFILE
    $profileDir = Split-Path -Parent $profileFile
    if (-not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    }
    if (-not (Test-Path -LiteralPath $profileFile)) {
        New-Item -ItemType File -Force -Path $profileFile | Out-Null
    }

    $content = Get-Content -LiteralPath $profileFile -Raw
    $pattern = '(?ms)^' + [regex]::Escape($profileBlockStart) + '.*?^' + [regex]::Escape($profileBlockEnd) + '\s*'
    $content = [regex]::Replace($content, $pattern, '')

    $snippet = @"
$profileBlockStart
if (-not (`$env:PATH -split [IO.Path]::PathSeparator | Where-Object { `$_ -eq '$PathToAdd' })) {
    `$env:PATH = '$PathToAdd' + [IO.Path]::PathSeparator + `$env:PATH
}
$profileBlockEnd
"@

    Set-Content -LiteralPath $profileFile -Value ($content.TrimEnd() + "`n`n" + $snippet) -Encoding UTF8
}

function Ensure-CliOnPath {
    New-Item -ItemType Directory -Force -Path $InstallBinDir | Out-Null

    $currentParts = $env:PATH -split [IO.Path]::PathSeparator
    if (-not ($currentParts -contains $InstallBinDir)) {
        $env:PATH = "$InstallBinDir$([IO.Path]::PathSeparator)$env:PATH"
    }

    Persist-PathInProfile -PathToAdd $InstallBinDir
    Log "PATH updated to include $InstallBinDir (current shell and future sessions)."
}

function Uninstall-CurrentCli {
    $cmd = Get-Command databricks -ErrorAction SilentlyContinue
    if (-not $cmd) { return }

    $currentBin = $cmd.Source
    Log "Removing current Databricks CLI binary at $currentBin"
    Remove-Item -LiteralPath $currentBin -Force
}

function Compare-Version([string]$A, [string]$B) {
    $va = Parse-SemVer $A
    $vb = Parse-SemVer $B
    if (-not $va -or -not $vb) {
        Fail "Invalid version comparison: '$A' vs '$B'"
    }
    return $va.CompareTo($vb)
}

function Print-Changelog([string]$FromVersion, [string]$ToVersion) {
    if ([string]::IsNullOrWhiteSpace($FromVersion) -or $FromVersion -eq $ToVersion) {
        return
    }

    Log "Databricks CLI changelog: v$FromVersion -> v$ToVersion"
    Write-Host "Compare changes: https://github.com/databricks/cli/compare/v$FromVersion...v$ToVersion"

    $versions = Get-SemverTagsFromApi

    Write-Host 'Release notes in range:'
    foreach ($v in $versions | Sort-Object { [version]$_ }) {
        if ((Compare-Version $FromVersion $ToVersion) -lt 0) {
            if ((Compare-Version $v $FromVersion) -gt 0 -and (Compare-Version $v $ToVersion) -le 0) {
                Write-Host "  - v$($v): https://github.com/databricks/cli/releases/tag/v$($v)"
            }
        }
        else {
            if ((Compare-Version $v $ToVersion) -ge 0 -and (Compare-Version $v $FromVersion) -lt 0) {
                Write-Host "  - v$($v): https://github.com/databricks/cli/releases/tag/v$($v)"
            }
        }
    }
}

function Install-OrUpdateCli {
    $targetVersion = Resolve-TargetVersion
    $currentVersion = Get-InstalledVersion
    $os = Detect-Os
    $arch = Detect-Arch

    Ensure-CliOnPath

    if ($Clean) {
        Log 'Clean mode enabled: forcing Databricks CLI reinstall.'
        if ($currentVersion) {
            Uninstall-CurrentCli
        }
    }

    if ((-not $Clean) -and $currentVersion -and $currentVersion -eq $targetVersion) {
        Log "Databricks CLI already at requested version (v$currentVersion). No changes needed."
        return
    }

    $showChangelog = $false
    if ($currentVersion -and (Compare-Version $currentVersion $targetVersion) -lt 0) {
        $showChangelog = $true
    }
    if ($currentVersion -and (Compare-Version $currentVersion $targetVersion) -gt 0) {
        Uninstall-CurrentCli
    }

    $releaseUrl = "https://github.com/databricks/cli/releases/download/v$targetVersion/databricks_cli_${targetVersion}_${os}_${arch}.zip"

    Log "Installing Databricks CLI v$targetVersion for $os/$arch"
    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpDir | Out-Null

    try {
        $archivePath = Join-Path $tmpDir 'databricks_cli.zip'
        Invoke-WebRequest -Uri $releaseUrl -OutFile $archivePath -UseBasicParsing

        Expand-Archive -Path $archivePath -DestinationPath $tmpDir -Force

        $candidateNames = @('databricks.exe')
        $extractedBin = $null
        foreach ($name in $candidateNames) {
            $candidate = Join-Path $tmpDir $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $extractedBin = $candidate
                break
            }
        }
        if (-not $extractedBin) {
            $fallback = Get-ChildItem -Path $tmpDir -Recurse -File | Where-Object { $_.Name -like 'databricks*' } | Select-Object -First 1
            if ($fallback) { $extractedBin = $fallback.FullName }
        }
        if (-not $extractedBin) {
            Fail 'Downloaded archive did not contain databricks binary.'
        }

        $destName = 'databricks.exe'
        $destPath = Join-Path $InstallBinDir $destName
        Copy-Item -LiteralPath $extractedBin -Destination $destPath -Force
        Log "Databricks CLI installed at $destPath"

        if ($showChangelog) {
            Print-Changelog -FromVersion $currentVersion -ToVersion $targetVersion
        }
    }
    finally {
        if (Test-Path -LiteralPath $tmpDir) {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force
        }
    }
}

Install-OrUpdateCli
