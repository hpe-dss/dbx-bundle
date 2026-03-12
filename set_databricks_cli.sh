#!/usr/bin/env bash
set -euo pipefail

# Set up Databricks CLI (install, upgrade, or downgrade).
#
# Version resolution strategy:
# 1) First positional argument (if provided)
# 2) Default stable semantic tag from https://github.com/databricks/cli/tags:
#    penultimate stable version (fallback to latest if fewer than 2 versions)
#    and fallback to GitHub tags API if needed.
#
# Optional environment variables:
#   INSTALL_BIN_DIR         Destination directory for databricks binary
#                           (default: $HOME/.local/bin)
#   ALLOW_SUDO_INSTALL      Allow sudo for package installation (default: true)

TAGS_URL="https://github.com/databricks/cli/tags"
GITHUB_TAGS_API_URL="https://api.github.com/repos/databricks/cli/tags?per_page=100"
INSTALL_BIN_DIR="${INSTALL_BIN_DIR:-$HOME/.local/bin}"
REQUESTED_VERSION="${1:-}"
PATH_BLOCK_START="# >>> databricks cli path >>>"
PATH_BLOCK_END="# <<< databricks cli path <<<"
ALLOW_SUDO_INSTALL="${ALLOW_SUDO_INSTALL:-true}"

log() {
  echo "==> $*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

if [[ $# -gt 1 ]]; then
  fail "Usage: $0 [version]"
fi

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

  fail "Installing system packages requires privileges. Re-run as root or allow sudo with ALLOW_SUDO_INSTALL=true."
}

ensure_download_tool() {
  command_exists curl || command_exists wget || fail "curl or wget is required."
}

http_get() {
  local url="$1"
  if command_exists curl; then
    curl -fsSL "$url"
  else
    wget -qO- "$url"
  fi
}

normalize_version() {
  local v="$1"
  v="${v#v}"
  printf "%s" "$v"
}

resolve_latest_version_from_tags_page() {
  # Pick the penultimate stable semantic version (fallback to latest if needed).
  http_get "$TAGS_URL" \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
    | sed 's/^v//' \
    | sort -Vr \
    | awk '!seen[$0]++' \
    | awk 'NR==2 { print; found=1; exit } END { if (!found && NR>=1) print $1 }'
}

resolve_latest_version_from_api() {
  http_get "$GITHUB_TAGS_API_URL" \
    | grep -oE '"name"[[:space:]]*:[[:space:]]*"v[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
    | sed 's/^v//' \
    | sort -Vr \
    | awk '!seen[$0]++' \
    | awk 'NR==2 { print; found=1; exit } END { if (!found && NR>=1) print $1 }'
}

resolve_target_version() {
  if [[ -n "$REQUESTED_VERSION" ]]; then
    normalize_version "$REQUESTED_VERSION"
    return 0
  fi

  local selected_version=""
  selected_version="$(resolve_latest_version_from_tags_page || true)"
  if [[ -z "$selected_version" ]]; then
    selected_version="$(resolve_latest_version_from_api || true)"
  fi
  [[ -n "$selected_version" ]] || fail "Could not resolve default Databricks CLI version from tags."
  printf "%s" "$selected_version"
}

detect_os() {
  case "$(uname -s)" in
    Linux) printf "linux" ;;
    Darwin) printf "darwin" ;;
    MINGW*|MSYS*|CYGWIN*) printf "windows" ;;
    *) fail "Unsupported OS: $(uname -s)" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf "amd64" ;;
    aarch64|arm64) printf "arm64" ;;
    *) fail "Unsupported architecture: $(uname -m)" ;;
  esac
}

installed_version() {
  if ! command_exists databricks; then
    return 0
  fi

  # Common outputs include:
  # - "Databricks CLI v0.289.1"
  # - "0.289.1"
  (databricks version 2>/dev/null || databricks -v 2>/dev/null || true) \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | head -n1
}

ensure_unzip() {
  if command_exists unzip; then
    return 0
  fi

  log "unzip not found. Trying to install it with the system package manager."

  if command_exists apt-get; then
    run_privileged apt-get update
    run_privileged apt-get install -y unzip
    return 0
  fi

  if command_exists dnf; then
    run_privileged dnf install -y unzip
    return 0
  fi

  if command_exists yum; then
    run_privileged yum install -y unzip
    return 0
  fi

  if command_exists zypper; then
    run_privileged zypper --non-interactive install unzip
    return 0
  fi

  if command_exists pacman; then
    run_privileged pacman -Sy --noconfirm unzip
    return 0
  fi

  if command_exists brew; then
    brew install unzip
    return 0
  fi

  fail "Could not install unzip automatically. Install it manually and re-run."
}

persist_path_in_file() {
  local rc_file="$1"
  local path_line="$2"

  if [[ ! -f "$rc_file" ]]; then
    touch "$rc_file"
  fi

  if grep -qF "$PATH_BLOCK_START" "$rc_file"; then
    sed -i "/$PATH_BLOCK_START/,/$PATH_BLOCK_END/d" "$rc_file"
  fi

  cat >> "$rc_file" <<EOF

$PATH_BLOCK_START
$path_line
$PATH_BLOCK_END
EOF
}

