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

function Ensure-UserPathContains([string]$PathToAdd) {
    if ([string]::IsNullOrWhiteSpace($PathToAdd)) {
        return
    }
    if (-not (Test-Path -LiteralPath $PathToAdd)) {
        return
    }

    $sessionPathParts = $env:PATH -split [IO.Path]::PathSeparator
    if (-not ($sessionPathParts -contains $PathToAdd)) {
        $env:PATH = "$PathToAdd$([IO.Path]::PathSeparator)$env:PATH"
    }

    $separator = [IO.Path]::PathSeparator
    $userPathRaw = [Environment]::GetEnvironmentVariable('Path', 'User')
    $userPathParts = @()
    if (-not [string]::IsNullOrWhiteSpace($userPathRaw)) {
        $userPathParts = @($userPathRaw -split [regex]::Escape([string]$separator))
    }

    $exists = $false
    foreach ($part in $userPathParts) {
        if ($part.TrimEnd('\') -ieq $PathToAdd.TrimEnd('\')) {
            $exists = $true
            break
        }
    }

    if (-not $exists) {
        $newUserPath = if ($userPathParts.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($userPathRaw)) {
            "$PathToAdd$separator$userPathRaw"
        }
        else {
            $PathToAdd
        }
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        Log "Added to user PATH: $PathToAdd"
    }
}

function Get-PoetryBinDirs {
    $dirs = @()

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $dirs += (Join-Path $env:APPDATA 'Python\Scripts')
        $dirs += (Join-Path $env:APPDATA 'pypoetry\venv\Scripts')
        $dirs += (Join-Path $env:APPDATA 'pypoetry\bin')
    }

    $dirs += (Join-Path $HOME '.local\bin')

    return @(
        $dirs |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
}

function Ensure-PoetryPathEntries {
    foreach ($dir in (Get-PoetryBinDirs)) {
        Ensure-UserPathContains $dir
    }
}

function Resolve-PoetryCommand {
    $candidates = @()

    foreach ($dir in (Get-PoetryBinDirs)) {
        $candidates += @(
            (Join-Path $dir 'poetry.exe'),
            (Join-Path $dir 'poetry.cmd'),
            (Join-Path $dir 'poetry.bat'),
            (Join-Path $dir 'poetry')
        )
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $poetryCmd = Get-Command -Name poetry -ErrorAction SilentlyContinue
    if ($poetryCmd -and -not [string]::IsNullOrWhiteSpace($poetryCmd.Source)) {
        $source = $poetryCmd.Source
        if ([IO.Path]::IsPathRooted($source) -and (Test-Path -LiteralPath $source -PathType Leaf)) {
            return $source
        }
    }

    return $null
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
    Ensure-UserPathContains (Join-Path $pyenvRoot 'bin')
    Ensure-UserPathContains (Join-Path $pyenvRoot 'shims')

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

    Ensure-UserPathContains (Join-Path $pyenvRoot 'bin')
    Ensure-UserPathContains (Join-Path $pyenvRoot 'shims')

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

    return $null
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

function Ensure-Poetry([string]$PythonBin) {
    $poetryCmd = $null
    if (-not $Clean) {
        $poetryCmd = Resolve-PoetryCommand
    }

    if ($poetryCmd -and -not $Clean) {
        & $poetryCmd --version | Out-Host
        if ($LASTEXITCODE -eq 0) {
            Log "Poetry detected: $poetryCmd"
            return $poetryCmd
        }
        Log 'Poetry command exists but failed to execute. Reinstalling Poetry.'
    }

    if ($Clean -and -not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $poetryHome = Join-Path $env:APPDATA 'pypoetry'
        if (Test-Path -LiteralPath $poetryHome -PathType Container) {
            Log "Clean mode enabled: removing Poetry home at $poetryHome"
            Remove-Item -LiteralPath $poetryHome -Recurse -Force
        }
    }

    $installerScript = (Invoke-WebRequest -Uri 'https://install.python-poetry.org' -UseBasicParsing).Content
    if ([string]::IsNullOrWhiteSpace($installerScript)) {
        Fail 'Poetry installer content is empty.'
    }

    $hadPoetryVersion = Test-Path Env:POETRY_VERSION
    $previousPoetryVersion = if ($hadPoetryVersion) { $env:POETRY_VERSION } else { $null }

    try {
        if ([string]::IsNullOrWhiteSpace($poetryVersion)) {
            Remove-Item Env:POETRY_VERSION -ErrorAction SilentlyContinue
        }
        else {
            $env:POETRY_VERSION = $poetryVersion
            Log "Using POETRY_VERSION=$poetryVersion"
        }

        $pyLauncher = Get-Command -Name py -ErrorAction SilentlyContinue
        if ($pyLauncher) {
            Log 'Installing Poetry with official installer: (Invoke-WebRequest -Uri https://install.python-poetry.org -UseBasicParsing).Content | py -'
            $installerScript | & $pyLauncher.Source - | Out-Host
            Assert-LastExitCode -Context 'official Poetry installer (py -)'
        }
        else {
            Log "Python launcher 'py' not found. Installing Poetry with $PythonBin -"
            $installerScript | & $PythonBin - | Out-Host
            Assert-LastExitCode -Context 'official Poetry installer (python -)'
        }
    }
    finally {
        if ($hadPoetryVersion) {
            $env:POETRY_VERSION = $previousPoetryVersion
        }
        else {
            Remove-Item Env:POETRY_VERSION -ErrorAction SilentlyContinue
        }
    }

    Ensure-PoetryPathEntries

    $poetryCmd = Resolve-PoetryCommand
    if ([string]::IsNullOrWhiteSpace($poetryCmd) -or -not (Test-Path -LiteralPath $poetryCmd -PathType Leaf)) {
        Fail 'Poetry installed but command was not found. Verify user PATH includes %APPDATA%\Python\Scripts.'
    }

    & $poetryCmd --version | Out-Host
    Assert-LastExitCode -Context 'poetry --version'

    Log "Poetry installed: $poetryCmd"
    return $poetryCmd
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
    Log 'Configuring Poetry: virtualenvs.prefer-active-python = true'
    & $PoetryBin config virtualenvs.prefer-active-python true | Out-Host
    Assert-LastExitCode -Context 'poetry config virtualenvs.prefer-active-python true'

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
    $poetryBin = Ensure-Poetry -PythonBin $pythonBin

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
