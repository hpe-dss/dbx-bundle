[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$UsePyenv
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
$pythonInstallMode = if ($UsePyenv) { 'pyenv' } else { 'direct' }

$pythonMajorMinor = '3.13'
$pythonWingetPackageId = 'Python.Python.3.13'
$pyenvRoot = Join-Path $HOME '.pyenv\pyenv-win'
$pyenvMinVersion = [version]'3.1.0'
$pyenvMaxExclusiveVersion = [version]'4.0.0'
$poetryMinVersion = [version]'2.0.0'
$poetryMaxExclusiveVersion = [version]'3.0.0'

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

function Is-ExecutableCommandPath([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $false
    }
    if (-not [IO.Path]::IsPathRooted($PathValue)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
        return $false
    }

    $ext = [IO.Path]::GetExtension($PathValue)
    if ([string]::IsNullOrWhiteSpace($ext)) {
        $ext = ''
    }
    else {
        $ext = $ext.ToLowerInvariant()
    }

    return @('.exe', '.cmd', '.bat') -contains $ext
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

    foreach ($part in $userPathParts) {
        if ($part.TrimEnd('\\') -ieq $PathToAdd.TrimEnd('\\')) {
            return
        }
    }

    $newUserPath = if ($userPathParts.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($userPathRaw)) {
        "$PathToAdd$separator$userPathRaw"
    }
    else {
        $PathToAdd
    }

    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    Log "Added to user PATH: $PathToAdd"
}

function Get-PoetryBinDirs {
    $dirs = @()

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $dirs += (Join-Path $env:APPDATA 'pypoetry\venv\Scripts')
        $dirs += (Join-Path $env:APPDATA 'pypoetry\bin')
        $dirs += (Join-Path $env:APPDATA 'Python\Scripts')

        $versionedPythonRoot = Join-Path $env:APPDATA 'Python'
        if (Test-Path -LiteralPath $versionedPythonRoot -PathType Container) {
            $versionedScriptDirs = Get-ChildItem -LiteralPath $versionedPythonRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^Python\d+$' } |
                ForEach-Object { Join-Path $_.FullName 'Scripts' }
            if ($versionedScriptDirs) {
                $dirs += $versionedScriptDirs
            }
        }
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
            (Join-Path $dir 'poetry.bat')
        )
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Is-ExecutableCommandPath $candidate) {
            return $candidate
        }
    }

    $poetryCmd = Get-Command -Name poetry -ErrorAction SilentlyContinue
    if ($poetryCmd -and -not [string]::IsNullOrWhiteSpace($poetryCmd.Source)) {
        if (Is-ExecutableCommandPath $poetryCmd.Source) {
            return $poetryCmd.Source
        }
    }

    return $null
}