ensure_cli_on_path() {
  local path_line
  path_line="export PATH=\"${INSTALL_BIN_DIR}:\$PATH\""

  case ":$PATH:" in
    *":${INSTALL_BIN_DIR}:"*) ;;
    *) export PATH="${INSTALL_BIN_DIR}:$PATH" ;;
  esac

  persist_path_in_file "$HOME/.bashrc" "$path_line"
  persist_path_in_file "$HOME/.zshrc" "$path_line"
  persist_path_in_file "$HOME/.profile" "$path_line"

  log "PATH updated to include ${INSTALL_BIN_DIR} (current shell and future sessions)."
}

uninstall_current_cli() {
  local current_bin
  current_bin="$(command -v databricks || true)"
  [[ -n "$current_bin" ]] || return 0

  log "Removing current Databricks CLI binary at ${current_bin}"
  rm -f "$current_bin" || fail "Could not remove current Databricks CLI at ${current_bin}."
}

version_lt() {
  [[ "$1" != "$2" ]] && [[ "$(printf "%s\n%s\n" "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

version_gt() {
  version_lt "$2" "$1"
}

version_le() {
  [[ "$1" == "$2" ]] || version_lt "$1" "$2"
}

version_ge() {
  [[ "$1" == "$2" ]] || version_gt "$1" "$2"
}

print_changelog() {
  local from_version="$1"
  local to_version="$2"
  local versions_between line

  [[ -n "$from_version" ]] || return 0
  [[ "$from_version" != "$to_version" ]] || return 0

  log "Databricks CLI changelog: v${from_version} -> v${to_version}"
  echo "Compare changes: https://github.com/databricks/cli/compare/v${from_version}...v${to_version}"

  # Re-fetch all visible semantic versions so we can list relevant release-note pages.
  versions_between="$(http_get "$GITHUB_TAGS_API_URL" \
    | grep -oE '"name"[[:space:]]*:[[:space:]]*"v[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
    | sed 's/^v//' \
    | sort -V)"

  [[ -n "$versions_between" ]] || return 0

  echo "Release notes in range:"
  if version_lt "$from_version" "$to_version"; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if version_gt "$line" "$from_version" && version_le "$line" "$to_version"; then
        echo "  - v${line}: https://github.com/databricks/cli/releases/tag/v${line}"
      fi
    done <<< "$versions_between"
  else
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if version_ge "$line" "$to_version" && version_lt "$line" "$from_version"; then
        echo "  - v${line}: https://github.com/databricks/cli/releases/tag/v${line}"
      fi
    done <<< "$(printf "%s\n" "$versions_between" | sort -Vr)"
  fi
}

install_or_update_cli() {
  ensure_download_tool
  ensure_unzip

  local target_version current_version os arch release_url tmpdir archive_path extracted_bin should_show_changelog

  target_version="$(resolve_target_version)"
  current_version="$(installed_version || true)"
  os="$(detect_os)"
  arch="$(detect_arch)"
  should_show_changelog=false

  if [[ -z "$REQUESTED_VERSION" ]]; then
    log "No Databricks CLI version was provided. Using default stable version v${target_version} (penultimate semantic tag, fallback to latest if needed)."
  fi

  ensure_cli_on_path

  if [[ -n "$current_version" && "$current_version" == "$target_version" ]]; then
    log "Databricks CLI already at requested version (v${current_version}). No changes needed."
    return 0
  fi

  if [[ -n "$current_version" ]] && version_lt "$current_version" "$target_version"; then
    should_show_changelog=true
  fi

  if [[ -n "$current_version" ]] && version_gt "$current_version" "$target_version"; then
    # Explicit downgrade path: remove current binary first, then install target.
    uninstall_current_cli
  fi

  release_url="https://github.com/databricks/cli/releases/download/v${target_version}/databricks_cli_${target_version}_${os}_${arch}.zip"

  log "Installing Databricks CLI v${target_version} for ${os}/${arch}"
  tmpdir="$(mktemp -d)"
  archive_path="${tmpdir}/databricks_cli.zip"

  if command_exists curl; then
    curl -fL "$release_url" -o "$archive_path"
  else
    wget -O "$archive_path" "$release_url"
  fi

  unzip -q "$archive_path" -d "$tmpdir"
  extracted_bin="${tmpdir}/databricks"
  [[ -f "$extracted_bin" ]] || fail "Downloaded archive did not contain databricks binary."

  mkdir -p "$INSTALL_BIN_DIR"
  install -m 0755 "$extracted_bin" "${INSTALL_BIN_DIR}/databricks"
  log "Databricks CLI installed at ${INSTALL_BIN_DIR}/databricks"

  if [[ "$should_show_changelog" == "true" ]]; then
    print_changelog "$current_version" "$target_version"
  fi

  rm -rf "$tmpdir"
}

install_or_update_cli
