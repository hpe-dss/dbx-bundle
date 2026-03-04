[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsFromCaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This script is supported only on Windows.'
}

$allowedOps = @('deploy', 'validate', 'destroy', 'summary', 'deployment', 'compile', 'rb-compile')
$originalArgs = @($ArgsFromCaller)

$dbxHome = Split-Path -Parent $PSCommandPath
$bundleRoot = if ($env:BUNDLE_ROOT) { $env:BUNDLE_ROOT } else { '.' }
$bundleFile = if ($env:BUNDLE_FILE) { $env:BUNDLE_FILE } else { Join-Path $bundleRoot 'databricks.yml' }
$resourcesFolder = Join-Path $bundleRoot 'resources'
$yamlPreprocessorScript = Join-Path $dbxHome 'scripts/yaml_comments_preprocessor.py'
$sqlInterpolatorScript = Join-Path $dbxHome 'scripts/sql_param_interpolator.py'
$wrapperVenvPython = Join-Path $dbxHome '.venv/Scripts/python.exe'
$wrapperInstallScript = Join-Path $dbxHome 'install_deps.ps1'

$target = ''
$op = ''
$wrapperVerbose = $false
$keepPreprocessedFiles = $false
$backups = @{}
$cliArgs = New-Object System.Collections.Generic.List[string]

function Print-Help {
@'
dbx - Databricks bundle wrapper with YAML preprocessing and SQL interpolation

Usage:
  dbx --help
  dbx bundle <operation> -t <target> [wrapper options] [-- <databricks bundle options>]
  dbx bundle rb-compile -t <target>

  dbx <any-non-bundle-databricks-subcommand> [args...]

Supported bundle operations:
  deploy, validate, destroy, summary, deployment, compile, rb-compile

What this wrapper does:
  1) Validates YAML comment directives in bundle resource YAML files.
  2) Applies YAML preprocessing for the selected target.
  3) Runs SQL parameter interpolation for the selected target.
  4) For non-compile ops, executes `databricks bundle <operation> ...`.
  5) For non-compile ops, if successful, runs SQL rollback to restore original SQL files.
  6) For `compile`, it skips Databricks CLI and keeps preprocessed YAML/SQL files.
  7) For `rb-compile`, it rolls back SQL/YAML compile artifacts if backup files still exist.

Options:
  --verbose              Show detailed output for wrapper + databricks bundle.
  --help                 Show this help message.
  BUNDLE_ROOT            Bundle root path (default: current directory).
  BUNDLE_FILE            Bundle file path (default: <BUNDLE_ROOT>/databricks.yml).

Examples:
  dbx bundle validate -t dev
  dbx bundle deploy -t prod -- --var release_id=2026_02_25
  dbx bundle rb-compile -t local
  dbx fs ls dbfs:/
'@ | Write-Host
}

function Run-Python {
    param(
        [Parameter(Mandatory)] [string]$HelperScript,
        [Parameter(ValueFromRemainingArguments = $true)] [string[]]$ScriptArgs
    )
    & $wrapperVenvPython $HelperScript @ScriptArgs
}

function Ensure-FileExists {
    param(
        [Parameter(Mandatory)] [string]$PathValue,
        [Parameter(Mandatory)] [string]$ErrorMessage
    )
    if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
        throw $ErrorMessage
    }
}

function Add-TargetCliArg {
    param(
        [Parameter(Mandatory)] [string]$TargetValue
    )
    $script:target = $TargetValue
    $script:cliArgs.Add('-t')
    $script:cliArgs.Add($TargetValue)
}

function Print-FailureLog {
    param(
        [Parameter(Mandatory)] [string]$StepDescription,
        [Parameter(Mandatory)] [string]$LogFile
    )

    Write-Error "Error: $StepDescription"
    Write-Error '---- detailed output ----'
    Get-Content -LiteralPath $LogFile | ForEach-Object { Write-Error $_ }
    Write-Error '------------------------'
}

function Run-Step {
    param(
        [Parameter(Mandatory)] [string]$StepDescription,
        [Parameter(Mandatory)] [scriptblock]$Action
    )

    $logFile = [System.IO.Path]::GetTempFileName()
    try {
        & $Action *> $logFile
        if ($wrapperVerbose) {
            Get-Content -LiteralPath $logFile | Write-Host
        }
    }
    catch {
        Print-FailureLog -StepDescription $StepDescription -LogFile $logFile
        exit 1
    }
    finally {
        if (Test-Path -LiteralPath $logFile) {
            Remove-Item -LiteralPath $logFile -Force
        }
    }
}

