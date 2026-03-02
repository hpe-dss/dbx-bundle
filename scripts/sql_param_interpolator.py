#!/usr/bin/env python3
"""Interpolate :params in DAB SQL notebooks and support target-scoped rollback.

Main flow:
1. Read `databricks.yml` and resolve effective variables for a target.
2. Detect tasks marked with `# [interpolate]` in resource YAML files.
3. For each marked SQL task, replace `:param` with typed SQL literals.
4. Before writing, create a target-scoped backup: `<file>.<target>.dab.bak`.
5. In rollback mode, restore from backups for the selected target only.
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from dataclasses import dataclass, field
from glob import glob
from pathlib import Path
from typing import Any

import yaml

INTERPOLATE_MARKER = "[interpolate]"
BACKUP_SUFFIX = ".dab.bak"
PARAM_PATTERN = re.compile(r"(?<!:):([A-Za-z_][A-Za-z0-9_]*)\b")
VAR_REF_PATTERN = re.compile(r"\$\{var\.([A-Za-z_][A-Za-z0-9_]*)\}")
BUNDLE_REF_PATTERN = re.compile(r"\$\{bundle\.([A-Za-z_][A-Za-z0-9_]*)\}")
TASK_KEY_LINE = re.compile(r'^\s*-\s*task_key\s*:\s*["\']?([^"\']+)["\']?\s*$')


@dataclass
class RuntimeContext:
    """Holds shared state used while processing resources and tasks."""

    target: str
    bundle_dir: Path
    variables: dict[str, Any]
    bundle_meta: dict[str, Any]
    dry_run: bool
    rollback: bool
    restored_backups: list[Path] = field(default_factory=list)


@dataclass
class ProcessingStats:
    """Tracks changed files and replacement counts."""

    files: int = 0
    replacements: int = 0

    def add(self, other: "ProcessingStats") -> None:
        """Accumulate stats from another partial run."""
        self.files += other.files
        self.replacements += other.replacements


def parse_args() -> argparse.Namespace:
    """Define and parse CLI arguments."""
    parser = argparse.ArgumentParser(
        description=(
            "Resolve target variables and replace :param in SQL tasks "
            "marked with '# [interpolate]'."
        )
    )
    parser.add_argument("target", help="Bundle target (for example: local, itg, prod)")
    parser.add_argument(
        "--bundle-file",
        default="databricks.yml",
        help="Path to databricks.yml (default: databricks.yml)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Do not write .sql files; only print planned changes",
    )
    parser.add_argument(
        "--rollback",
        action="store_true",
        help="Restore .sql files from target backups (*.TARGET.dab.bak)",
    )
    return parser.parse_args()


def load_yaml_document(path: Path) -> dict[str, Any]:
    """Load YAML with PyYAML."""
    if not path.exists():
        raise FileNotFoundError(f"File not found: {path}")

    with path.open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    if not isinstance(data, dict):
        raise ValueError(f"Invalid YAML in {path}: root must be a mapping")
    return data


def resolve_target_variables(
    bundle_data: dict[str, Any], target: str, bundle_meta: dict[str, Any]
) -> dict[str, Any]:
    """Resolve final variables: defaults + target overrides + cross-variable dependencies."""
    variables_section = bundle_data.get("variables", {}) or {}
    targets_section = bundle_data.get("targets", {}) or {}

    if not isinstance(variables_section, dict):
        raise ValueError("'variables' must be a mapping")
    if not isinstance(targets_section, dict):
        raise ValueError("'targets' must be a mapping")
    if target not in targets_section:
        available = ", ".join(sorted(targets_section)) or "(no targets)"
        raise KeyError(f"Target '{target}' does not exist. Available: {available}")

    resolved: dict[str, Any] = {}
    for var_name, var_def in variables_section.items():
        if isinstance(var_def, dict) and "default" in var_def:
            resolved[var_name] = var_def["default"]
        else:
            resolved[var_name] = var_def

    target_vars = (targets_section.get(target) or {}).get("variables", {}) or {}
    if not isinstance(target_vars, dict):
        raise ValueError(f"'targets.{target}.variables' must be a mapping")
    resolved.update(target_vars)

    return resolve_variable_dependencies(resolved, bundle_meta=bundle_meta)


def resolve_template_preserve_unknowns(
    raw: Any, variables: dict[str, Any], bundle_meta: dict[str, Any]
) -> Any:
    """Resolve template placeholders but keep unknown refs unchanged."""
    if not isinstance(raw, str):
        return raw

    value = raw

    def var_replacer(match: re.Match[str]) -> str:
        key = match.group(1)
        if key in variables:
            return stringify_scalar(variables[key])
        return match.group(0)

    def bundle_replacer(match: re.Match[str]) -> str:
        key = match.group(1)
        if key in bundle_meta:
            return stringify_scalar(bundle_meta[key])
        return match.group(0)

    for _ in range(5):
        previous = value
        value = VAR_REF_PATTERN.sub(var_replacer, value)
        value = BUNDLE_REF_PATTERN.sub(bundle_replacer, value)
        if value == previous:
            break

    return value


def find_unresolved_var_refs(value: Any) -> set[str]:
    """Extract unresolved `${var.*}` references from a value."""
    if not isinstance(value, str):
        return set()
    return {match.group(1) for match in VAR_REF_PATTERN.finditer(value)}


def resolve_variable_dependencies(
    variables: dict[str, Any], bundle_meta: dict[str, Any]
) -> dict[str, Any]:
    """Resolve variable-to-variable references regardless declaration order."""
    resolved = dict(variables)
    max_passes = max(1, len(resolved) * 5)

    for _ in range(max_passes):
        changed = False
        snapshot = dict(resolved)

        for name, raw_value in snapshot.items():
            new_value = resolve_template_preserve_unknowns(
                raw_value, variables=snapshot, bundle_meta=bundle_meta
            )
            if new_value != resolved[name]:
                resolved[name] = new_value
                changed = True

        if not changed:
            break

    unresolved_by_var: dict[str, set[str]] = {}
    for name, value in resolved.items():
        refs = find_unresolved_var_refs(value)
        if refs:
            unresolved_by_var[name] = refs

    if unresolved_by_var:
        details = ", ".join(
            f"{var_name} -> {sorted(refs)}"
            for var_name, refs in sorted(unresolved_by_var.items())
        )
        raise ValueError(
            "Unresolved variable references detected "
            "(possibly missing variables or cyclic dependencies): "
            f"{details}"
        )

    return resolved


def stringify_scalar(value: Any) -> str:
    """Normalize scalar values to strings for logs and SQL literals."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def escape_sql_literal(value: Any) -> str:
    """Escape single quotes for safe SQL literal interpolation."""
    return stringify_scalar(value).replace("'", "''")


