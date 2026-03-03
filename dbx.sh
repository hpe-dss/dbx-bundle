#!/usr/bin/env bash
set -euo pipefail

# dbx wrapper for Databricks CLI.
# Purpose:
# - Validate and preprocess YAML resources with comment directives.
# - Interpolate SQL parameters for tasks marked for interpolation.
# - Execute databricks bundle operations.
# - Roll back SQL interpolation only after successful bundle execution.
# - Support a compile-only mode that leaves preprocessed files in place.

ALLOWED_OPS=( 'deploy' 'validate' 'destroy' 'summary' 'deployment' 'compile' )
ORIGINAL_ARGS=("$@")

# If subcommand is not "bundle", forward everything to Databricks CLI.
if [[ "${1:-}" != "bundle" ]]; then
    exec databricks "${ORIGINAL_ARGS[@]}"
    exit 0
fi
shift

# If "bundle" doesn't include a supported operation, forward to Databricks CLI.
SUPPORTED_BUNDLE_OP=false
for arg in "$@"; do
    [[ "$arg" == "--" ]] && break
    [[ "$arg" == -* ]] && continue
    for allowed_op in "${ALLOWED_OPS[@]}"; do
        if [[ "$arg" == "$allowed_op" ]]; then
            SUPPORTED_BUNDLE_OP=true
            break 2
        fi
    done
done
if [[ "$SUPPORTED_BUNDLE_OP" != "true" ]]; then
    exec databricks "${ORIGINAL_ARGS[@]}"
    exit 0
fi

TARGET=""
OP=""
WRAPPER_VERBOSE=false
FULL_VERBOSE=false
ROLLBACK_ONLY=false
CLI_ARGS=()

WRAPPER_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="${BUNDLE_ROOT:-.}"
BUNDLE_FILE="${BUNDLE_FILE:-${BUNDLE_ROOT}/databricks.yml}"
RESOURCES_FOLDER="${BUNDLE_ROOT}/resources"
YAML_PREPROCESSOR_SCRIPT="${WRAPPER_HOME}/scripts/yaml_comments_preprocessor.py"
SQL_INTERPOLATOR_SCRIPT="${WRAPPER_HOME}/scripts/sql_param_interpolator.py"
WRAPPER_VENV_PYTHON="${WRAPPER_HOME}/.venv/bin/python"
WRAPPER_INSTALL_SCRIPT="${WRAPPER_HOME}/install_deps.sh"

print_help() {
    cat <<'EOF'
dbx.sh - Databricks bundle wrapper with YAML preprocessing and SQL interpolation

Usage:
  dbx.sh bundle <operation> -t <target> [wrapper options] [-- <databricks bundle options>]
  dbx.sh bundle -t <target> --w-rollback
  dbx.sh bundle --w-help
  dbx.sh <any-non-bundle-databricks-subcommand> [args...]

Supported operations:
  deploy, validate, destroy, summary, deployment, compile

What this wrapper does:
  1) Validates YAML comment directives in bundle resource YAML files.
  2) Applies YAML preprocessing for the selected target.
  3) Runs SQL parameter interpolation for the selected target.
  4) For non-compile ops, executes `databricks bundle <operation> ...`.
  5) For non-compile ops, if successful, runs SQL rollback to restore original SQL files.
  6) For `compile`, it skips Databricks CLI and keeps preprocessed YAML/SQL files.

Options:
  --w-verbose            Show detailed output only for wrapper steps.
  --verbose              Show detailed output for wrapper + databricks bundle.
  --w-rollback           Wrapper-only mode: YAML preprocess + SQL rollback, no bundle execution.
  --w-help               Show this help message.
  BUNDLE_ROOT            Bundle root path (default: current directory).
  BUNDLE_FILE            Bundle file path (default: <BUNDLE_ROOT>/databricks.yml).

Compatibility aliases (legacy):
  -t, --target, --verbose, --rollback

