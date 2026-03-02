#!/usr/bin/env bash
set -euo pipefail

# Setup script for the local Python environment required by
# scripts/sql_param_interpolator.py, managed with Poetry.
#
# What this script does:
# 1. Ensures Python is available (tries to install it if missing).
# 2. Ensures Poetry is available (installs it if missing).
# 3. Configures a local project virtualenv.
# 4. Installs project dependencies with Poetry.
#
# Usage:
#   ./install_deps.sh
#
# Optional environment variables:
#   PYTHON_VERSION      Python selector for the venv (default: 3).
#                       Example values: 3, 3.12, 3.13
#   PYTHON_BIN_OVERRIDE Absolute path to python interpreter.
#   VENV_DIR            Local virtual environment directory (default: .venv).
#   POETRY_VERSION      Optional Poetry version pin for installer.
#   ALLOW_SUDO_INSTALL  Allow using sudo for system package installs.
#                       Default: false (safer, non-privileged mode).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PYTHON_VERSION="${PYTHON_VERSION:-3}"
PYTHON_BIN_OVERRIDE="${PYTHON_BIN_OVERRIDE:-}"
VENV_DIR="${VENV_DIR:-.venv}"
POETRY_VERSION="${POETRY_VERSION:-}"
ALLOW_SUDO_INSTALL="${ALLOW_SUDO_INSTALL:-false}"

log() {
  echo "==> $*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_privileged() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
    return 0
  fi

  if [[ "$ALLOW_SUDO_INSTALL" == "true" ]] && command_exists sudo; then
    sudo "$@"
    return 0
  fi

  fail "System package installation requires privileges. Re-run as root, preinstall Python manually, or set ALLOW_SUDO_INSTALL=true."
}

resolve_python_bin() {
  if [[ -n "$PYTHON_BIN_OVERRIDE" ]]; then
    if [[ ! -x "$PYTHON_BIN_OVERRIDE" ]]; then
      fail "PYTHON_BIN_OVERRIDE points to a non-executable path: $PYTHON_BIN_OVERRIDE"
    fi
    echo "$PYTHON_BIN_OVERRIDE"
    return 0
  fi

  local candidate="python${PYTHON_VERSION}"
  if command_exists "$candidate"; then
    command -v "$candidate"
    return 0
  fi

  if command_exists python3; then
    command -v python3
    return 0
  fi

  return 1
}

install_python() {
  log "Python not found. Trying to install it with the system package manager."

  local python_pkg="python3"
  local venv_pkg="python3-venv"
  if [[ "$PYTHON_VERSION" != "3" ]]; then
    python_pkg="python${PYTHON_VERSION}"
    venv_pkg="python${PYTHON_VERSION}-venv"
  fi

  if command_exists apt-get; then
    run_privileged apt-get update
    run_privileged apt-get install -y "$python_pkg" "$venv_pkg" || run_privileged apt-get install -y python3 python3-venv
    return 0
  fi

  if command_exists dnf; then
    run_privileged dnf install -y "$python_pkg" || run_privileged dnf install -y python3
    return 0
  fi

  if command_exists yum; then
    run_privileged yum install -y "$python_pkg" || run_privileged yum install -y python3
    return 0
  fi

  if command_exists zypper; then
    run_privileged zypper --non-interactive install "$python_pkg" || run_privileged zypper --non-interactive install python3
    return 0
  fi

  if command_exists pacman; then
    run_privileged pacman -Sy --noconfirm python
    return 0
  fi

  if command_exists brew; then
    brew install python@"$PYTHON_VERSION" || brew install python
    return 0
  fi

  fail "Unsupported OS/package manager. Install Python manually and re-run this script."
}

ensure_python() {
  if PYTHON_BIN="$(resolve_python_bin)"; then
    log "Using Python interpreter: $PYTHON_BIN"
    return 0
  fi

  install_python

  if PYTHON_BIN="$(resolve_python_bin)"; then
    log "Using Python interpreter: $PYTHON_BIN"
    return 0
  fi

  fail "Python installation finished but no suitable interpreter was found in PATH."
}

