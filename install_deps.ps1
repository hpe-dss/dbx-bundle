[CmdletBinding()]
param(
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This script is supported only on Windows.'
}

$scriptDir = Split-Path -Parent $PSCommandPath
Set-Location $scriptDir

$venvDir = if ($env:VENV_DIR) { $env:VENV_DIR } else { '.venv' }
$poetryVersion = if ($env:POETRY_VERSION) { $env:POETRY_VERSION } else { '' }
$pythonMajorMinor = '3.13'
$pyenvRoot = Join-Path $HOME '.pyenv/pyenv-win'

function Log([string]$Message) {
    Write-Host "==> $Message"
}

function Fail([string]$Message) {
    throw $Message
}

function Assert-LastExitCode([string]$Context) {
    if ($LASTEXITCODE -ne 0) {
        Fail "$Context failed with exit code $LASTEXITCODE."
    }
}

function Write-Utf8NoBom([string]$Path, [string]$Value) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $utf8NoBom)
}

function Add-ToPath([string]$PathToAdd) {
    if ([string]::IsNullOrWhiteSpace($PathToAdd)) {
        return
    }
    if (-not (Test-Path -LiteralPath $PathToAdd)) {
        return
    }

    $pathParts = $env:PATH -split [IO.Path]::PathSeparator
    if (-not ($pathParts -contains $PathToAdd)) {
        $env:PATH = "$PathToAdd$([IO.Path]::PathSeparator)$env:PATH"
    }
}

function Get-PyenvCommand {
    $cmd = Get-Command -Name pyenv -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $bat = Join-Path $pyenvRoot 'bin/pyenv.bat'
    if (Test-Path -LiteralPath $bat -PathType Leaf) {
        return $bat
    }

    return $null
}

function Get-PyenvInstalledVersions([string]$PyenvCmd) {
    $installed = @(& $PyenvCmd versions --bare 2>$null | ForEach-Object { $_.Trim() })
    if ($LASTEXITCODE -ne 0) {
        $installed = @(
            & $PyenvCmd versions 2>$null |
            ForEach-Object { $_.Trim().TrimStart('*').Trim() } |
            Where-Object { $_ -match '^\d+\.\d+\.\d+$' }
        )
    }
    return $installed
}

function Ensure-PyenvGlobal {
    Add-ToPath (Join-Path $pyenvRoot 'bin')
    Add-ToPath (Join-Path $pyenvRoot 'shims')

    $pyenvCmd = Get-PyenvCommand
    if ($pyenvCmd) {
        Log "pyenv detected: $pyenvCmd"
        return $pyenvCmd
    }

    Log 'pyenv-win not found. Installing globally for current user.'

    $installer = Join-Path ([IO.Path]::GetTempPath()) ('install-pyenv-win-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/pyenv-win/pyenv-win/master/pyenv-win/install-pyenv-win.ps1' -OutFile $installer -UseBasicParsing
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installer | Out-Host
        Assert-LastExitCode -Context 'pyenv-win installer'
    }
    finally {
        if (Test-Path -LiteralPath $installer) {
            Remove-Item -LiteralPath $installer -Force
        }
    }

    Add-ToPath (Join-Path $pyenvRoot 'bin')
    Add-ToPath (Join-Path $pyenvRoot 'shims')

    $pyenvCmd = Get-PyenvCommand
    if (-not $pyenvCmd) {
        Fail 'pyenv-win installation completed but pyenv command is not available.'
    }

    Log "pyenv installed: $pyenvCmd"
    return $pyenvCmd
}

function Resolve-LatestPatchVersion([string]$PyenvCmd, [string]$MajorMinor) {
    $list = & $PyenvCmd install --list
    if ($LASTEXITCODE -ne 0) {
        $list = & $PyenvCmd install -l
    }
    Assert-LastExitCode -Context 'pyenv install list'

    $candidates = @(
        $list |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match "^$([regex]::Escape($MajorMinor))\.\d+$" }
    )

    if ($candidates.Count -eq 0) {
        Fail "Could not find installable Python versions for $MajorMinor in pyenv."
    }

    return ($candidates | Sort-Object { [version]$_ } | Select-Object -Last 1)
}