def is_single_quoted_literal(value: str) -> bool:
    """Return True when value already looks like a single-quoted SQL literal."""
    return bool(re.fullmatch(r"'(?:[^']|'')*'", value))


def format_sql_literal(value: Any) -> str:
    """Format Python values as SQL literals preserving primitive types."""
    if isinstance(value, str):
        if is_single_quoted_literal(value):
            return value
        return f"'{escape_sql_literal(value)}'"
    return stringify_scalar(value)


def resolve_template(raw: Any, variables: dict[str, Any], bundle_meta: dict[str, Any]) -> Any:
    """Resolve `${var.*}` and `${bundle.*}` placeholders in a string value."""
    if not isinstance(raw, str):
        return raw

    value = raw

    def var_replacer(match: re.Match[str]) -> str:
        key = match.group(1)
        return stringify_scalar(variables.get(key, ""))

    def bundle_replacer(match: re.Match[str]) -> str:
        key = match.group(1)
        return stringify_scalar(bundle_meta.get(key, ""))

    # Iterate a bounded number of times for chained template resolution.
    for _ in range(5):
        previous = value
        value = VAR_REF_PATTERN.sub(var_replacer, value)
        value = BUNDLE_REF_PATTERN.sub(bundle_replacer, value)
        if value == previous:
            break

    return value


def sanitize_target(target: str) -> str:
    """Sanitize target for safe usage in file names."""
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", target)


def build_backup_path(sql_file: Path, target: str) -> Path:
    """Build target-scoped backup path for a SQL file."""
    return Path(f"{sql_file}.{sanitize_target(target)}{BACKUP_SUFFIX}")


def backup_file(sql_file: Path, target: str) -> Path:
    """Create or overwrite SQL backup before mutation."""
    backup_path = build_backup_path(sql_file, target)
    shutil.copy2(sql_file, backup_path)
    return backup_path


def rollback_file(sql_file: Path, target: str, dry_run: bool) -> Path | None:
    """Restore SQL file from target backup and return backup path if restored."""
    backup_path = build_backup_path(sql_file, target)
    if not backup_path.exists():
        return None
    if not dry_run:
        shutil.copy2(backup_path, sql_file)
    return backup_path


def cleanup_restored_backups(backups: list[Path]) -> int:
    """Delete restored backup files at the end of rollback execution."""
    deleted = 0
    for backup_path in sorted(set(backups)):
        if backup_path.exists():
            backup_path.unlink()
            deleted += 1
    return deleted


def get_include_patterns(bundle_data: dict[str, Any]) -> list[str]:
    """Extract valid `include` patterns from bundle YAML."""
    include = bundle_data.get("include", [])
    if isinstance(include, str):
        return [include]
    if isinstance(include, list):
        return [entry for entry in include if isinstance(entry, str)]
    return []


