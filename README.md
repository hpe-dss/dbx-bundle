# dbx CLI wrapper

## Installation

### Windows (PowerShell)

Install or update everything:

```powershell
.\install.ps1
```

Clean reinstall (Databricks CLI + Python + Poetry + `.venv`):

```powershell
.\install.ps1 -Clean
```

Set specific Databricks CLI version:

```powershell
.\install.ps1 0.291.0
```

After install, commands are added to your PowerShell profile:
- `dbx`
- `set-databricks-cli`

If needed, load profile manually:

```powershell
. $PROFILE
```

### Linux / macOS (bash)

Install or update everything:

```bash
./install.sh
```

Set specific Databricks CLI version:

```bash
./install.sh 0.291.0
```

After install:

```bash
source ~/.bashrc
```

Commands installed:
- `dbx`
- `set-databricks-cli`

## Poetry compatibility and manual installation

Compatible Poetry versions for this project:

- Recommended: `2.x`
- Tested: `2.1.1`
- Supported range: `>=2.0.0,<3.0.0`

### Linux / macOS

Install Poetry manually (official installer):

```bash
curl -sSL https://install.python-poetry.org | python3 -
export PATH="$HOME/.local/bin:$PATH"
poetry --version
```

Pin Poetry version during installer execution:

```bash
POETRY_VERSION=2.1.1 ./install.sh
# or
POETRY_VERSION=2.1.1 ./install_deps.sh
```

If current Poetry version is not compatible, uninstall/reinstall:

```bash
poetry --version
```

Uninstall current Poetry:

```bash
curl -sSL https://install.python-poetry.org | python3 - --uninstall
rm -f "$HOME/.local/bin/poetry"
```

Install a compatible Poetry version:

```bash
curl -sSL https://install.python-poetry.org | POETRY_VERSION=2.1.1 python3 -
export PATH="$HOME/.local/bin:$PATH"
poetry --version
```

### Windows

`install_deps.ps1` installs Poetry using Python 3.13 managed by global `pyenv-win`.

Optional Poetry version pin:

```powershell
$env:POETRY_VERSION = "2.1.1"
.\install.ps1
```

Clear pin after install:

```powershell
Remove-Item Env:POETRY_VERSION -ErrorAction SilentlyContinue
```

## What install scripts do

`install.sh` / `install.ps1` do the following:
- Copies the project scripts to `~/scripts/dbx/`.
- Runs `set_databricks_cli.sh` / `set_databricks_cli.ps1` to install or update Databricks CLI.
- Ensures Databricks CLI is on `PATH` (current shell and future sessions).
- Runs `install_deps.sh` / `install_deps.ps1` to install/update local Python environment (`.venv`) with Poetry.
- Adds/updates shell profile helpers (`~/.bashrc` on Linux/macOS, `$PROFILE` on Windows).

## `dbx` command

`dbx` acts as a front command for `databricks`:

- If first argument is `--help`, it shows wrapper help and then forwards to `databricks --help`.
- If the first argument is not `bundle`, it forwards all arguments directly to `databricks`.
- If the first argument is `bundle` but the operation is not one of the supported wrapper ops, it also forwards directly to `databricks`.
- If it is `bundle` with a supported operation (`deploy`, `validate`, `destroy`, `summary`, `deployment`, `compile`, `rb-compile`), it runs the wrapper flow:
  - validates and preprocesses YAML resources,
  - interpolates SQL parameters,
  - for non-`compile` operations, executes `databricks bundle ...`,
  - for non-`compile` operations, rolls back SQL interpolation on success.
- For `compile`, it only preprocesses YAML + interpolates SQL and does not execute Databricks CLI.
- For `compile`, preprocessed YAML and SQL files are intentionally kept (no rollback), and YAML backups are saved as `*.yamlpp.bak`.
- For `rb-compile`, it skips Databricks CLI and rolls back:
  - SQL files from `*.TARGET.dab.bak` backups (if they exist),
  - YAML files from `*.TARGET.yamlpp.bak` backups (if they exist), deleting restored YAML backups.