function Get-PoetryVersion([string]$PoetryCmd) {
    if ([string]::IsNullOrWhiteSpace($PoetryCmd) -or -not (Test-Path -LiteralPath $PoetryCmd -PathType Leaf)) {
        return $null
    }

    $rawOutput = @(& $PoetryCmd --version 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $text = ($rawOutput -join ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $match = [regex]::Match($text, '(\d+\.\d+\.\d+)')
    if (-not $match.Success) {
        return $null
    }

    try {
        return [version]$match.Groups[1].Value
    }
    catch {
        return $null
    }
}

function Is-PoetryVersionCompatible([version]$Version) {
    if ($null -eq $Version) {
        return $false
    }

    return ($Version -ge $poetryMinVersion -and $Version -lt $poetryMaxExclusiveVersion)
}

function Uninstall-Poetry([string]$PythonRunnerPath, [string]$InstallerScript) {
    Log 'Uninstalling current Poetry.'
    if (-not [string]::IsNullOrWhiteSpace($PythonRunnerPath) -and (Test-Path -LiteralPath $PythonRunnerPath -PathType Leaf)) {
        try {
            $InstallerScript | & $PythonRunnerPath - --uninstall | Out-Host
        }
        catch {
            Log 'Poetry uninstall command failed. Continuing with filesystem cleanup.'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $poetryHome = Join-Path $env:APPDATA 'pypoetry'
        if (Test-Path -LiteralPath $poetryHome -PathType Container) {
            Remove-Item -LiteralPath $poetryHome -Recurse -Force
        }
    }

    foreach ($dir in (Get-PoetryBinDirs)) {
        foreach ($name in @('poetry.exe', 'poetry.cmd', 'poetry.bat')) {
            $candidate = Join-Path $dir $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                Remove-Item -LiteralPath $candidate -Force
            }
        }
    }
}

function Get-PyenvRootFromCommandPath([string]$CommandPath) {
    if (-not (Is-ExecutableCommandPath $CommandPath)) {
        return $null
    }

    $leaf = [IO.Path]::GetFileName($CommandPath).ToLowerInvariant()
    if ($leaf -notin @('pyenv.bat', 'pyenv.cmd', 'pyenv.exe')) {
        return $null
    }

    $binDir = Split-Path -Parent $CommandPath
    if ([string]::IsNullOrWhiteSpace($binDir)) {
        return $null
    }

    if ((Split-Path -Leaf $binDir).ToLowerInvariant() -ne 'bin') {
        return $null
    }

    return (Split-Path -Parent $binDir)
}

function Get-PyenvRootCandidates {
    $candidates = @()
    $homeCandidates = @($HOME, $env:USERPROFILE) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    if (-not [string]::IsNullOrWhiteSpace($env:PYENV_ROOT)) {
        $candidates += $env:PYENV_ROOT
    }
    if (-not [string]::IsNullOrWhiteSpace($env:PYENV)) {
        $candidates += $env:PYENV
    }

    $candidates += $pyenvRoot
    foreach ($homePath in $homeCandidates) {
        $candidates += (Join-Path $homePath '.pyenv\pyenv-win')
        $candidates += (Join-Path $homePath '.pyenv')
    }

    return @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Resolve-PyenvRoot {
    foreach ($candidate in (Get-PyenvRootCandidates)) {
        $rootsToCheck = @($candidate)
        if ((Split-Path -Leaf $candidate).ToLowerInvariant() -ne 'pyenv-win') {
            $rootsToCheck += (Join-Path $candidate 'pyenv-win')
        }

        foreach ($root in ($rootsToCheck | Select-Object -Unique)) {
            $pyenvBat = Join-Path $root 'bin\pyenv.bat'
            if (Test-Path -LiteralPath $pyenvBat -PathType Leaf) {
                return $root
            }
        }
    }

    foreach ($candidate in (Get-PyenvRootCandidates)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
            continue
        }

        $match = Get-ChildItem -LiteralPath $candidate -Recurse -Filter pyenv.bat -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '[\\/]bin[\\/]pyenv\.bat$' } |
            Select-Object -First 1

        if ($match) {
            $root = Split-Path -Parent (Split-Path -Parent $match.FullName)
            if (-not [string]::IsNullOrWhiteSpace($root)) {
                return $root
            }
        }
    }

    return $null
}

function Get-PyenvCommand {
    $commandCandidates = @()
    $cmd = Get-Command -Name pyenv -ErrorAction SilentlyContinue
    if ($cmd) {
        foreach ($candidate in @($cmd.Path, $cmd.Source, $cmd.Definition)) {
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }
            $commandCandidates += $candidate
        }
    }

    $whereMatches = @()
    try {
        $whereMatches = @(& cmd.exe /d /c 'where pyenv 2>nul')
    }
    catch {
        $whereMatches = @()
    }

    foreach ($whereMatch in $whereMatches) {
        $trimmed = $whereMatch.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $commandCandidates += $trimmed
        }
    }

    foreach ($candidate in ($commandCandidates | Select-Object -Unique)) {
        if (Is-ExecutableCommandPath $candidate) {
            $resolvedRoot = Get-PyenvRootFromCommandPath $candidate
            if ($resolvedRoot) {
                $script:pyenvRoot = $resolvedRoot
            }
            return $candidate
        }
    }

    $resolvedRoot = Resolve-PyenvRoot
    if ($resolvedRoot) {
        $script:pyenvRoot = $resolvedRoot
        foreach ($candidate in @(
            (Join-Path $script:pyenvRoot 'bin\pyenv.bat'),
            (Join-Path $script:pyenvRoot 'bin\pyenv.cmd'),
            (Join-Path $script:pyenvRoot 'bin\pyenv.exe')
        )) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }

    return $null
}