install_poetry() {
  log "Poetry not found. Installing Poetry for current user."

  if ! command_exists curl && ! command_exists wget; then
    fail "Poetry installer requires curl or wget. Install one of them and retry."
  fi

  "$PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1 || true

  if command_exists curl; then
    if [[ -n "$POETRY_VERSION" ]]; then
      curl -sSL https://install.python-poetry.org | POETRY_VERSION="$POETRY_VERSION" "$PYTHON_BIN" -
    else
      curl -sSL https://install.python-poetry.org | "$PYTHON_BIN" -
    fi
  else
    if [[ -n "$POETRY_VERSION" ]]; then
      wget -qO- https://install.python-poetry.org | POETRY_VERSION="$POETRY_VERSION" "$PYTHON_BIN" -
    else
      wget -qO- https://install.python-poetry.org | "$PYTHON_BIN" -
    fi
  fi

  export PATH="$HOME/.local/bin:$PATH"
  command_exists poetry || fail "Poetry installation did not produce a usable 'poetry' command."
}

ensure_poetry() {
  if command_exists poetry; then
    log "Poetry detected: $(command -v poetry)"
    return 0
  fi

  install_poetry
  log "Poetry installed: $(command -v poetry)"
}

ensure_poetry_non_package_mode() {
  local pyproject_file="${SCRIPT_DIR}/pyproject.toml"
  [[ -f "$pyproject_file" ]] || fail "pyproject.toml not found at ${pyproject_file}"

  if awk '
    BEGIN { in_section=0; ok=0 }
    /^\[tool\.poetry\]/ { in_section=1; next }
    /^\[.*\]/ { if (in_section) in_section=0 }
    in_section && /^[[:space:]]*package-mode[[:space:]]*=[[:space:]]*false([[:space:]]*#.*)?$/ { ok=1 }
    END { exit ok ? 0 : 1 }
  ' "$pyproject_file"; then
    return 0
  fi

  local tmp_file
  tmp_file="$(mktemp)"

  if grep -q '^\[tool\.poetry\]' "$pyproject_file"; then
    awk '
      BEGIN { in_section=0; inserted=0 }
      /^\[tool\.poetry\]/ {
        print
        in_section=1
        next
      }
      in_section && /^\[.*\]/ {
        if (!inserted) {
          print "package-mode = false"
          inserted=1
        }
        in_section=0
      }
      in_section && /^[[:space:]]*package-mode[[:space:]]*=/ {
        if (!inserted) {
          print "package-mode = false"
          inserted=1
        }
        next
      }
      { print }
      END {
        if (in_section && !inserted) {
          print "package-mode = false"
        }
      }
    ' "$pyproject_file" > "$tmp_file"
  else
    cat "$pyproject_file" > "$tmp_file"
    printf "\n[tool.poetry]\npackage-mode = false\n" >> "$tmp_file"
  fi

  mv "$tmp_file" "$pyproject_file"
  log "Configured Poetry with package-mode = false in pyproject.toml"
}

configure_local_venv() {
  local desired_venv="${SCRIPT_DIR}/${VENV_DIR}"

  if [[ "$VENV_DIR" != ".venv" ]]; then
    mkdir -p "$desired_venv"
    ln -sfn "$desired_venv" "${SCRIPT_DIR}/.venv"
    log "Linked .venv -> ${desired_venv}"
  fi

  export POETRY_VIRTUALENVS_IN_PROJECT=true
  log "Configuring Poetry local virtualenv at ${desired_venv}"
  poetry env use "$PYTHON_BIN"
}

main() {
  ensure_python
  ensure_poetry
  ensure_poetry_non_package_mode
  configure_local_venv

  log "Installing project dependencies from pyproject.toml with Poetry"
  poetry install --no-root --only main --no-interaction

  log "Setup complete"
  echo "Run with: poetry run python scripts/sql_param_interpolator.py --help"
}

main "$@"