Wrapper options and env vars:

- `--verbose`: print detailed logs from wrapper steps and pass `--verbose` to `databricks bundle`.
- `-t|--target <target>`: required for wrapper bundle operations.
- `BUNDLE_ROOT`: bundle root directory (default: current directory `.`).
- `BUNDLE_FILE`: bundle config path (default: `<BUNDLE_ROOT>/databricks.yml`).

### YAML preprocessing directives

The YAML preprocessor supports these comment directives inside resource files:

- Conditional blocks:
  - `# N: IF (condition)`
  - `# N: FI`
  - Include/exclude lines between `IF/FI` depending on condition result.
- Conditional rename (`RNMIF`) for the next YAML line:
  - Rename next key:
    - `# RNMIF (condition) new_key`
  - Replace text in next value:
    - `# RNMIF (condition) find | replace`

Condition syntax:

- Format: `<variable> <operator> <literal>`
- Supported operators: `==`, `!=`, `in`, `not in`
- Main variable used by `dbx`: `target` (value from `-t <target>`)

Example:

```yaml
# 1: IF (target == 'prod')
environment: production
# 1: FI

# RNMIF (target == 'prod') deployment_env
target: local

# RNMIF (target == 'prod') /tmp/dev | /mnt/prod
path: /tmp/dev/table
```

### SQL interpolation in `.sql` notebooks

`dbx` interpolates variables only for tasks explicitly marked with `# [interpolate]` in YAML:

- Marker must appear immediately above the `- task_key: ...` line.
- Task must reference a `.sql` notebook via `notebook_task.notebook_path`.
- Only local SQL files are processed (Workspace/DBFS/URL paths are ignored).

Parameter sources used for `:param` replacements:

- `job.parameters[*].default` from the job definition.
- `notebook_task.base_parameters` from the task.
- Values like `{{job.*}}` inside `base_parameters` are intentionally skipped.
- `${var.*}` and `${bundle.*}` templates in parameter values are resolved first.

Replacement behavior:

- SQL tokens `:param` are replaced when `param` exists in resolved parameters.
- `::type` casts are preserved (not treated as params).
- Values are typed/formatted for SQL:
  - strings are quoted (`'value'`),
  - numbers/bools/null stay as SQL literals,
  - already single-quoted SQL literals are preserved.

Example:

```yaml
# [interpolate]
- task_key: load_sales
  notebook_task:
    notebook_path: src/sql/load_sales.sql
    base_parameters:
      table_name: "${var.catalog}.${var.schema}.sales"
      limit_rows: 1000
```

```sql
SELECT * FROM :table_name LIMIT :limit_rows;
```

After interpolation:

```sql
SELECT * FROM 'main.analytics.sales' LIMIT 1000;
```

Examples:

```bash
dbx fs ls dbfs:/
dbx bundle validate -t dev
dbx bundle deploy -t prod -- --var release_id=2026_02_25
dbx bundle compile -t dev
dbx bundle rb-compile -t dev
```

## `set-databricks-cli` command

`set-databricks-cli` installs or changes the Databricks CLI version:

- Without arguments, it installs/updates to the latest version found in `databricks/cli` tags.
- With a version argument, it sets exactly that version.
- If requested version equals installed version, it does nothing.
- If requested version is newer, it upgrades and prints changelog links after update.
- If requested version is older, it downgrades (removes current binary and installs target) without changelog output.
- It also ensures the CLI binary directory is added to `PATH` for current and future sessions.

Examples:

```bash
set-databricks-cli
set-databricks-cli 0.289.1
set-databricks-cli v0.289.1
```

After installation run:

```bash
source ~/.bashrc
dbx bundle validate -t <target>
# or
set-databricks-cli
```