function Get-PyenvVersion([string]$PyenvCmd) {
    if ([string]::IsNullOrWhiteSpace($PyenvCmd) -or -not (Test-Path -LiteralPath $PyenvCmd -PathType Leaf)) {
        return $null
    }

    $rawOutput = @(& $PyenvCmd --version 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $text = ($rawOutput -join ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $match = [regex]::Match($text, '(\d+\.\d+\.\d+)')
    if (-not $match.Success) {
        return $null
    }

    try {
        return [version]$match.Groups[1].Value
    }
    catch {
        return $null
    }
}

function Is-PyenvVersionCompatible([version]$Version) {
    if ($null -eq $Version) {
        return $false
    }

    return ($Version -ge $pyenvMinVersion -and $Version -lt $pyenvMaxExclusiveVersion)
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RegistryValueOrNull([string]$Path, [string]$Name) {
    try {
        return Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        return $null
    }
    catch [System.Management.Automation.PSArgumentException] {
        return $null
    }
}

function Test-VBScriptAvailable {
    $cscriptPath = Join-Path $env:windir 'System32\cscript.exe'
    $vbscriptDll = Join-Path $env:windir 'System32\vbscript.dll'
    if (-not (Test-Path -LiteralPath $cscriptPath -PathType Leaf)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $vbscriptDll -PathType Leaf)) {
        return $false
    }

    $machineEnabled = Get-RegistryValueOrNull -Path 'HKLM:\Software\Microsoft\Windows Script Host\Settings' -Name Enabled
    if ($machineEnabled -eq 0) {
        return $false
    }

    $userEnabled = Get-RegistryValueOrNull -Path 'HKCU:\Software\Microsoft\Windows Script Host\Settings' -Name Enabled
    if ($userEnabled -eq 0) {
        return $false
    }

    $probeScript = Join-Path ([IO.Path]::GetTempPath()) ('vbscript-probe-' + [Guid]::NewGuid().ToString('N') + '.vbs')
    try {
        Set-Content -LiteralPath $probeScript -Value 'WScript.Quit 0' -Encoding ASCII
        & $cscriptPath //nologo $probeScript *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $probeScript -PathType Leaf) {
            Remove-Item -LiteralPath $probeScript -Force -ErrorAction SilentlyContinue
        }
    }
}

function Ensure-VBScriptReady {
    if (Test-VBScriptAvailable) {
        Log 'VBScript is available.'
        return
    }

    Log 'VBScript is not available. Installing/enabling required components.'
    if (-not (Test-IsAdministrator)) {
        Fail 'VBScript remediation requires administrator privileges. Run this script in an elevated PowerShell session.'
    }

    & dism.exe /Online /Add-Capability /CapabilityName:VBSCRIPT~~~~ /NoRestart /Quiet > $null 2>&1
    Assert-LastExitCode -Context 'Install VBScript capability'

    & "$env:windir\System32\regsvr32.exe" /s "$env:windir\System32\vbscript.dll"
    Assert-LastExitCode -Context 'Register System32 vbscript.dll'

    if (Test-Path -LiteralPath "$env:windir\SysWOW64\vbscript.dll" -PathType Leaf) {
        & "$env:windir\SysWOW64\regsvr32.exe" /s "$env:windir\SysWOW64\vbscript.dll"
        Assert-LastExitCode -Context 'Register SysWOW64 vbscript.dll'
    }

    & cmd.exe /d /c 'assoc .vbs=VBSFile' > $null 2>&1
    Assert-LastExitCode -Context 'Associate .vbs extension'

    & cmd.exe /d /c 'ftype VBSFile="%SystemRoot%\System32\WScript.exe" "%1" %*' > $null 2>&1
    Assert-LastExitCode -Context 'Configure VBSFile file type'

    & reg.exe add 'HKLM\Software\Microsoft\Windows Script Host\Settings' /v Enabled /t REG_DWORD /d 1 /f > $null 2>&1
    Assert-LastExitCode -Context 'Enable WSH in HKLM'

    & reg.exe add 'HKCU\Software\Microsoft\Windows Script Host\Settings' /v Enabled /t REG_DWORD /d 1 /f > $null 2>&1
    Assert-LastExitCode -Context 'Enable WSH in HKCU'

    if (-not (Test-VBScriptAvailable)) {
        Fail 'VBScript is still unavailable after remediation.'
    }

    Log 'VBScript is ready.'
}

function Stop-ProcessesUsingPathPrefix([string]$PathPrefix) {
    if ([string]::IsNullOrWhiteSpace($PathPrefix)) {
        return
    }

    $normalizedPrefix = [IO.Path]::GetFullPath($PathPrefix).TrimEnd('\') + '\'
    $stopped = 0

    foreach ($proc in (Get-Process -ErrorAction SilentlyContinue)) {
        $procPath = $null
        try {
            $procPath = $proc.Path
        }
        catch {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($procPath)) {
            continue
        }

        $normalizedProcPath = [IO.Path]::GetFullPath($procPath)
        if ($normalizedProcPath.StartsWith($normalizedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                $stopped++
            }
            catch {
                # Best effort: process may already have exited or be protected.
            }
        }
    }

    if ($stopped -gt 0) {
        Log "Stopped $stopped process(es) locking pyenv files."
    }
}

function Remove-DirectoryWithRetries([string]$PathValue, [int]$Attempts = 3) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $true
    }

    for ($i = 1; $i -le $Attempts; $i++) {
        if (-not (Test-Path -LiteralPath $PathValue -PathType Container)) {
            return $true
        }

        try {
            Remove-Item -LiteralPath $PathValue -Recurse -Force -ErrorAction Stop
            return $true
        }
        catch {
            if ($i -lt $Attempts) {
                Start-Sleep -Seconds 1
            }
        }
    }

    return -not (Test-Path -LiteralPath $PathValue -PathType Container)
}