function Resolve-PythonFromPyenv([string]$PyenvCmd) {
    $whichOutput = & $PyenvCmd which python 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($whichOutput)) {
        $candidate = ($whichOutput -split "`r?`n" | Select-Object -First 1).Trim()
        if ((-not [string]::IsNullOrWhiteSpace($candidate)) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    $shimCandidates = @(
        (Join-Path $pyenvRoot 'shims/python.exe'),
        (Join-Path $pyenvRoot 'shims/python.bat'),
        (Join-Path $pyenvRoot 'shims/python.cmd')
    )
    foreach ($shim in $shimCandidates) {
        if (Test-Path -LiteralPath $shim -PathType Leaf) {
            return $shim
        }
    }

    Add-ToPath (Join-Path $pyenvRoot 'shims')
    $pythonCmd = Get-Command -Name python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        return $pythonCmd.Source
    }

    return $null
}

function Invoke-PipInstall {
    param(
        [Parameter(Mandatory)] [string]$PythonBin,
        [Parameter(Mandatory)] [string[]]$Packages,
        [Parameter(Mandatory)] [string]$Context
    )

    & $PythonBin -m pip install --upgrade @Packages | Out-Host
    Assert-LastExitCode -Context $Context
}

function Ensure-Python313([string]$PyenvCmd) {
    $targetVersion = Resolve-LatestPatchVersion -PyenvCmd $PyenvCmd -MajorMinor $pythonMajorMinor

    $installed = Get-PyenvInstalledVersions -PyenvCmd $PyenvCmd

    if ($Clean -and ($installed -contains $targetVersion)) {
        Log "Clean mode enabled: removing Python $targetVersion before reinstall"
        & $PyenvCmd uninstall -f $targetVersion | Out-Host
        if ($LASTEXITCODE -ne 0) {
            $versionDir = Join-Path $pyenvRoot "versions/$targetVersion"
            if (Test-Path -LiteralPath $versionDir) {
                Remove-Item -LiteralPath $versionDir -Recurse -Force
            }
        }
        & $PyenvCmd rehash | Out-Host
    }

    if ($Clean -or -not ($installed -contains $targetVersion)) {
        Log "Installing Python $targetVersion with pyenv"
        & $PyenvCmd install $targetVersion | Out-Host
        Assert-LastExitCode -Context "pyenv install $targetVersion"
    }

    Log "Setting global Python version with pyenv: $targetVersion"
    & $PyenvCmd global $targetVersion | Out-Host
    Assert-LastExitCode -Context "pyenv global $targetVersion"

    & $PyenvCmd rehash | Out-Host
    Assert-LastExitCode -Context 'pyenv rehash'

    $pythonBin = Resolve-PythonFromPyenv -PyenvCmd $PyenvCmd
    if (-not $pythonBin) {
        Fail "Python executable could not be resolved from pyenv at $pyenvRoot."
    }

    $versionOutput = & $pythonBin --version 2>&1
    Log "Using Python interpreter: $pythonBin ($versionOutput)"

    return $pythonBin
}

function Ensure-Poetry([string]$PythonBin, [string]$PyenvCmd) {
    $poetryCmd = Get-Command -Name poetry -ErrorAction SilentlyContinue
    if ($poetryCmd -and -not $Clean) {
        Log "Poetry detected: $($poetryCmd.Source)"
        return $poetryCmd.Source
    }

    if ($Clean) {
        Log 'Clean mode enabled: removing Poetry before reinstall'
        & $PythonBin -m pip uninstall -y poetry | Out-Host
    }

    Invoke-PipInstall -PythonBin $PythonBin -Packages @('pip') -Context 'pip upgrade'

    if ([string]::IsNullOrWhiteSpace($poetryVersion)) {
        Log 'Installing Poetry with Python 3.13 via pip'
        Invoke-PipInstall -PythonBin $PythonBin -Packages @('poetry') -Context 'pip install poetry'
    }
    else {
        Log "Installing Poetry==$poetryVersion with Python 3.13 via pip"
        Invoke-PipInstall -PythonBin $PythonBin -Packages @("poetry==$poetryVersion") -Context "pip install poetry==$poetryVersion"
    }

    & $PyenvCmd rehash | Out-Host
    Assert-LastExitCode -Context 'pyenv rehash (poetry)'

    Add-ToPath (Join-Path $pyenvRoot 'shims')

    $poetryCmd = Get-Command -Name poetry -ErrorAction SilentlyContinue
    if (-not $poetryCmd) {
        Fail 'Poetry installed but command not found in PATH.'
    }

    Log "Poetry installed: $($poetryCmd.Source)"
    return $poetryCmd.Source
}

