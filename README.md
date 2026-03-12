# dbx CLI wrapper

## windows powershell install
```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/hpe-dss/dbx-bundle/v1.0.1/install-remote.ps1)))
```

## mac/linux bash install
```bash
curl -fsSL https://raw.githubusercontent.com/hpe-dss/dbx-bundle/v1.0.1/install-remote.sh | bash
```

Detailed installation documentation (Windows + Linux/macOS, including installer parameters) is in [INSTALL.md](INSTALL.md).

## `dbx` command

`dbx` is a wrapper over `databricks` focused on bundle workflows with YAML preprocessing and SQL interpolation.

What `dbx` can do:

- Pass-through mode: forwards non-wrapper commands directly to `databricks`.
- Bundle wrapper mode: for supported bundle ops, runs preprocessing/interpolation before Databricks CLI.
- Compile artifact mode: generates compile-time YAML/SQL artifacts without running Databricks CLI.
- Rollback mode (`rb-compile`): restores compile artifacts from backups.

Supported wrapped bundle operations:

- `deploy`
- `validate`
- `destroy`
- `summary`
- `deployment`
- `compile`
- `rb-compile`

Forwarding behavior:

- `dbx --help`: prints wrapper help, then forwards to `databricks --help`.
- `dbx <non-bundle-command> ...`: direct pass-through.
- `dbx bundle <unsupported-op> ...`: direct pass-through.
- `dbx bundle <supported-op> ...`: wrapper pipeline is executed.

Wrapper pipeline for supported ops (`deploy|validate|destroy|summary|deployment|compile|rb-compile`):

1. Validate YAML directives in `resources/**/*.yml`.
2. Apply YAML preprocessing for the selected target.
3. Run SQL interpolation for marked tasks.
4. If op is not `compile`/`rb-compile`, execute `databricks bundle <op> ...`.
5. For non-`compile` ops, rollback SQL interpolation only after successful Databricks bundle execution.

Compile and rollback behavior:

- `compile`:
  - skips Databricks CLI execution,
  - keeps preprocessed YAML and interpolated SQL in place,
  - keeps YAML backups as `*.TARGET.yamlpp.bak`,
  - SQL rollback is not performed.
- non-`compile` wrapped ops:
  - create runtime YAML backups as `*.TARGET.yamlpp.bak.<pid>`,
  - restore YAML backups on exit,
  - rollback SQL interpolation only on successful Databricks bundle execution.
- `rb-compile`:
  - skips Databricks CLI execution,
  - rolls back SQL from `*.TARGET.dab.bak` if present,
  - rolls back YAML from `*.TARGET.yamlpp.bak` if present.

Options and inputs:

- `-t|--target <target>`: required for wrapped bundle operations.
- `--verbose`: enables verbose wrapper output and passes `--verbose` to `databricks bundle`.
- `--bundle-root <path>`: Windows (`dbx.ps1`) only; sets bundle root (expects `databricks.yml` under that path).
- `BUNDLE_ROOT`: Linux/macOS (`dbx.sh`) bundle root (default `.`).
- `BUNDLE_FILE`: Linux/macOS (`dbx.sh`) bundle file path (default `<BUNDLE_ROOT>/databricks.yml`).

Prerequisites:

- `databricks` CLI must be installed and on `PATH`.
- `poetry` must be available.
- If wrapper `.venv` is missing, `dbx` auto-runs `install_deps.sh`/`install_deps.ps1` to bootstrap it.

## Release process

Release automation is configured in `.github/workflows/release.yml`.

When a tag like `v1.0.1` is pushed, the workflow publishes:
- `dbx-v1.0.1.tar.gz`
- `dbx-v1.0.1.zip`
- `SHA256SUMS`

Commands to publish `v1.0.1`:

```bash
git add .
git commit -m "prepare release v1.0.1"
git tag v1.0.1
git push origin v1.0.1
```

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

# RNMIF (target == 'prod') pipeline_new_name
pipeline_name:

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

`set-databricks-cli` installs, upgrades, downgrades, or reinstalls Databricks CLI binaries.

What it can do:

- Install a stable default CLI when no version is passed (penultimate semantic version; fallback to latest if needed).
- Install a specific version (`0.289.1` or `v0.289.1`).
- Skip work if current version already matches requested version.
- Upgrade to newer version and print changelog links.
- Downgrade by removing the current binary then installing target version.
- Ensure install directory is added to `PATH` in current session and persisted profile files.

Version resolution:

- If you pass a version argument, that version is used.
- If not passed, default stable semantic version is resolved (penultimate semantic version; fallback to latest if needed) from:
  - GitHub tags page (`databricks/cli/tags`), then
  - GitHub tags API fallback.

Platform behavior differences:

- Linux/macOS (`set_databricks_cli.sh`):
  - default install dir: `$HOME/.local/bin`,
  - ensures `unzip` is available (can auto-install with package manager),
  - supports `ALLOW_SUDO_INSTALL` for package installs.
- Windows (`set_databricks_cli.ps1`):
  - default install dir: `$HOME\.local\bin`,
  - supports `-Clean` for forced reinstall.

Parameters:

- Positional `version`:
  - `set-databricks-cli` -> default stable (penultimate semantic version; fallback to latest if needed).
  - `set-databricks-cli 0.289.1` -> exact version.
  - `set-databricks-cli v0.289.1` -> exact version (prefix normalized).
- Linux/macOS env vars:
  - `INSTALL_BIN_DIR`: install directory for `databricks` binary.
  - `ALLOW_SUDO_INSTALL`: `true`/`false` (default `true`) for dependency package install.
- Windows parameters/env:
  - `-InstallBinDir <path>` or env `INSTALL_BIN_DIR`.
  - `-Clean` to force reinstall even if version matches.

Examples:

```bash
set-databricks-cli
set-databricks-cli 0.289.1
INSTALL_BIN_DIR="$HOME/bin" set-databricks-cli
ALLOW_SUDO_INSTALL=false set-databricks-cli
```

```powershell
set-databricks-cli
set-databricks-cli 0.289.1
set-databricks-cli -InstallBinDir "$HOME\\bin"
set-databricks-cli -Clean
```