def expand_resource_files(bundle_path: Path, patterns: list[str]) -> list[Path]:
    """Expand include globs into a sorted unique list of resource YAML files."""
    base_dir = bundle_path.parent
    files: list[Path] = []

    for pattern in patterns:
        for match in glob(str(base_dir / pattern), recursive=True):
            file_path = Path(match)
            if file_path.is_file() and file_path.suffix in {".yml", ".yaml"}:
                files.append(file_path)

    return sorted(set(files))


def find_marked_task_keys(resource_file: Path) -> set[str]:
    """Find task keys that have `# [interpolate]` immediately above them."""
    marked_keys: set[str] = set()
    armed = False

    for line in resource_file.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()

        if INTERPOLATE_MARKER in stripped and stripped.startswith("#"):
            armed = True
            continue
        if not stripped:
            continue
        if stripped.startswith("#"):
            continue

        match = TASK_KEY_LINE.match(line)
        if armed and match:
            marked_keys.add(match.group(1).strip())
            armed = False
            continue

        if armed:
            armed = False

    return marked_keys


def build_job_parameters(
    job_def: dict[str, Any], variables: dict[str, Any], bundle_meta: dict[str, Any]
) -> dict[str, Any]:
    """Resolve `job.parameters` defaults with variable and bundle interpolation."""
    resolved: dict[str, Any] = {}
    params = job_def.get("parameters", []) or []

    if not isinstance(params, list):
        return resolved

    for item in params:
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        if not name:
            continue
        resolved[name] = resolve_template(item.get("default", ""), variables, bundle_meta)

    return resolved


def build_task_parameters(
    task: dict[str, Any], variables: dict[str, Any], bundle_meta: dict[str, Any]
) -> dict[str, Any]:
    """Resolve `notebook_task.base_parameters`, excluding `{{job.*}}` values."""
    resolved: dict[str, Any] = {}
    notebook_task = task.get("notebook_task", {}) or {}
    base_params = notebook_task.get("base_parameters", {}) or {}

    if not isinstance(base_params, dict):
        return resolved

    for key, raw_value in base_params.items():
        if isinstance(raw_value, str) and "{{job." in raw_value:
            # Functional requirement: `{{job.*}}` values are not interpolated into SQL.
            continue
        resolved[key] = resolve_template(raw_value, variables, bundle_meta)

    return resolved


def extract_sql_path(task: dict[str, Any]) -> str:
    """Return notebook path when task points to a `.sql` notebook."""
    notebook_task = task.get("notebook_task", {}) or {}
    notebook_path = notebook_task.get("notebook_path")
    if isinstance(notebook_path, str) and notebook_path.strip().lower().endswith(".sql"):
        return notebook_path.strip()
    return ""


def resolve_sql_local_path(sql_path: str, bundle_dir: Path, resource_file: Path) -> Path | None:
    """Resolve local SQL path; ignore Workspace/DBFS/URL paths."""
    lower = sql_path.lower()
    if lower.startswith("/workspace/") or lower.startswith("dbfs:"):
        return None
    if "://" in sql_path:
        return None

    candidate = Path(sql_path)
    if candidate.is_absolute():
        return candidate if candidate.exists() else None

    from_resource = (resource_file.parent / candidate).resolve()
    if from_resource.exists():
        return from_resource

    from_bundle = (bundle_dir / candidate).resolve()
    if from_bundle.exists():
        return from_bundle

    return None


def interpolate_sql_file(
    sql_file: Path, params: dict[str, Any], target: str, dry_run: bool
) -> int:
    """Replace `:param` tokens in SQL and return replacement count."""
    original = sql_file.read_text(encoding="utf-8")
    replaced_count = 0

    def replacer(match: re.Match[str]) -> str:
        nonlocal replaced_count
        key = match.group(1)
        if key not in params:
            return match.group(0)
        replaced_count += 1
        return format_sql_literal(params[key])

    updated = PARAM_PATTERN.sub(replacer, original)

    if not dry_run and updated != original:
        backup_file(sql_file, target)
        sql_file.write_text(updated, encoding="utf-8")

    return replaced_count


