# Installation Guide

This document covers installation for:

- Windows (PowerShell)
- Linux/macOS (bash)

It includes:

- Remote bootstrap install (`install-remote.*`)
- Local install from a repository checkout (`install.*`)
- Installer parameters and environment variables
- Behavior of dependency and Databricks CLI helper installers

## Installation Modes

Two entry points are supported:

- Remote bootstrap:
  - Downloads a tagged release archive from GitHub.
  - Verifies checksum (`SHA256SUMS`).
  - Runs the packaged local installer.
- Local checkout:
  - Runs installer scripts directly from this repository.

## Windows (PowerShell)

### Remote Bootstrap

Default install (stable default Databricks CLI version: penultimate semantic tag, fallback to latest if needed):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hpe-dss/dbx-bundle/v1.0.1/install-remote.ps1)))
```

Install a specific Databricks CLI version:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hpe-dss/dbx-bundle/v1.0.1/install-remote.ps1))) -DatabricksCliVersion 0.291.0
```

Use `pyenv-win` mode:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hpe-dss/dbx-bundle/v1.0.1/install-remote.ps1))) -UsePyenv
```

Force clean reinstall (CLI + Python toolchain + `.venv`):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hpe-dss/dbx-bundle/v1.0.1/install-remote.ps1))) -Clean
```

### Local Install From Checkout

```powershell
.\install.ps1
```

Common variants:

```powershell
.\install.ps1 0.291.0
.\install.ps1 -UsePyenv
.\install.ps1 -Clean
.\install.ps1 -InstallDir "C:\tools\dbx"
```

### Parameters: `install-remote.ps1`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `DatabricksCliVersion` | positional string | empty | Databricks CLI version to install. |
| `DbxReleaseVersion` | string | `v1.0.1` or env `DBX_RELEASE_VERSION` | Git tag used for release artifacts. Accepts with/without `v` prefix. |
| `DbxRepo` | string | `hpe-dss/dbx-bundle` or env `DBX_REPO` | GitHub repo in `owner/name` format. |
| `UsePyenv` | switch | false | If present, Python is provisioned with `pyenv-win`; if omitted, direct Python `3.13.x` provisioning is used. |
| `Clean` | switch | false | Forwards clean reinstall to packaged `install.ps1`. |

### Parameters: `install.ps1`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `DatabricksCliVersion` | positional string | empty | Version passed to `set_databricks_cli.ps1`. |
| `InstallDir` | string | `$HOME\scripts\dbx` or env `INSTALL_DIR` | Installation root where wrapper scripts are copied. |
| `PythonVersion` | string | `3` or env `PYTHON_VERSION` | Compatibility parameter; Windows dependency installer currently pins Python to `3.13.x`. |
| `UsePyenv` | switch | false | If present, Python is provisioned with `pyenv-win`; if omitted, direct Python `3.13.x` provisioning is used. |
| `Clean` | switch | false | Forces clean reinstall path in CLI/dependency installers. |

### Parameters: `install_deps.ps1`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `Clean` | switch | false | Recreates local dependency state (`Poetry`, `.venv`, and Python toolchain path depending on mode). |
| `UsePyenv` | switch | false | `true`: manage Python via `pyenv-win` (default patch selection uses the penultimate available `3.13.x` patch, fallback to latest if needed); `false`: use/install Python `3.13.x` directly (winget package `Python.Python.3.13`). |

Related environment variables read by `install_deps.ps1`:

| Env var | Default | Description |
|---|---|---|
| `POETRY_VERSION` | empty | Optional Poetry version pin. Supported range is `>=2.0.0,<3.0.0`. |
| `VENV_DIR` | `.venv` | Target virtualenv directory. |

### Parameters: `set_databricks_cli.ps1`

| Parameter | Type | Default | Description |
|---|---|---|---|
| `Version` | positional string | empty | Requested Databricks CLI version. If omitted, stable default is resolved (penultimate semantic tag, fallback to latest if needed). |
| `InstallBinDir` | string | `$HOME\.local\bin` or env `INSTALL_BIN_DIR` | Destination folder for `databricks.exe`. |
| `Clean` | switch | false | Forces reinstall even if target version is already installed. |

### Windows Environment Variables

