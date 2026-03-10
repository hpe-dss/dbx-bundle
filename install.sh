#!/usr/bin/env bash
set -euo pipefail

# Install or update the dbx CLI wrapper in ~/scripts/dbx.
# The wrapper includes its own local Python virtual environment managed by Poetry.
#
# Usage:
#   ./install.sh [databricks_cli_version]
#
# Optional environment variables:
#   INSTALL_DIR      Destination directory for the wrapper
#                    (default: $HOME/scripts/dbx)
#   PYTHON_VERSION   Python selector passed to the wrapper install_deps.sh
#                    (default: 3)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/scripts/dbx}"
TARGET_SCRIPTS_DIR="${INSTALL_DIR}/scripts"
BASHRC_FILE="${HOME}/.bashrc"
PYTHON_VERSION="${PYTHON_VERSION:-3}"
BASHRC_BLOCK_START="# >>> dbx wrapper >>>"
BASHRC_BLOCK_END="# <<< dbx wrapper <<<"
DATABRICKS_CLI_VERSION="${1:-}"

if [[ $# -gt 1 ]]; then
  echo "Error: usage: ./install.sh [databricks_cli_version]" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$TARGET_SCRIPTS_DIR"

copy_file() {
  local src="$1"
  local dst="$2"
  [[ -f "$src" ]] || {
    echo "Error: source file not found: $src" >&2
    exit 1
  }
  cp -f "$src" "$dst"
}

copy_file "${SCRIPT_DIR}/dbx.sh" "${INSTALL_DIR}/dbx.sh"
copy_file "${SCRIPT_DIR}/set_databricks_cli.sh" "${INSTALL_DIR}/set_databricks_cli.sh"
copy_file "${SCRIPT_DIR}/install_deps.sh" "${INSTALL_DIR}/install_deps.sh"
copy_file "${SCRIPT_DIR}/pyproject.toml" "${INSTALL_DIR}/pyproject.toml"
copy_file "${SCRIPT_DIR}/README.md" "${INSTALL_DIR}/README.md"
copy_file "${SCRIPT_DIR}/INSTALL.md" "${INSTALL_DIR}/INSTALL.md"
copy_file "${SCRIPT_DIR}/scripts/yaml_comments_preprocessor.py" "${TARGET_SCRIPTS_DIR}/yaml_comments_preprocessor.py"
copy_file "${SCRIPT_DIR}/scripts/sql_param_interpolator.py" "${TARGET_SCRIPTS_DIR}/sql_param_interpolator.py"

chmod +x "${INSTALL_DIR}/dbx.sh"
chmod +x "${INSTALL_DIR}/set_databricks_cli.sh"
chmod +x "${INSTALL_DIR}/install_deps.sh"

(
  cd "$INSTALL_DIR"
  if [[ -n "$DATABRICKS_CLI_VERSION" ]]; then
    ./set_databricks_cli.sh "$DATABRICKS_CLI_VERSION"
  else
    ./set_databricks_cli.sh
  fi
  PYTHON_VERSION="$PYTHON_VERSION" ./install_deps.sh
)

if [[ ! -f "$BASHRC_FILE" ]]; then
  touch "$BASHRC_FILE"
fi

if grep -qF "$BASHRC_BLOCK_START" "$BASHRC_FILE"; then
  sed -i "/$BASHRC_BLOCK_START/,/$BASHRC_BLOCK_END/d" "$BASHRC_FILE"
fi

cat >> "$BASHRC_FILE" <<BASHRC_SNIPPET

$BASHRC_BLOCK_START
dbx() {
  local script_path="${INSTALL_DIR}/dbx.sh"

  [[ -f "\$script_path" ]] || {
    echo "Error: dbx wrapper not found at \$script_path" >&2
    return 1
  }

  if [[ ! -x "\$script_path" ]]; then
    chmod +x "\$script_path" || {
      echo "Error: cannot set execute permission on \$script_path" >&2
      return 1
    }
  fi

  "\$script_path" "\$@"
}

set-databricks-cli() {
  local script_path="${INSTALL_DIR}/set_databricks_cli.sh"

  [[ -f "\$script_path" ]] || {
    echo "Error: set-databricks-cli script not found at \$script_path" >&2
    return 1
  }

  if [[ ! -x "\$script_path" ]]; then
    chmod +x "\$script_path" || {
      echo "Error: cannot set execute permission on \$script_path" >&2
      return 1
    }
  fi

  "\$script_path" "\$@"
}
$BASHRC_BLOCK_END
BASHRC_SNIPPET

echo "Wrapper installed/updated at: ${INSTALL_DIR}"
echo "Open a new shell or run: source ${BASHRC_FILE}"
echo "Then use: dbx bundle validate -t <target>"
