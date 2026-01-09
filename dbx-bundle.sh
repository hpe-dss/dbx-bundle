#!/usr/bin/env bash
set -euo pipefail

########################################
# 1. parse arguments
########################################
TARGET=""
OP=""
CLI_ARGS=()
ALLOWED_OPS=( 'deploy' 'validate' 'destroy' 'summary' 'deployment' )

RESOURCES_FOLDER='resources'
PY_SCRIPT="$(realpath "$HOME/scripts/yaml_comments_preprocessor.py")"

in_list() {
    local tgt="$1"
    shift
    for item in "$@"; do
        [[ "$item" == "$tgt" ]] && return 0
    done
    return 1
}


while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      [[ $# -lt 2 ]] && { echo "Error: -t|--target requires a value" >&2; exit 1; }
      TARGET="$2"
      CLI_ARGS+=("$1" "$2")
      shift 2
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

[[ -z "$OP" ]] && { echo "Error: you must give a valid operation argument" >&2; exit 1; }
[[ -z "$TARGET" ]] && { echo "Error: you must give arg -t|--target <value>" >&2; exit 1; }
[[ -f databricks.yml ]] || { echo "Error: databricks.yml not found" >&2; exit 1; }


declare -A BACKUPS=()
restore(){ for f in "${!BACKUPS[@]}"; do mv -f "${BACKUPS[$f]}" "$f"; done; }
trap restore EXIT INT TERM

if [[ -d "$RESOURCES_FOLDER" ]]; then

    while IFS= read -r -d '' yml; do
        python "$PY_SCRIPT" --check -i "$yml" -t "$TARGET" || { echo "✖ comment directives with errors in $yml" >&2; exit 1; }
    done < <(find "$RESOURCES_FOLDER" -type f -name '*.yml' -print0)

    while IFS= read -r -d '' yml; do
        bak="${yml%.yml}.bak.$$"; cp "$yml" "$bak"; BACKUPS["$yml"]="$bak"
        python "$PY_SCRIPT" -t "$TARGET" -i "$yml" -o "$yml"
    done < <(find "$RESOURCES_FOLDER" -type f -name '*.yml' -print0)

    echo ">> Running: databricks bundle ${CLI_ARGS[*]}"
    databricks bundle "${CLI_ARGS[@]}"
else
     echo "Error: $RESOURCES_FOLDER folder not found" >&2; exit 1; 
fi