| Variable | Used by | Purpose |
|---|---|---|
| `DBX_RELEASE_VERSION` | `install-remote.ps1` | Release tag for remote bootstrap package. |
| `DBX_REPO` | `install-remote.ps1` | Repo override for remote bootstrap package. |
| `INSTALL_DIR` | `install.ps1` | Installation directory override. |
| `POETRY_VERSION` | `install_deps.ps1` | Pin Poetry installer version. |
| `VENV_DIR` | `install_deps.ps1` | Configure location of project virtualenv. |
| `INSTALL_BIN_DIR` | `set_databricks_cli.ps1` | Databricks CLI binary directory. |

## Linux/macOS (bash)

### Remote Bootstrap

Default install:

```bash
curl -fsSL https://raw.githubusercontent.com/hpe-dss/dbx-bundle/v1.0.1/install-remote.sh | bash
```

Install a specific Databricks CLI version:

```bash
curl -fsSL https://raw.githubusercontent.com/hpe-dss/dbx-bundle/v1.0.1/install-remote.sh | bash -s -- 0.291.0
```

Use a different release tag/repo:

```bash
DBX_RELEASE_VERSION=v1.0.1 DBX_REPO=hpe-dss/dbx-bundle \
curl -fsSL https://raw.githubusercontent.com/hpe-dss/dbx-bundle/v1.0.1/install-remote.sh | bash
```

### Local Install From Checkout

```bash
./install.sh
```

Common variants:

```bash
./install.sh 0.291.0
INSTALL_DIR="$HOME/tools/dbx" ./install.sh
PYTHON_VERSION=3.13 ./install.sh
```

### Parameters: `install-remote.sh`

| Input | Default | Description |
|---|---|---|
| positional `databricks_cli_version` | empty | Databricks CLI version passed to packaged `install.sh`. |
| `DBX_RELEASE_VERSION` | `v1.0.1` | Release tag used to download artifacts (`dbx-<tag>.tar.gz`). |
| `DBX_REPO` | `hpe-dss/dbx-bundle` | GitHub repo in `owner/name` format. |

### Parameters: `install.sh`

| Input | Default | Description |
|---|---|---|
| positional `databricks_cli_version` | empty | Version passed to `set_databricks_cli.sh`. |
| `INSTALL_DIR` | `$HOME/scripts/dbx` | Installation root where wrapper scripts are copied. |
| `PYTHON_VERSION` | `3` | Python selector forwarded to `install_deps.sh`. |

### Parameters: `install_deps.sh`

| Env var | Default | Description |
|---|---|---|
| `PYTHON_VERSION` | `3` | Python selector (examples: `3`, `3.12`, `3.13`). |
| `PYTHON_BIN_OVERRIDE` | empty | Absolute path to Python interpreter to force usage. |
| `VENV_DIR` | `.venv` | Local virtualenv directory. |
| `POETRY_VERSION` | empty | Optional Poetry version pin for official Poetry installer. |
| `ALLOW_SUDO_INSTALL` | `false` | Allow sudo for package installs attempted by dependency setup. |

### Parameters: `set_databricks_cli.sh`

| Input | Default | Description |
|---|---|---|
| positional `version` | empty | Databricks CLI version. If omitted, stable default semantic version is resolved (penultimate semantic tag, fallback to latest if needed). |
| `INSTALL_BIN_DIR` | `$HOME/.local/bin` | Destination for `databricks` binary. |
| `ALLOW_SUDO_INSTALL` | `true` | Allow sudo for package installs (for example `unzip` if missing). |

## What Installers Configure

Both platform installers perform the same high-level flow:

1. Copy wrapper scripts into install directory.
2. Install/update Databricks CLI via `set_databricks_cli.*`.
3. Install/update Python/Poetry project dependencies via `install_deps.*`.
4. Add shell/profile functions:
   - `dbx`
   - `set-databricks-cli`

After install:

- Linux/macOS: run `source ~/.bashrc` (or open a new shell).
- Windows: run `. $PROFILE` (or open a new PowerShell session).

## Verification

Run:

```bash
dbx --help
set-databricks-cli
```

Or on Windows PowerShell:

```powershell
dbx --help
set-databricks-cli
```
