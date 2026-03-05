#!/usr/bin/env bash
set -euo pipefail

# Remote bootstrap installer for dbx wrapper.
# Downloads a tagged release package, verifies SHA-256 checksum,
# and executes install.sh from that package.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/hpe-dss/dbx-bundle/v1.0.0/install-remote.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/hpe-dss/dbx-bundle/v1.0.0/install-remote.sh | bash -s -- 0.291.0
#
# Optional env vars:
#   DBX_REPO            GitHub repo in owner/name format (default: hpe-dss/dbx-bundle).
#   DBX_RELEASE_VERSION Git release tag (default: v1.0.0).

DBX_REPO="${DBX_REPO:-hpe-dss/dbx-bundle}"
DBX_RELEASE_VERSION="${DBX_RELEASE_VERSION:-v1.0.0}"
DATABRICKS_CLI_VERSION="${1:-}"

if [[ $# -gt 1 ]]; then
  echo "Error: usage: install-remote.sh [databricks_cli_version]" >&2
  exit 1
fi

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

file_sha256() {
  local file_path="$1"
  if command_exists sha256sum; then
    sha256sum "$file_path" | awk '{print $1}'
    return 0
  fi
  if command_exists shasum; then
    shasum -a 256 "$file_path" | awk '{print $1}'
    return 0
  fi
  if command_exists openssl; then
    openssl dgst -sha256 "$file_path" | awk '{print $NF}'
    return 0
  fi
  fail "No SHA-256 tool found. Install sha256sum, shasum, or openssl."
}

http_get_to_file() {
  local url="$1"
  local out_file="$2"
  if command_exists curl; then
    curl -fsSL "$url" -o "$out_file"
  elif command_exists wget; then
    wget -qO "$out_file" "$url"
  else
    fail "curl or wget is required."
  fi
}

command_exists tar || fail "tar is required."

if [[ "$DBX_RELEASE_VERSION" != v* ]]; then
  DBX_RELEASE_VERSION="v${DBX_RELEASE_VERSION}"
fi

release_base_url="https://github.com/${DBX_REPO}/releases/download/${DBX_RELEASE_VERSION}"
archive_name="dbx-${DBX_RELEASE_VERSION}.tar.gz"
checksums_name="SHA256SUMS"
archive_url="${release_base_url}/${archive_name}"
checksums_url="${release_base_url}/${checksums_name}"

tmp_dir="$(mktemp -d)"
archive_path="${tmp_dir}/${archive_name}"
checksums_path="${tmp_dir}/${checksums_name}"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

echo "==> Downloading ${DBX_REPO} ${DBX_RELEASE_VERSION}"
http_get_to_file "$archive_url" "$archive_path"
http_get_to_file "$checksums_url" "$checksums_path"

echo "==> Verifying SHA-256 checksum"
expected_sha="$(awk -v f="$archive_name" '$2 == f { print $1 }' "$checksums_path" | head -n1)"
[[ -n "$expected_sha" ]] || fail "Expected checksum for ${archive_name} was not found in ${checksums_name}."
actual_sha="$(file_sha256 "$archive_path")"
[[ "$actual_sha" == "$expected_sha" ]] || fail "Checksum verification failed for ${archive_name}."

echo "==> Extracting package"
tar -xzf "$archive_path" -C "$tmp_dir"

extract_dir="${tmp_dir}/dbx-${DBX_RELEASE_VERSION}"
if [[ ! -d "$extract_dir" ]]; then
  extract_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
fi
[[ -n "$extract_dir" ]] || fail "Could not locate extracted directory."

install_script="${extract_dir}/install.sh"
[[ -f "$install_script" ]] || fail "install.sh not found inside downloaded package."
chmod +x "$install_script"

echo "==> Running installer from ${DBX_RELEASE_VERSION}"
if [[ -n "$DATABRICKS_CLI_VERSION" ]]; then
  "$install_script" "$DATABRICKS_CLI_VERSION"
else
  "$install_script"
fi
