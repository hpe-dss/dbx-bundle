[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$DatabricksCliVersion,
    [string]$InstallDir = $(if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path $HOME 'scripts/dbx' }),
    [string]$PythonVersion = $(if ($env:PYTHON_VERSION) { $env:PYTHON_VERSION } else { '3' }),
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This script is supported only on Windows.'
}

$scriptDir = Split-Path -Parent $PSCommandPath
$targetScriptsDir = Join-Path $InstallDir 'scripts'
$profileFile = $PROFILE
$profileBlockStart = '# >>> dbx wrapper >>>'
$profileBlockEnd = '# <<< dbx wrapper <<<'

New-Item -ItemType Directory -Force -Path $InstallDir, $targetScriptsDir | Out-Null

function Invoke-LocalScript {
    param(
        [Parameter(Mandatory)] [string]$ScriptPath,
        [string]$FirstArg,
        [switch]$CleanMode
    )
    $scriptParams = @{}
    if ($CleanMode) {
        $scriptParams['Clean'] = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($FirstArg)) {
        $scriptParams['Version'] = $FirstArg
    }
    & $ScriptPath @scriptParams
}

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Source file not found: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

$filesToCopy = @(
    @{ Source = 'dbx.ps1'; Destination = (Join-Path $InstallDir 'dbx.ps1') }
    @{ Source = 'set_databricks_cli.ps1'; Destination = (Join-Path $InstallDir 'set_databricks_cli.ps1') }
    @{ Source = 'install_deps.ps1'; Destination = (Join-Path $InstallDir 'install_deps.ps1') }
    @{ Source = 'pyproject.toml'; Destination = (Join-Path $InstallDir 'pyproject.toml') }
    @{ Source = 'README.md'; Destination = (Join-Path $InstallDir 'README.md') }
    @{ Source = 'scripts/yaml_comments_preprocessor.py'; Destination = (Join-Path $targetScriptsDir 'yaml_comments_preprocessor.py') }
    @{ Source = 'scripts/sql_param_interpolator.py'; Destination = (Join-Path $targetScriptsDir 'sql_param_interpolator.py') }
)

foreach ($file in $filesToCopy) {
    Copy-RequiredFile -Source (Join-Path $scriptDir $file.Source) -Destination $file.Destination
}

Push-Location $InstallDir
try {
    if ($Clean) {
        Write-Host '==> Clean mode enabled: forcing clean reinstall of CLI + Python + Poetry + .venv'
    }

    Invoke-LocalScript -ScriptPath (Join-Path $InstallDir 'set_databricks_cli.ps1') -FirstArg $DatabricksCliVersion -CleanMode:$Clean

    $env:PYTHON_VERSION = $PythonVersion
    & (Join-Path $InstallDir 'install_deps.ps1') -Clean:$Clean
}
finally {
    Pop-Location
}

$profileDir = Split-Path -Parent $profileFile
if (-not (Test-Path -LiteralPath $profileDir)) {
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
}
if (-not (Test-Path -LiteralPath $profileFile)) {
    New-Item -ItemType File -Path $profileFile -Force | Out-Null
}

$profileContent = Get-Content -LiteralPath $profileFile -Raw
$pattern = '(?ms)^' + [regex]::Escape($profileBlockStart) + '.*?^' + [regex]::Escape($profileBlockEnd) + '\s*'
$profileContent = [regex]::Replace($profileContent, $pattern, '')

$snippet = @"
$profileBlockStart
function dbx {
    param([Parameter(ValueFromRemainingArguments = `$true)][string[]]`$Args)
    `$scriptPath = Join-Path `$HOME 'scripts/dbx/dbx.ps1'
    if (-not (Test-Path -LiteralPath `$scriptPath -PathType Leaf)) {
        Write-Error "dbx wrapper not found at `$scriptPath"
        return 1
    }
    & `$scriptPath @Args
    return `$LASTEXITCODE
}

function set-databricks-cli {
    param([Parameter(ValueFromRemainingArguments = `$true)][string[]]`$Args)
    `$scriptPath = Join-Path `$HOME 'scripts/dbx/set_databricks_cli.ps1'
    if (-not (Test-Path -LiteralPath `$scriptPath -PathType Leaf)) {
        Write-Error "set-databricks-cli script not found at `$scriptPath"
        return 1
    }
    & `$scriptPath @Args
    return `$LASTEXITCODE
}
$profileBlockEnd
"@

Set-Content -LiteralPath $profileFile -Value ($profileContent.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $snippet) -Encoding UTF8

# Make commands available immediately in the current session (no new shell required).
function global:dbx {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $scriptPath = Join-Path $HOME 'scripts/dbx/dbx.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Write-Error "dbx wrapper not found at $scriptPath"
        return 1
    }
    & $scriptPath @Args
    return $LASTEXITCODE
}

function global:set-databricks-cli {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    $scriptPath = Join-Path $HOME 'scripts/dbx/set_databricks_cli.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Write-Error "set-databricks-cli script not found at $scriptPath"
        return 1
    }
    & $scriptPath @Args
    return $LASTEXITCODE
}

Write-Host "Wrapper installed/updated at: $InstallDir"
Write-Host "Open a new PowerShell session or run: . $profileFile"
Write-Host 'Then use: dbx bundle validate -t <target>'