def process_task(
    task: dict[str, Any],
    task_key: str,
    job_params: dict[str, Any],
    resource_file: Path,
    ctx: RuntimeContext,
) -> ProcessingStats:
    """Process one marked SQL task in interpolate or rollback mode."""
    sql_path = extract_sql_path(task)
    if not sql_path:
        print(
            f"WARN: {resource_file}: task '{task_key}' is marked but not a SQL notebook",
            file=sys.stderr,
        )
        return ProcessingStats()

    sql_file = resolve_sql_local_path(sql_path, ctx.bundle_dir, resource_file)
    if sql_file is None:
        print(
            f"WARN: {resource_file}: task '{task_key}' has non-local SQL path ({sql_path})",
            file=sys.stderr,
        )
        return ProcessingStats()

    print(f"task={task_key} sql={sql_file}")

    if ctx.rollback:
        restored_backup = rollback_file(sql_file, target=ctx.target, dry_run=ctx.dry_run)
        if restored_backup is not None:
            if not ctx.dry_run:
                ctx.restored_backups.append(restored_backup)
            action = "DRY-RUN" if ctx.dry_run else "ROLLED-BACK"
            print(f"  {action}: restored from backup")
            return ProcessingStats(files=1)
        print("  NO BACKUP")
        return ProcessingStats()

    params = dict(job_params)
    params.update(build_task_parameters(task, ctx.variables, ctx.bundle_meta))

    for key in sorted(params):
        print(f"  {key}={stringify_scalar(params[key])}")

    replacements = interpolate_sql_file(
        sql_file, params=params, target=ctx.target, dry_run=ctx.dry_run
    )

    if replacements == 0:
        print("  NO CHANGES")
        return ProcessingStats()

    action = "DRY-RUN" if ctx.dry_run else "UPDATED"
    print(f"  {action}: {replacements} replacements")
    return ProcessingStats(files=1, replacements=replacements)


def process_resource_file(resource_file: Path, ctx: RuntimeContext) -> ProcessingStats:
    """Process a resource YAML and execute interpolation on marked tasks."""
    marked_task_keys = find_marked_task_keys(resource_file)
    if not marked_task_keys:
        return ProcessingStats()

    resource_data = load_yaml_document(resource_file)
    jobs = ((resource_data.get("resources", {}) or {}).get("jobs", {}) or {})
    if not isinstance(jobs, dict):
        return ProcessingStats()

    stats = ProcessingStats()

    for job_def_any in jobs.values():
        if not isinstance(job_def_any, dict):
            continue

        job_params = build_job_parameters(job_def_any, ctx.variables, ctx.bundle_meta)
        tasks = job_def_any.get("tasks", []) or []
        if not isinstance(tasks, list):
            continue

        for task_any in tasks:
            if not isinstance(task_any, dict):
                continue
            task_key = task_any.get("task_key")
            if not isinstance(task_key, str) or task_key not in marked_task_keys:
                continue
            stats.add(process_task(task_any, task_key, job_params, resource_file, ctx))

    return stats


def build_runtime_context(args: argparse.Namespace) -> tuple[RuntimeContext, list[Path]]:
    """Build runtime context and resolve resource files from bundle include."""
    bundle_path = Path(args.bundle_file).resolve()
    bundle_data = load_yaml_document(bundle_path)

    bundle_meta = dict(bundle_data.get("bundle", {}) or {})
    bundle_meta.setdefault("target", args.target)
    variables = resolve_target_variables(
        bundle_data=bundle_data, target=args.target, bundle_meta=bundle_meta
    )

    include_patterns = get_include_patterns(bundle_data)
    if not include_patterns:
        raise ValueError("No 'include' patterns found to locate resources/*.yml")

    resource_files = expand_resource_files(bundle_path, include_patterns)
    if not resource_files:
        raise ValueError("No resource files were found to process")

    ctx = RuntimeContext(
        target=args.target,
        bundle_dir=bundle_path.parent.resolve(),
        variables=variables,
        bundle_meta=bundle_meta,
        dry_run=args.dry_run,
        rollback=args.rollback,
    )
    return ctx, resource_files


def print_resolved_variables(target: str, variables: dict[str, Any]) -> None:
    """Print target and effective variables for execution traceability."""
    print(f"target={target}")
    for key in sorted(variables):
        print(f"var.{key}={stringify_scalar(variables[key])}")


def main() -> int:
    """CLI entrypoint: validate args, execute processing, print summary."""
    args = parse_args()

    if args.rollback and args.dry_run:
        print("ERROR: --rollback and --dry-run cannot be used together", file=sys.stderr)
        return 1

    try:
        ctx, resource_files = build_runtime_context(args)
    except (FileNotFoundError, ValueError, KeyError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print_resolved_variables(ctx.target, ctx.variables)

    total = ProcessingStats()
    for resource_file in resource_files:
        total.add(process_resource_file(resource_file, ctx))

    if ctx.rollback:
        deleted_backups = 0
        if not ctx.dry_run:
            deleted_backups = cleanup_restored_backups(ctx.restored_backups)
        print(f"summary: restored_sql_files={total.files} rollback=True")
        print(f"summary: deleted_backup_files={deleted_backups}")
    else:
        print(
            f"summary: modified_sql_files={total.files} "
            f"total_replacements={total.replacements} dry_run={ctx.dry_run}"
        )

    return 0


if __name__ == "__main__":
    main()