Pass-through to Databricks CLI:
  Use `--` to pass the rest directly to `databricks bundle`, avoiding flag overlaps.

Examples:
  dbx.sh bundle validate -t dev
  dbx.sh bundle deploy -t prod -- --var release_id=2026_02_25
  dbx.sh bundle -t local --w-rollback
  dbx.sh fs ls dbfs:/
EOF
}

in_list() {
    local tgt="$1"
    shift
    for item in "$@"; do
        [[ "$item" == "$tgt" ]] && return 0
    done
    return 1
}

run_python() {
    local helper_script="$1"
    shift
    (
      cd "$WRAPPER_HOME"
      poetry run python "$helper_script" "$@"
    )
}

run_bundle_cli() {
    (
      cd "$BUNDLE_ROOT"
      databricks bundle "$@"
    )
}

should_print_step_logs() {
    local verbosity_scope="$1"
    case "$verbosity_scope" in
        wrapper)
            [[ "$WRAPPER_VERBOSE" == "true" ]]
            ;;
        full)
            [[ "$FULL_VERBOSE" == "true" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

print_failure_log() {
    local step_description="$1"
    local log_file="$2"
    echo "Error: ${step_description}" >&2
    echo "---- detailed output ----" >&2
    cat "$log_file" >&2
    echo "------------------------" >&2
}

run_step() {
    local step_description="$1"
    local verbosity_scope="$2"
    shift
    shift
    local cmd=("$@")
    local log_file
    local cmd_status=0
    log_file="$(mktemp)"

    "${cmd[@]}" >"$log_file" 2>&1 || cmd_status=$?

    if [[ $cmd_status -ne 0 ]]; then
        print_failure_log "$step_description" "$log_file"
        rm -f "$log_file"
        exit 1
    fi

    if should_print_step_logs "$verbosity_scope"; then
        cat "$log_file"
    fi

    rm -f "$log_file"
}

ensure_wrapper_virtual_environment() {
    if [[ -x "$WRAPPER_VENV_PYTHON" ]]; then
        return 0
    fi

    [[ -x "$WRAPPER_INSTALL_SCRIPT" ]] || {
        echo "Error: wrapper install script not found at $WRAPPER_INSTALL_SCRIPT" >&2
        exit 1
    }

    echo ">> Wrapper virtual environment not found. Bootstrapping with poetry."
    "$WRAPPER_INSTALL_SCRIPT"
}


while [[ $# -gt 0 ]]; do
  case "$1" in
    --w-help)
      print_help
      exit 0
      ;;
    --verbose|--w-verbose)
      if [[ "$1" == "--verbose" ]]; then
        FULL_VERBOSE=true
        WRAPPER_VERBOSE=true
      else
        WRAPPER_VERBOSE=true
      fi
      shift
      ;;
    --rollback|--w-rollback)
      ROLLBACK_ONLY=true
      shift
      ;;
    -t|--target)
      [[ $# -lt 2 ]] && { echo "Error: -t|--target requires a value" >&2; exit 1; }
      TARGET="$2"
      shift 2
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        CLI_ARGS+=("$1")
        shift
      done
      break
      ;;
    *)
      if in_list "$1" "${ALLOWED_OPS[@]}" ; then 
        OP=$1
      fi
      CLI_ARGS+=("$1")
      shift
      ;;
  esac
done

[[ -z "$TARGET" ]] && { echo "Error: you must give arg -t|--target <value>" >&2; exit 1; }
if [[ "$ROLLBACK_ONLY" != "true" ]]; then
    [[ -z "$OP" ]] && { echo "Error: you must give a valid operation argument" >&2; exit 1; }
fi
[[ -f "$BUNDLE_FILE" ]] || { echo "Error: bundle file not found at $BUNDLE_FILE" >&2; exit 1; }
[[ -f "$YAML_PREPROCESSOR_SCRIPT" ]] || { echo "Error: yaml preprocessor script not found at $YAML_PREPROCESSOR_SCRIPT" >&2; exit 1; }
[[ -f "$SQL_INTERPOLATOR_SCRIPT" ]] || { echo "Error: SQL interpolator script not found at $SQL_INTERPOLATOR_SCRIPT" >&2; exit 1; }
command -v poetry >/dev/null 2>&1 || { echo "Error: poetry is required but not installed. Run ${WRAPPER_INSTALL_SCRIPT} first." >&2; exit 1; }

ensure_wrapper_virtual_environment


declare -A BACKUPS=()
KEEP_PREPROCESSED_FILES=false
if [[ "$OP" == "compile" ]]; then
    KEEP_PREPROCESSED_FILES=true
fi
restore() {
    if [[ "$KEEP_PREPROCESSED_FILES" == "true" ]]; then
        return 0
    fi
    for f in "${!BACKUPS[@]}"; do
        mv -f "${BACKUPS[$f]}" "$f"
    done
}
trap restore EXIT INT TERM

if [[ -d "$RESOURCES_FOLDER" ]]; then

    echo ">> Validating YAML directives for target: $TARGET"
    while IFS= read -r -d '' yml; do
        run_step "comment directives validation failed in $yml" \
            wrapper \
            run_python "$YAML_PREPROCESSOR_SCRIPT" --check -i "$yml" -t "$TARGET"
    done < <(find "$RESOURCES_FOLDER" -type f -name '*.yml' -print0)

    echo ">> Applying YAML preprocessing for target: $TARGET"
    while IFS= read -r -d '' yml; do
        if [[ "$KEEP_PREPROCESSED_FILES" != "true" ]]; then
            bak="${yml%.yml}.bak.$$"
            cp "$yml" "$bak"
            BACKUPS["$yml"]="$bak"
        fi
        run_step "YAML preprocessing failed in $yml" \
            wrapper \
            run_python "$YAML_PREPROCESSOR_SCRIPT" -t "$TARGET" -i "$yml" -o "$yml"
    done < <(find "$RESOURCES_FOLDER" -type f -name '*.yml' -print0)

    if [[ "$ROLLBACK_ONLY" == "true" ]]; then
        echo ">> Wrapper rollback mode enabled: skipping Databricks bundle execution."
        echo ">> Rolling back interpolated SQL files for target: $TARGET"
        run_step "SQL rollback failed for target '$TARGET'" \
            wrapper \
            run_python "$SQL_INTERPOLATOR_SCRIPT" "$TARGET" --bundle-file "$BUNDLE_FILE" --rollback
        exit 0
    fi

    echo ">> Running SQL interpolation for target: $TARGET"
    run_step "SQL interpolation failed for target '$TARGET'" \
        wrapper \
        run_python "$SQL_INTERPOLATOR_SCRIPT" "$TARGET" --bundle-file "$BUNDLE_FILE"

    if [[ "$OP" == "compile" ]]; then
        echo ">> Compile operation completed. Databricks CLI execution skipped."
        echo ">> Preprocessed YAML and interpolated SQL files were kept without rollback."
        exit 0
    fi

    BUNDLE_ARGS=("${CLI_ARGS[@]}" "-t" "$TARGET")
    if [[ "$FULL_VERBOSE" == "true" ]]; then
        BUNDLE_ARGS+=("--verbose")
    fi
    echo ">> Executing Databricks bundle operation: ${BUNDLE_ARGS[*]}"
    run_step "databricks bundle command failed" full run_bundle_cli "${BUNDLE_ARGS[@]}"

    echo ">> Bundle completed successfully. Rolling back interpolated SQL files."
    run_step "SQL rollback failed for target '$TARGET'" \
        wrapper \
        run_python "$SQL_INTERPOLATOR_SCRIPT" "$TARGET" --bundle-file "$BUNDLE_FILE" --rollback
else
     echo "Error: $RESOURCES_FOLDER folder not found" >&2; exit 1; 
fi