function Ensure-DbxVenv {
    if (Test-Path -LiteralPath $wrapperVenvPython -PathType Leaf) {
        return
    }

    if (-not (Test-Path -LiteralPath $wrapperInstallScript -PathType Leaf)) {
        throw "Wrapper install script not found at $wrapperInstallScript"
    }

    Write-Host '>> Wrapper virtual environment not found. Bootstrapping with poetry.'
    & $wrapperInstallScript
}

function Get-YamlBackupPath {
    param(
        [Parameter(Mandatory)] [string]$YmlPath,
        [Parameter(Mandatory)] [string]$TargetName
    )

    return "$YmlPath.$TargetName.yamlpp.bak"
}

function Rollback-PreprocessedYaml {
    $restored = 0
    $ymlFiles = Get-ChildItem -Path $resourcesFolder -Filter '*.yml' -Recurse -File
    foreach ($yml in $ymlFiles) {
        $backupFile = Get-YamlBackupPath -YmlPath $yml.FullName -TargetName $target
        if (Test-Path -LiteralPath $backupFile -PathType Leaf) {
            Copy-Item -LiteralPath $backupFile -Destination $yml.FullName -Force
            Remove-Item -LiteralPath $backupFile -Force
            $restored += 1
            Write-Host "  restored: $($yml.FullName)"
        }
    }
    Write-Host ">> YAML rollback summary: restored_files=$restored"
}

function Forward-ToDatabricks([string[]]$ForwardArgs) {
    & databricks @ForwardArgs
    exit $LASTEXITCODE
}

if ($originalArgs.Count -gt 0 -and $originalArgs[0] -eq '--help') {
    Print-Help
    Forward-ToDatabricks -ForwardArgs $originalArgs
}

if ($originalArgs.Count -eq 0 -or $originalArgs[0] -ne 'bundle') {
    Forward-ToDatabricks -ForwardArgs $originalArgs
}

$workArgs = New-Object System.Collections.Generic.List[string]
if ($originalArgs.Count -gt 1) {
    foreach ($arg in $originalArgs[1..($originalArgs.Count - 1)]) {
        $workArgs.Add([string]$arg)
    }
}

if ($workArgs.Count -eq 0 -or -not ($allowedOps -contains $workArgs[0])) {
    Forward-ToDatabricks -ForwardArgs $originalArgs
}

$op = $workArgs[0]
if ($workArgs.Count -gt 1) {
    $remainingArgs = New-Object System.Collections.Generic.List[string]
    for ($idx = 1; $idx -lt $workArgs.Count; $idx++) {
        $remainingArgs.Add($workArgs[$idx])
    }
    $workArgs = $remainingArgs
}
else {
    $workArgs = New-Object System.Collections.Generic.List[string]
}

$i = 0
while ($i -lt $workArgs.Count) {
    $arg = $workArgs[$i]
    switch ($arg) {
        '--verbose' {
            $wrapperVerbose = $true
            $i += 1
            continue
        }
        '-t' {
            if (($i + 1) -ge $workArgs.Count) {
                throw 'Error: -t|--target requires a value'
            }
            Add-TargetCliArg -TargetValue $workArgs[$i + 1]
            $i += 2
            continue
        }
        '--target' {
            if (($i + 1) -ge $workArgs.Count) {
                throw 'Error: -t|--target requires a value'
            }
            Add-TargetCliArg -TargetValue $workArgs[$i + 1]
            $i += 2
            continue
        }
        default {
            $cliArgs.Add($arg)
            $i += 1
            continue
        }
    }
}

if ([string]::IsNullOrWhiteSpace($target)) {
    throw 'Error: you must give arg -t|--target <value>'
}
if ([string]::IsNullOrWhiteSpace($op)) {
    throw 'Error: you must give a valid operation argument'
}
Ensure-FileExists -PathValue $bundleFile -ErrorMessage "Error: bundle file not found at $bundleFile"
Ensure-FileExists -PathValue $yamlPreprocessorScript -ErrorMessage "Error: yaml preprocessor script not found at $yamlPreprocessorScript"
Ensure-FileExists -PathValue $sqlInterpolatorScript -ErrorMessage "Error: sql interpolator script not found at $sqlInterpolatorScript"
if (-not (Get-Command poetry -ErrorAction SilentlyContinue)) {
    throw "Error: poetry is required but not installed. Run $wrapperInstallScript first."
}

