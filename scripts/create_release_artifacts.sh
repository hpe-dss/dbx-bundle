#!/usr/bin/env bash
set -euo pipefail

# Build release archives and checksums for a version tag.
#
# Usage:
#   ./scripts/create_release_artifacts.sh v1.0.0

RELEASE_TAG="${1:-}"

if [[ -z "$RELEASE_TAG" ]]; then
  echo "Error: usage: ./scripts/create_release_artifacts.sh <tag>" >&2
  echo "Example: ./scripts/create_release_artifacts.sh v1.0.0" >&2
  exit 1
fi

if [[ "$RELEASE_TAG" != v* ]]; then
  RELEASE_TAG="v${RELEASE_TAG}"
fi

if [[ ! "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: tag must follow semantic version format v<major>.<minor>.<patch>" >&2
  exit 1
fi

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

create_zip() {
  local src_root="$1"
  local destination_zip="$2"
  local folder_name="$3"

  if command_exists zip; then
    ( cd "$src_root" && zip -qr "$destination_zip" "$folder_name" )
    return 0
  fi

  if command_exists python3; then
    (
      cd "$src_root"
      python3 - "$destination_zip" "$folder_name" <<'PY'
import os
import sys
import zipfile

dest_zip = sys.argv[1]
base_folder = sys.argv[2]

with zipfile.ZipFile(dest_zip, "w", zipfile.ZIP_DEFLATED) as archive:
    for root, _, files in os.walk(base_folder):
        for file_name in files:
            path = os.path.join(root, file_name)
            archive.write(path, path)
PY
    )
    return 0
  fi

  fail "zip or python3 is required."
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
STAGE_ROOT="$(mktemp -d)"
PACKAGE_ROOT_NAME="dbx-${RELEASE_TAG}"
PACKAGE_ROOT="${STAGE_ROOT}/${PACKAGE_ROOT_NAME}"
TAR_FILE="${DIST_DIR}/${PACKAGE_ROOT_NAME}.tar.gz"
ZIP_FILE="${DIST_DIR}/${PACKAGE_ROOT_NAME}.zip"
CHECKSUMS_FILE="${DIST_DIR}/SHA256SUMS"

cleanup() {
  rm -rf "$STAGE_ROOT"
}
trap cleanup EXIT INT TERM

command_exists tar || fail "tar is required."

REQUIRED_FILES=(
  "README.md"
  "dbx.sh"
  "dbx.ps1"
  "install.sh"
  "install.ps1"
  "install-remote.sh"
  "install-remote.ps1"
  "install_deps.sh"
  "install_deps.ps1"
  "set_databricks_cli.sh"
  "set_databricks_cli.ps1"
  "pyproject.toml"
  "scripts/yaml_comments_preprocessor.py"
  "scripts/sql_param_interpolator.py"
)

OPTIONAL_FILES=(
  "poetry.lock"
)

mkdir -p "$PACKAGE_ROOT"

for rel_path in "${REQUIRED_FILES[@]}"; do
  src_path="${REPO_ROOT}/${rel_path}"
  [[ -f "$src_path" ]] || fail "Required file not found: ${rel_path}"
  dst_path="${PACKAGE_ROOT}/${rel_path}"
  mkdir -p "$(dirname "$dst_path")"
  cp "$src_path" "$dst_path"
done

for rel_path in "${OPTIONAL_FILES[@]}"; do
  src_path="${REPO_ROOT}/${rel_path}"
  if [[ -f "$src_path" ]] && git -C "$REPO_ROOT" ls-files --error-unmatch "$rel_path" >/dev/null 2>&1; then
    dst_path="${PACKAGE_ROOT}/${rel_path}"
    mkdir -p "$(dirname "$dst_path")"
    cp "$src_path" "$dst_path"
  fi
done

chmod +x \
  "${PACKAGE_ROOT}/dbx.sh" \
  "${PACKAGE_ROOT}/install.sh" \
  "${PACKAGE_ROOT}/install-remote.sh" \
  "${PACKAGE_ROOT}/install_deps.sh" \
  "${PACKAGE_ROOT}/set_databricks_cli.sh"

mkdir -p "$DIST_DIR"
rm -f "$TAR_FILE" "$ZIP_FILE" "$CHECKSUMS_FILE"

tar -czf "$TAR_FILE" -C "$STAGE_ROOT" "$PACKAGE_ROOT_NAME"
create_zip "$STAGE_ROOT" "$ZIP_FILE" "$PACKAGE_ROOT_NAME"

{
  printf "%s  %s\n" "$(file_sha256 "$TAR_FILE")" "$(basename "$TAR_FILE")"
  printf "%s  %s\n" "$(file_sha256 "$ZIP_FILE")" "$(basename "$ZIP_FILE")"
} > "$CHECKSUMS_FILE"

echo "Created release artifacts:"
echo "  - $TAR_FILE"
echo "  - $ZIP_FILE"
echo "  - $CHECKSUMS_FILE"