function Ensure-PoetryNonPackageMode {
    $pyproject = Join-Path $scriptDir 'pyproject.toml'
    if (-not (Test-Path -LiteralPath $pyproject -PathType Leaf)) {
        Fail "pyproject.toml not found at $pyproject"
    }

    $content = Get-Content -LiteralPath $pyproject -Raw
    $originalContent = $content

    # Normalize BOM/ZWNBSP at the beginning. Some Poetry/TOML parser paths fail on it.
    if ($content.Length -gt 0 -and [int][char]$content[0] -eq 0xFEFF) {
        $content = $content.Substring(1)
    }

    if ($content -ne $originalContent) {
        Write-Utf8NoBom -Path $pyproject -Value $content
        Log 'Removed BOM from pyproject.toml'
    }

    if ($content -match '(?ms)^\[tool\.poetry\][\s\S]*?^\s*package-mode\s*=\s*false\s*$') {
        return
    }

    if ($content -match '(?m)^\[tool\.poetry\]\s*$') {
        $updated = [regex]::Replace(
            $content,
            '(?m)^\[tool\.poetry\]\s*$',
            "[tool.poetry]`npackage-mode = false"
        )
        Write-Utf8NoBom -Path $pyproject -Value $updated
    }
    else {
        $updated = $content.TrimEnd() + "`n`n[tool.poetry]`npackage-mode = false`n"
        Write-Utf8NoBom -Path $pyproject -Value $updated
    }

    Log 'Configured Poetry with package-mode = false in pyproject.toml'
}

function Configure-LocalVenv([string]$PoetryBin, [string]$PythonBin) {
    $desiredVenv = Join-Path $scriptDir $venvDir

    if ($Clean -and (Test-Path -LiteralPath $desiredVenv)) {
        Log "Clean mode enabled: removing existing virtualenv at $desiredVenv"
        Remove-Item -LiteralPath $desiredVenv -Recurse -Force
    }

    if ($venvDir -ne '.venv') {
        New-Item -ItemType Directory -Force -Path $desiredVenv | Out-Null

        $dotVenv = Join-Path $scriptDir '.venv'
        if (Test-Path -LiteralPath $dotVenv) {
            Remove-Item -LiteralPath $dotVenv -Force -Recurse
        }
        New-Item -ItemType SymbolicLink -Path $dotVenv -Target $desiredVenv | Out-Null
        Log "Linked .venv -> $desiredVenv"
    }

    $env:POETRY_VIRTUALENVS_IN_PROJECT = 'true'
    Log "Configuring local virtualenv at $desiredVenv"
    & $PoetryBin env use $PythonBin
    Assert-LastExitCode -Context 'poetry env use'
}

function Main {
    if ($Clean) {
        Log 'Clean mode enabled: forcing clean reinstall of Python 3.13, Poetry, and local .venv'
    }

    $pyenvCmd = Ensure-PyenvGlobal
    $pythonBin = Ensure-Python313 -PyenvCmd $pyenvCmd
    $poetryBin = Ensure-Poetry -PythonBin $pythonBin -PyenvCmd $pyenvCmd

    Ensure-PoetryNonPackageMode
    Configure-LocalVenv -PoetryBin $poetryBin -PythonBin $pythonBin

    Log 'Installing project dependencies into local .venv'
    & $poetryBin install --no-root --only main --no-interaction | Out-Host
    Assert-LastExitCode -Context 'poetry install'

    Log 'Setup complete'
    $interpolatorPath = Join-Path $scriptDir 'scripts/sql_param_interpolator.py'
    Write-Host "Run with: & '$poetryBin' run python '$interpolatorPath' --help"
}

Main