Ensure-DbxVenv

$bundleRootResolved = Split-Path -Parent (Resolve-Path -LiteralPath $bundleFile)
$bundleFile = Join-Path $bundleRootResolved (Split-Path -Leaf $bundleFile)
$resourcesFolder = Join-Path $bundleRootResolved 'resources'

Push-Location $bundleRootResolved
try {
    if (-not (Test-Path -LiteralPath $resourcesFolder -PathType Container)) {
        throw "Error: resources folder not found in bundle root: $bundleRootResolved"
    }

    if ($op -eq 'compile') {
        $keepPreprocessedFiles = $true
    }

    try {
        if ($op -eq 'rb-compile') {
            Write-Host ">> rb-compile operation: rolling back SQL and YAML compile artifacts for target: $target"
            Run-Step -StepDescription "SQL rollback failed for target '$target'" -Action {
                Run-Python -HelperScript $sqlInterpolatorScript $target '--bundle-file' $bundleFile '--rollback'
            }
            Run-Step -StepDescription "YAML rollback failed for target '$target'" -Action {
                Rollback-PreprocessedYaml
            }
            exit 0
        }

        Write-Host ">> Validating YAML directives for target: $target"
        $ymlFiles = Get-ChildItem -Path $resourcesFolder -Filter '*.yml' -Recurse -File
        foreach ($yml in $ymlFiles) {
            $ymlPath = $yml.FullName
            Run-Step -StepDescription "comment directives validation failed in $ymlPath" -Action {
                Run-Python -HelperScript $yamlPreprocessorScript '--check' '-i' $ymlPath '-t' $target
            }
        }

        Write-Host ">> Applying YAML preprocessing for target: $target"
        $pidValue = [System.Diagnostics.Process]::GetCurrentProcess().Id
        foreach ($yml in $ymlFiles) {
            $ymlPath = $yml.FullName
            if ($op -eq 'compile') {
                $compileBackupFile = Get-YamlBackupPath -YmlPath $ymlPath -TargetName $target
                Copy-Item -LiteralPath $ymlPath -Destination $compileBackupFile -Force
            }
            elseif (-not $keepPreprocessedFiles) {
                $bak = "$($ymlPath).bak.$pidValue"
                Copy-Item -LiteralPath $ymlPath -Destination $bak -Force
                $backups[$ymlPath] = $bak
            }

            Run-Step -StepDescription "YAML preprocessing failed in $ymlPath" -Action {
                Run-Python -HelperScript $yamlPreprocessorScript '-t' $target '-i' $ymlPath '-o' $ymlPath
            }
        }

        Write-Host ">> Running SQL interpolation for target: $target"
        Run-Step -StepDescription "SQL interpolation failed for target '$target'" -Action {
            Run-Python -HelperScript $sqlInterpolatorScript $target '--bundle-file' $bundleFile
        }

        if ($op -eq 'compile') {
            Write-Host '>> Compile operation completed. Databricks CLI execution skipped.'
            Write-Host '>> Preprocessed YAML and interpolated SQL files were kept without rollback.'
            exit 0
        }

        $bundleArgs = New-Object System.Collections.Generic.List[string]
        $bundleArgs.Add($op)
        foreach ($a in $cliArgs) {
            $bundleArgs.Add($a)
        }
        if ($wrapperVerbose) {
            $bundleArgs.Add('--verbose')
        }

        Write-Host ">> Executing Databricks bundle operation: $($bundleArgs -join ' ')"
        Run-Step -StepDescription 'databricks bundle command failed' -Action {
            & databricks bundle @bundleArgs
        }

        Write-Host '>> Bundle completed successfully. Rolling back interpolated SQL files.'
        Run-Step -StepDescription "SQL rollback failed for target '$target'" -Action {
            Run-Python -HelperScript $sqlInterpolatorScript $target '--bundle-file' $bundleFile '--rollback'
        }
    }
    finally {
        if (-not $keepPreprocessedFiles) {
            foreach ($entry in $backups.GetEnumerator()) {
                if (Test-Path -LiteralPath $entry.Value -PathType Leaf) {
                    Move-Item -LiteralPath $entry.Value -Destination $entry.Key -Force
                }
            }
        }
    }
}
finally {
    Pop-Location
}