function Test-BrokenPyenvLayout([string]$RootPath) {
    if ([string]::IsNullOrWhiteSpace($RootPath)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return $false
    }

    $expectedCmd = Join-Path $RootPath 'pyenv-win\bin\pyenv.bat'
    if (Test-Path -LiteralPath $expectedCmd -PathType Leaf) {
        return $false
    }

    $versionFile = Join-Path $RootPath '.version'
    $readmeFile = Join-Path $RootPath 'README.md'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $readmeFile -PathType Leaf)) {
        return $false
    }

    try {
        $readmeHead = Get-Content -LiteralPath $readmeFile -TotalCount 5 -ErrorAction Stop
        return (($readmeHead -join "`n") -match 'pyenv for Windows')
    }
    catch {
        return $false
    }
}

function Uninstall-Pyenv {
    $resolvedExistingRoot = Resolve-PyenvRoot
    if ($resolvedExistingRoot) {
        $script:pyenvRoot = $resolvedExistingRoot
    }

    if (-not (Test-Path -LiteralPath $pyenvRoot -PathType Container)) {
        $legacyRoot = Join-Path $HOME '.pyenv'
        if (Test-BrokenPyenvLayout -RootPath $legacyRoot) {
            Log "Detected broken pyenv-win layout at $legacyRoot. Removing it."
            Stop-ProcessesUsingPathPrefix -PathPrefix $legacyRoot
            if (-not (Remove-DirectoryWithRetries -PathValue $legacyRoot -Attempts 3)) {
                Fail "Failed to remove broken pyenv root at $legacyRoot."
            }
            return
        }
        Log 'pyenv-win is not installed. Nothing to uninstall.'
        return
    }

    $installer = Join-Path ([IO.Path]::GetTempPath()) ('install-pyenv-win-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    $officialError = $null
    try {
        Log 'Uninstalling pyenv-win using official uninstall script.'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/pyenv-win/pyenv-win/master/pyenv-win/install-pyenv-win.ps1' -OutFile $installer
        & $installer -UNINSTALL | Out-Host
        Assert-LastExitCode -Context 'pyenv-win uninstall'
    }
    catch {
        $officialError = $_
        Log 'Official pyenv-win uninstall did not complete cleanly. Applying local fallback cleanup.'
    }
    finally {
        if (Test-Path -LiteralPath $installer -PathType Leaf) {
            Remove-Item -LiteralPath $installer -Force
        }
    }

    if (Test-Path -LiteralPath $pyenvRoot -PathType Container) {
        Stop-ProcessesUsingPathPrefix -PathPrefix $pyenvRoot
        if (-not (Remove-DirectoryWithRetries -PathValue $pyenvRoot -Attempts 3)) {
            if ($officialError) {
                Fail "Failed to remove pyenv-win at $pyenvRoot after official uninstall fallback. Last error: $($officialError.Exception.Message)"
            }
            Fail "Failed to remove pyenv-win at $pyenvRoot after fallback cleanup."
        }
    }
}

function Install-PyenvWin {
    $installer = Join-Path ([IO.Path]::GetTempPath()) ('install-pyenv-win-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/pyenv-win/pyenv-win/master/pyenv-win/install-pyenv-win.ps1' -OutFile $installer -UseBasicParsing
        & powershell -NoProfile -ExecutionPolicy Bypass -File $installer | Out-Host
        Assert-LastExitCode -Context 'pyenv-win installer'
    }
    finally {
        if (Test-Path -LiteralPath $installer -PathType Leaf) {
            Remove-Item -LiteralPath $installer -Force
        }
    }
}

function Ensure-PyenvReady {
    $resolvedExistingRoot = Resolve-PyenvRoot
    if ($resolvedExistingRoot) {
        $script:pyenvRoot = $resolvedExistingRoot
    }

    if ($Clean) {
        Log 'Clean mode enabled: uninstalling pyenv-win before reinstall.'
        Uninstall-Pyenv
    }

    $pyenvCmd = Get-PyenvCommand
    if ($pyenvCmd) {
        Ensure-UserPathContains (Join-Path $pyenvRoot 'bin')
        Ensure-UserPathContains (Join-Path $pyenvRoot 'shims')
        Ensure-VBScriptReady

        $currentVersion = Get-PyenvVersion -PyenvCmd $pyenvCmd
        if ($currentVersion -and (Is-PyenvVersionCompatible $currentVersion)) {
            Log "pyenv detected and compatible: $pyenvCmd (version $currentVersion)"
            & $pyenvCmd rehash | Out-Host
            Assert-LastExitCode -Context 'pyenv rehash'
            return $pyenvCmd
        }

        if ($null -eq $currentVersion) {
            Log 'pyenv detected but version could not be determined. Updating pyenv-win.'
        }
        else {
            Log "pyenv version $currentVersion is not compatible (required >=$pyenvMinVersion and <$pyenvMaxExclusiveVersion). Updating pyenv-win."
        }

        & $pyenvCmd update | Out-Host
        Assert-LastExitCode -Context 'pyenv update'
        & $pyenvCmd rehash | Out-Host
        Assert-LastExitCode -Context 'pyenv rehash'

        $updatedVersion = Get-PyenvVersion -PyenvCmd $pyenvCmd
        if ($null -eq $updatedVersion) {
            Fail 'pyenv updated but version could not be determined.'
        }
        if (-not (Is-PyenvVersionCompatible $updatedVersion)) {
            Fail "pyenv version $updatedVersion is not compatible (required >=$pyenvMinVersion and <$pyenvMaxExclusiveVersion)."
        }

        Log "pyenv updated: $pyenvCmd (version $updatedVersion)"
        return $pyenvCmd
    }

    Log 'pyenv not found. Installing pyenv-win.'
    $legacyRoot = Join-Path $HOME '.pyenv'
    if (Test-BrokenPyenvLayout -RootPath $legacyRoot) {
        Log "Detected broken pyenv-win layout at $legacyRoot. Removing it before reinstall."
        Stop-ProcessesUsingPathPrefix -PathPrefix $legacyRoot
        if (-not (Remove-DirectoryWithRetries -PathValue $legacyRoot -Attempts 3)) {
            Fail "Failed to remove broken pyenv root at $legacyRoot."
        }
    }
    Ensure-VBScriptReady
    Install-PyenvWin

    $resolvedInstalledRoot = Resolve-PyenvRoot
    if ($resolvedInstalledRoot) {
        if ($resolvedInstalledRoot -ne $script:pyenvRoot) {
            Log "Detected pyenv root: $resolvedInstalledRoot"
        }
        $script:pyenvRoot = $resolvedInstalledRoot
    }

    Ensure-UserPathContains (Join-Path $pyenvRoot 'bin')
    Ensure-UserPathContains (Join-Path $pyenvRoot 'shims')

    $pyenvCmd = Get-PyenvCommand
    if (-not $pyenvCmd) {
        Fail 'pyenv-win installation completed but pyenv command is not available.'
    }

    & $pyenvCmd rehash | Out-Host
    Assert-LastExitCode -Context 'pyenv rehash'

    $installedVersion = Get-PyenvVersion -PyenvCmd $pyenvCmd
    if ($null -eq $installedVersion) {
        Fail 'pyenv installed but version could not be determined.'
    }
    if (-not (Is-PyenvVersionCompatible $installedVersion)) {
        Fail "pyenv version $installedVersion is not compatible (required >=$pyenvMinVersion and <$pyenvMaxExclusiveVersion)."
    }

    Log "pyenv installed: $pyenvCmd (version $installedVersion)"
    return $pyenvCmd
}

function Get-PythonVersionFromInvocation([string]$CommandPath, [string[]]$InvocationArgs) {
    if ([string]::IsNullOrWhiteSpace($CommandPath)) {
        return $null
    }

    try {
        $rawOutput = @(& $CommandPath @InvocationArgs 2>&1)
    }
    catch {
        return $null
    }

    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $text = ($rawOutput -join ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $match = [regex]::Match($text, 'Python\s+(\d+\.\d+\.\d+)')
    if (-not $match.Success) {
        return $null
    }

    try {
        return [version]$match.Groups[1].Value
    }
    catch {
        return $null
    }
}

function Test-MajorMinorMatch([version]$Version, [string]$MajorMinor) {
    if ($null -eq $Version -or [string]::IsNullOrWhiteSpace($MajorMinor)) {
        return $false
    }

    $parts = $MajorMinor.Split('.', 2)
    if ($parts.Count -ne 2) {
        return $false
    }

    $major = 0
    $minor = 0
    if (-not [int]::TryParse($parts[0], [ref]$major)) {
        return $false
    }
    if (-not [int]::TryParse($parts[1], [ref]$minor)) {
        return $false
    }

    return ($Version.Major -eq $major -and $Version.Minor -eq $minor)
}

function Test-IsPyenvPath([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $false
    }

    try {
        $candidateFullPath = [IO.Path]::GetFullPath($PathValue).TrimEnd('\').ToLowerInvariant()
        $pyenvRootFullPath = [IO.Path]::GetFullPath($pyenvRoot).TrimEnd('\').ToLowerInvariant()
        return ($candidateFullPath -eq $pyenvRootFullPath -or $candidateFullPath.StartsWith("$pyenvRootFullPath\"))
    }
    catch {
        return $false
    }
}

function Resolve-PythonFromPyLauncher([string]$MajorMinor) {
    $selector = "-$MajorMinor"
    $pyLauncher = Get-Command -Name py -ErrorAction SilentlyContinue
    if (-not $pyLauncher -or [string]::IsNullOrWhiteSpace($pyLauncher.Source)) {
        return $null
    }

    $pyLauncherPath = $pyLauncher.Source
    $version = Get-PythonVersionFromInvocation -CommandPath $pyLauncherPath -InvocationArgs @($selector, '--version')
    if (-not (Test-MajorMinorMatch -Version $version -MajorMinor $MajorMinor)) {
        return $null
    }

    $pythonPathOutput = @(& $pyLauncherPath $selector -c 'import sys; print(sys.executable)' 2>$null)
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $pythonPath = ($pythonPathOutput -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($pythonPath)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
        return $null
    }
    if (Test-IsPyenvPath -PathValue $pythonPath) {
        return $null
    }

    return [PSCustomObject]@{
        Path    = $pythonPath
        Version = $version
        Source  = 'py launcher'
    }
}

function Resolve-PythonFromCommandName([string]$CommandName, [string]$MajorMinor) {
    if ([string]::IsNullOrWhiteSpace($CommandName)) {
        return $null
    }

    $cmd = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
    if (-not $cmd -or [string]::IsNullOrWhiteSpace($cmd.Source)) {
        return $null
    }

    $candidatePath = $cmd.Source
    if (-not (Is-ExecutableCommandPath $candidatePath)) {
        return $null
    }
    if (Test-IsPyenvPath -PathValue $candidatePath) {
        return $null
    }

    $version = Get-PythonVersionFromInvocation -CommandPath $candidatePath -InvocationArgs @('--version')
    if (-not (Test-MajorMinorMatch -Version $version -MajorMinor $MajorMinor)) {
        return $null
    }

    return [PSCustomObject]@{
        Path    = $candidatePath
        Version = $version
        Source  = $CommandName
    }
}

function Get-DirectPython313Candidate {
    $candidate = Resolve-PythonFromPyLauncher -MajorMinor $pythonMajorMinor
    if ($candidate) {
        return $candidate
    }

    foreach ($name in @('python', 'python3')) {
        $candidate = Resolve-PythonFromCommandName -CommandName $name -MajorMinor $pythonMajorMinor
        if ($candidate) {
            return $candidate
        }
    }

    return $null
}

function Install-Python313Direct {
    $winget = Get-Command -Name winget -ErrorAction SilentlyContinue
    if (-not $winget -or [string]::IsNullOrWhiteSpace($winget.Source)) {
        Fail "Python $pythonMajorMinor was not found and winget is not available. Install Python $pythonMajorMinor.x manually from https://www.python.org/downloads/windows/ and retry."
    }

    $wingetArgs = @(
        'install',
        '--id', $pythonWingetPackageId,
        '--exact',
        '--source', 'winget',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--silent',
        '--disable-interactivity'
    )

    if ($Clean) {
        $wingetArgs += '--force'
    }

    Log "Installing Python $pythonMajorMinor.x using winget package $pythonWingetPackageId"
    $wingetOutput = @(& $winget.Source @wingetArgs 2>&1)
    if ($LASTEXITCODE -ne 0) {
        if ($wingetOutput.Count -gt 0) {
            $wingetOutput | Out-Host
        }
        Fail "winget install $pythonWingetPackageId failed with exit code $LASTEXITCODE."
    }
}

function Ensure-Python313Direct {
    $candidate = Get-DirectPython313Candidate
    if ($candidate -and -not $Clean) {
        Log "Using Python interpreter: $($candidate.Path) (Python $($candidate.Version), source: $($candidate.Source))"
        return $candidate.Path
    }

    if ($candidate -and $Clean) {
        Log "Clean mode enabled: reinstalling Python $pythonMajorMinor.x via winget."
    }
    elseif (-not $candidate) {
        Log "Python $pythonMajorMinor.x not found. Installing with winget."
    }

    Install-Python313Direct
    $candidate = Get-DirectPython313Candidate
    if (-not $candidate) {
        Fail "Python $pythonMajorMinor.x installation completed but the interpreter could not be resolved. Restart PowerShell and run install again."
    }

    Log "Using Python interpreter: $($candidate.Path) (Python $($candidate.Version), source: $($candidate.Source))"
    return $candidate.Path
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

    return @($installed | Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Select-Object -Unique)
}

function Resolve-PreferredPatchVersion([string]$PyenvCmd, [string]$MajorMinor) {
    $list = & $PyenvCmd install --list
    if ($LASTEXITCODE -ne 0) {
        $list = & $PyenvCmd install -l
    }
    Assert-LastExitCode -Context 'pyenv install list'

    $pattern = "^$([regex]::Escape($MajorMinor))\.\d+$"
    $candidates = @(
        $list |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match $pattern }
    )

    if ($candidates.Count -eq 0) {
        Fail "Could not find installable Python versions for $MajorMinor in pyenv."
    }

    $ordered = @(
        $candidates |
        Select-Object -Unique |
        Sort-Object { [version]$_ }
    )

    if ($ordered.Count -ge 2) {
        return $ordered[-2]
    }

    return $ordered[-1]
}

function Resolve-PythonFromPyenv([string]$PyenvCmd) {
    $whichOutput = & $PyenvCmd which python 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($whichOutput)) {
        $candidate = ($whichOutput -split "`r?`n" | Select-Object -First 1).Trim()
        if ((-not [string]::IsNullOrWhiteSpace($candidate)) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    return $null
}

function Ensure-Python313([string]$PyenvCmd) {
    $targetVersion = Resolve-PreferredPatchVersion -PyenvCmd $PyenvCmd -MajorMinor $pythonMajorMinor
    $installed = Get-PyenvInstalledVersions -PyenvCmd $PyenvCmd

    Log "No explicit Python patch was provided. Using default stable Python $targetVersion for $pythonMajorMinor (penultimate available patch, fallback to latest if needed)."

    if ($Clean -and ($installed -contains $targetVersion)) {
        Log "Clean mode enabled: removing Python $targetVersion before reinstall"
        & $PyenvCmd uninstall -f $targetVersion | Out-Host
        if ($LASTEXITCODE -ne 0) {
            $versionDir = Join-Path $pyenvRoot "versions/$targetVersion"
            if (Test-Path -LiteralPath $versionDir -PathType Container) {
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

    $preferredPythonBin = Join-Path $pyenvRoot "versions/$targetVersion/python.exe"
    $pythonBin = $null
    if (Test-Path -LiteralPath $preferredPythonBin -PathType Leaf) {
        $pythonBin = $preferredPythonBin
    }
    else {
        $pythonBin = Resolve-PythonFromPyenv -PyenvCmd $PyenvCmd
    }
    if (-not $pythonBin) {
        Fail "Python executable could not be resolved from pyenv at $pyenvRoot."
    }

    $versionOutput = & $pythonBin --version 2>&1
    Log "Using Python interpreter: $pythonBin ($versionOutput)"

    return $pythonBin
}

function Ensure-Poetry([string]$PythonBin) {
    if ([string]::IsNullOrWhiteSpace($PythonBin) -or -not (Test-Path -LiteralPath $PythonBin -PathType Leaf)) {
        Fail 'No valid configured Python interpreter was provided for Poetry install.'
    }

    $installerScript = (Invoke-WebRequest -Uri 'https://install.python-poetry.org' -UseBasicParsing).Content
    if ([string]::IsNullOrWhiteSpace($installerScript)) {
        Fail 'Poetry installer content is empty.'
    }

    $pinnedPoetryVersion = $null
    if (-not [string]::IsNullOrWhiteSpace($poetryVersion)) {
        try {
            $pinnedPoetryVersion = [version]$poetryVersion
        }
        catch {
            Fail "POETRY_VERSION '$poetryVersion' is not a valid semantic version."
        }

        if (-not (Is-PoetryVersionCompatible $pinnedPoetryVersion)) {
            Fail "POETRY_VERSION '$poetryVersion' is outside supported range >=$poetryMinVersion and <$poetryMaxExclusiveVersion."
        }
    }

    $poetryCmd = Resolve-PoetryCommand
    $shouldInstall = $Clean
    $needsUninstall = $false
    $reinstallReason = $null

    if ($poetryCmd) {
        $currentVersion = Get-PoetryVersion -PoetryCmd $poetryCmd
        if ($null -eq $currentVersion) {
            $shouldInstall = $true
            $needsUninstall = $true
            $reinstallReason = 'Poetry command exists but failed to report a valid version.'
        }
        elseif (-not (Is-PoetryVersionCompatible $currentVersion)) {
            $shouldInstall = $true
            $needsUninstall = $true
            $reinstallReason = "Installed Poetry version $currentVersion is not compatible (required >=$poetryMinVersion and <$poetryMaxExclusiveVersion)."
        }
        elseif ($pinnedPoetryVersion -and $currentVersion -ne $pinnedPoetryVersion) {
            $shouldInstall = $true
            $needsUninstall = $true
            $reinstallReason = "Installed Poetry version $currentVersion does not match pinned POETRY_VERSION=$poetryVersion."
        }
        elseif (-not $Clean) {
            Ensure-PoetryPathEntries
            Log "Poetry detected and compatible: $poetryCmd (version $currentVersion)"
            return $poetryCmd
        }
    }
    elseif (-not $Clean) {
        $shouldInstall = $true
        $reinstallReason = 'Poetry is not installed.'
    }

    if ($Clean) {
        $needsUninstall = $true
        if (-not $reinstallReason) {
            $reinstallReason = 'Clean mode enabled.'
        }
    }

    if ($reinstallReason) {
        Log $reinstallReason
    }

    if ($needsUninstall) {
        Uninstall-Poetry -PythonRunnerPath $PythonBin -InstallerScript $installerScript
    }

    if (-not $shouldInstall) {
        Fail 'Poetry installation flow reached an invalid state.'
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

        Log "Installing Poetry with official installer using configured Python: $PythonBin -"
        $installerScript | & $PythonBin - | Out-Host
        Assert-LastExitCode -Context "official Poetry installer ($PythonBin -)"
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

    $installedVersion = Get-PoetryVersion -PoetryCmd $poetryCmd
    if ($null -eq $installedVersion) {
        Fail 'Poetry installed but version could not be determined.'
    }
    if (-not (Is-PoetryVersionCompatible $installedVersion)) {
        Fail "Installed Poetry version $installedVersion is not compatible (required >=$poetryMinVersion and <$poetryMaxExclusiveVersion)."
    }
    if ($pinnedPoetryVersion -and $installedVersion -ne $pinnedPoetryVersion) {
        Fail "Installed Poetry version $installedVersion does not match pinned POETRY_VERSION=$poetryVersion."
    }
    & $poetryCmd --version | Out-Host

    Log "Poetry installed: $poetryCmd (version $installedVersion)"
    return $poetryCmd
}

function Ensure-PoetryNonPackageMode {
    $pyproject = Join-Path $scriptDir 'pyproject.toml'
    if (-not (Test-Path -LiteralPath $pyproject -PathType Leaf)) {
        Fail "pyproject.toml not found at $pyproject"
    }

    $content = Get-Content -LiteralPath $pyproject -Raw
    if ($content.Length -gt 0 -and [int][char]$content[0] -eq 0xFEFF) {
        $content = $content.Substring(1)
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
    }
    else {
        $updated = $content.TrimEnd() + "`n`n[tool.poetry]`npackage-mode = false`n"
    }

    Write-Utf8NoBom -Path $pyproject -Value $updated
    Log 'Configured Poetry with package-mode = false in pyproject.toml'
}

function Configure-LocalVenv([string]$PoetryBin, [string]$PythonBin) {
    $desiredVenv = Join-Path $scriptDir $venvDir

    if ($Clean -and (Test-Path -LiteralPath $desiredVenv)) {
        Log "Clean mode enabled: removing existing virtualenv at $desiredVenv"
        Remove-Item -LiteralPath $desiredVenv -Recurse -Force
    }

    if ($venvDir -eq '.venv') {
        if ((Test-Path -LiteralPath $desiredVenv) -and -not (Test-Path -LiteralPath $desiredVenv -PathType Container)) {
            Remove-Item -LiteralPath $desiredVenv -Recurse -Force
        }
        if (-not (Test-Path -LiteralPath $desiredVenv -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $desiredVenv | Out-Null
        }
    }
    else {
        New-Item -ItemType Directory -Force -Path $desiredVenv | Out-Null

        $dotVenv = Join-Path $scriptDir '.venv'
        if (Test-Path -LiteralPath $dotVenv) {
            Remove-Item -LiteralPath $dotVenv -Recurse -Force
        }
        New-Item -ItemType SymbolicLink -Path $dotVenv -Target $desiredVenv | Out-Null
        Log "Linked .venv -> $desiredVenv"
    }

    $env:POETRY_VIRTUALENVS_IN_PROJECT = 'true'
    & $PoetryBin config virtualenvs.in-project true --local | Out-Host

    Log "Configuring Poetry local virtualenv at $desiredVenv"
    & $PoetryBin env use $PythonBin | Out-Host
    Assert-LastExitCode -Context 'poetry env use'
}

function Install-ProjectDependencies([string]$PoetryBin) {
    Log 'Installing project dependencies from pyproject.toml with Poetry'
    & $PoetryBin install --no-root --only main --no-interaction | Out-Host
    Assert-LastExitCode -Context 'poetry install'
}

function Main {
    if ($Clean) {
        if ($pythonInstallMode -eq 'pyenv') {
            Log 'Clean mode enabled: uninstalling pyenv and poetry, then reinstalling Python 3.13, Poetry, and local .venv.'
        }
        else {
            Log 'Clean mode enabled: reinstalling Python 3.13, Poetry, and local .venv without pyenv.'
        }
    }

    if ($pythonInstallMode -eq 'pyenv') {
        $pyenvCmd = Ensure-PyenvReady
        $pythonBin = Ensure-Python313 -PyenvCmd $pyenvCmd
    }
    else {
        Log 'Python install mode: direct (no pyenv).'
        $pythonBin = Ensure-Python313Direct
    }

    $poetryBin = Ensure-Poetry -PythonBin $pythonBin

    Ensure-PoetryNonPackageMode
    Configure-LocalVenv -PoetryBin $poetryBin -PythonBin $pythonBin

    Install-ProjectDependencies -PoetryBin $poetryBin

    Log 'Setup complete'
    $interpolatorPath = Join-Path $scriptDir 'scripts/sql_param_interpolator.py'
    Write-Host "Run with: & '$poetryBin' run python '$interpolatorPath' --help"
}

Main
