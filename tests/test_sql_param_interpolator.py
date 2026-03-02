from __future__ import annotations

from pathlib import Path

import pytest

from conftest import load_script_module


@pytest.fixture
def spi():
    return load_script_module("sql_param_interpolator.py", "sql_param_interpolator_test")


def test_processing_stats_add(spi):
    a = spi.ProcessingStats(files=1, replacements=2)
    b = spi.ProcessingStats(files=3, replacements=4)
    a.add(b)
    assert (a.files, a.replacements) == (4, 6)


def test_load_yaml_document_valid_and_errors(tmp_path, spi):
    yml = tmp_path / "ok.yml"
    yml.write_text("a: 1\n", encoding="utf-8")
    assert spi.load_yaml_document(yml) == {"a": 1}

    with pytest.raises(FileNotFoundError):
        spi.load_yaml_document(tmp_path / "missing.yml")

    bad = tmp_path / "bad.yml"
    bad.write_text("- one\n- two\n", encoding="utf-8")
    with pytest.raises(ValueError):
        spi.load_yaml_document(bad)


def test_resolve_target_variables_nominal_and_errors(spi):
    bundle_data = {
        "variables": {"a": {"default": "1"}, "b": "${var.a}-x"},
        "targets": {"dev": {"variables": {"a": "2"}}},
    }
    resolved = spi.resolve_target_variables(bundle_data, "dev", {"target": "dev"})
    assert resolved["a"] == "2"
    assert resolved["b"] == "2-x"

    with pytest.raises(KeyError):
        spi.resolve_target_variables({"variables": {}, "targets": {}}, "prod", {})

    with pytest.raises(ValueError):
        spi.resolve_target_variables({"variables": [1], "targets": {"x": {}}}, "x", {})


def test_template_resolution_and_unresolved_detection(spi):
    preserve = spi.resolve_template_preserve_unknowns(
        "${var.a}-${bundle.target}-${var.missing}", {"a": 1}, {"target": "dev"}
    )
    assert preserve == "1-dev-${var.missing}"

    normal = spi.resolve_template("${var.a}-${bundle.target}-${var.missing}", {"a": 1}, {"target": "dev"})
    assert normal == "1-dev-"

    refs = spi.find_unresolved_var_refs("x ${var.one} y ${var.two}")
    assert refs == {"one", "two"}


def test_resolve_variable_dependencies_and_cycle_error(spi):
    resolved = spi.resolve_variable_dependencies(
        {"a": "1", "b": "${var.a}-ok"}, {"target": "dev"}
    )
    assert resolved["b"] == "1-ok"

    with pytest.raises(ValueError):
        spi.resolve_variable_dependencies({"a": "${var.b}", "b": "${var.a}"}, {})


def test_scalar_and_sql_format_helpers(spi):
    assert spi.stringify_scalar(None) == "null"
    assert spi.stringify_scalar(True) == "true"
    assert spi.escape_sql_literal("O'Reilly") == "O''Reilly"
    assert spi.is_single_quoted_literal("'abc'")
    assert spi.is_single_quoted_literal("'O''Reilly'")
    assert not spi.is_single_quoted_literal("abc")
    assert spi.format_sql_literal("abc") == "'abc'"
    assert spi.format_sql_literal("'/tmp/dbx/delta/table'") == "'/tmp/dbx/delta/table'"
    assert spi.format_sql_literal(10) == "10"


def test_backup_rollback_and_cleanup(tmp_path, spi):
    sql = tmp_path / "q.sql"
    sql.write_text("select 1", encoding="utf-8")

    backup = spi.backup_file(sql, "dev/env")
    assert backup.exists()
    assert "dev_env" in str(backup)

    sql.write_text("changed", encoding="utf-8")
    restored = spi.rollback_file(sql, "dev/env", dry_run=False)
    assert restored == backup
    assert sql.read_text(encoding="utf-8") == "select 1"

    deleted = spi.cleanup_restored_backups([backup, backup])
    assert deleted == 1
    assert not backup.exists()


def test_get_include_patterns_and_expand_resource_files(tmp_path, spi):
    bundle = tmp_path / "databricks.yml"
    bundle.write_text("bundle: {name: demo}\n", encoding="utf-8")

    res_dir = tmp_path / "resources"
    res_dir.mkdir()
    a = res_dir / "a.yml"
    b = res_dir / "b.yaml"
    c = res_dir / "skip.txt"
    a.write_text("resources: {}\n", encoding="utf-8")
    b.write_text("resources: {}\n", encoding="utf-8")
    c.write_text("x", encoding="utf-8")

    patterns = spi.get_include_patterns({"include": ["resources/*"]})
    files = spi.expand_resource_files(bundle, patterns)

    assert files == sorted([a, b])
    assert spi.get_include_patterns({"include": "resources/*.yml"}) == ["resources/*.yml"]
    assert spi.get_include_patterns({"include": 123}) == []


def test_find_marked_task_keys(tmp_path, spi):
    resource = tmp_path / "job.yml"
    resource.write_text(
        """
# [interpolate]
- task_key: first
# comment
- task_key: second
# [interpolate]
not_a_task: value
# [interpolate]
- task_key: third
""".strip()
        + "\n",
        encoding="utf-8",
    )

    assert spi.find_marked_task_keys(resource) == {"first", "third"}


def test_build_job_and_task_parameters(spi):
    job_def = {
        "parameters": [
            {"name": "p1", "default": "${var.a}"},
            {"name": "p2", "default": "${bundle.target}"},
            {"default": "x"},
        ]
    }
    params = spi.build_job_parameters(job_def, {"a": "1"}, {"target": "dev"})
    assert params == {"p1": "1", "p2": "dev"}

    task = {
        "notebook_task": {
            "base_parameters": {
                "x": "${var.a}",
                "skip": "{{job.parameters.foo}}",
                "flag": True,
            }
        }
    }
    task_params = spi.build_task_parameters(task, {"a": "1"}, {"target": "dev"})
    assert task_params == {"x": "1", "flag": True}


def test_extract_and_resolve_sql_path(tmp_path, spi):
    resource = tmp_path / "resources" / "job.yml"
    resource.parent.mkdir()
    resource.write_text("x: 1\n", encoding="utf-8")

    sql = resource.parent / "query.sql"
    sql.write_text("select 1", encoding="utf-8")

    assert spi.extract_sql_path({"notebook_task": {"notebook_path": " query.sql "}}) == "query.sql"
    assert spi.extract_sql_path({"notebook_task": {"notebook_path": "not_sql.py"}}) == ""

    assert spi.resolve_sql_local_path("query.sql", tmp_path, resource) == sql.resolve()
    assert spi.resolve_sql_local_path("/Workspace/a.sql", tmp_path, resource) is None
    assert spi.resolve_sql_local_path("dbfs:/a.sql", tmp_path, resource) is None
    assert spi.resolve_sql_local_path("https://x/a.sql", tmp_path, resource) is None


def test_interpolate_sql_file_dry_and_write(tmp_path, spi):
    sql = tmp_path / "q.sql"
    sql.write_text("select :a, :b, ::type", encoding="utf-8")

    replaced = spi.interpolate_sql_file(sql, {"a": "x", "b": 2}, "dev", dry_run=True)
    assert replaced == 2
    assert sql.read_text(encoding="utf-8") == "select :a, :b, ::type"

    replaced = spi.interpolate_sql_file(sql, {"a": "x", "b": 2}, "dev", dry_run=False)
    assert replaced == 2
    assert sql.read_text(encoding="utf-8") == "select 'x', 2, ::type"
    assert spi.build_backup_path(sql, "dev").exists()


def test_interpolate_sql_file_preserves_single_quoted_param(tmp_path, spi):
    sql = tmp_path / "q.sql"
    sql.write_text("LOCATION :path", encoding="utf-8")

    replaced = spi.interpolate_sql_file(
        sql, {"path": "'/tmp/dbx/delta/clientes_master'"}, "dev", dry_run=False
    )
    assert replaced == 1
    assert sql.read_text(encoding="utf-8") == "LOCATION '/tmp/dbx/delta/clientes_master'"


def test_process_task_non_sql_and_non_local(tmp_path, spi, capsys):
    ctx = spi.RuntimeContext(
        target="dev",
        bundle_dir=tmp_path,
        variables={},
        bundle_meta={"target": "dev"},
        dry_run=True,
        rollback=False,
    )

    stats = spi.process_task(
        {"notebook_task": {"notebook_path": "job.py"}},
        "t1",
        {},
        tmp_path / "resource.yml",
        ctx,
    )
    assert stats.files == 0

    stats = spi.process_task(
        {"notebook_task": {"notebook_path": "dbfs:/job.sql"}},
        "t2",
        {},
        tmp_path / "resource.yml",
        ctx,
    )
    assert stats.files == 0
    err = capsys.readouterr().err
    assert "not a SQL notebook" in err
    assert "non-local SQL path" in err


def test_process_task_rollback_and_update(tmp_path, spi):
    sql = tmp_path / "job.sql"
    sql.write_text("select :a", encoding="utf-8")
    backup = spi.build_backup_path(sql, "dev")
    backup.write_text("select 1", encoding="utf-8")

    resource_file = tmp_path / "r.yml"
    resource_file.write_text("x: 1\n", encoding="utf-8")

    rollback_ctx = spi.RuntimeContext(
        target="dev",
        bundle_dir=tmp_path,
        variables={},
        bundle_meta={"target": "dev"},
        dry_run=False,
        rollback=True,
    )

    stats = spi.process_task(
        {"task_key": "t", "notebook_task": {"notebook_path": "job.sql"}},
        "t",
        {},
        resource_file,
        rollback_ctx,
    )
    assert stats.files == 1
    assert rollback_ctx.restored_backups == [backup]

    update_ctx = spi.RuntimeContext(
        target="dev",
        bundle_dir=tmp_path,
        variables={"a": "x"},
        bundle_meta={"target": "dev"},
        dry_run=False,
        rollback=False,
    )
    sql.write_text("select :a", encoding="utf-8")

    stats = spi.process_task(
        {
            "task_key": "t",
            "notebook_task": {"notebook_path": "job.sql", "base_parameters": {"a": "${var.a}"}},
        },
        "t",
        {},
        resource_file,
        update_ctx,
    )
    assert stats.files == 1
    assert stats.replacements == 1


def test_process_resource_file_and_runtime_context(tmp_path, spi, monkeypatch):
    bundle = tmp_path / "databricks.yml"
    bundle.write_text(
        """
bundle:
  name: demo
include:
  - resources/*.yml
variables:
  p:
    default: "1"
targets:
  dev:
    variables:
      p: "2"
""".strip()
        + "\n",
        encoding="utf-8",
    )

    res_dir = tmp_path / "resources"
    res_dir.mkdir()
    resource = res_dir / "job.yml"
    resource.write_text(
        """
resources:
  jobs:
    job1:
      tasks:
        # [interpolate]
        - task_key: t1
          notebook_task:
            notebook_path: q.sql
""".strip()
        + "\n",
        encoding="utf-8",
    )

    called = []

    def fake_process_task(task, task_key, job_params, resource_file, ctx):
        called.append((task_key, resource_file))
        return spi.ProcessingStats(files=1, replacements=2)

    monkeypatch.setattr(spi, "process_task", fake_process_task)

    args = type("Args", (), {"bundle_file": str(bundle), "target": "dev", "dry_run": True, "rollback": False})
    ctx, resources = spi.build_runtime_context(args)
    assert resources == [resource]
    assert ctx.variables["p"] == "2"

    stats = spi.process_resource_file(resource, ctx)
    assert stats.files == 1
    assert stats.replacements == 2
    assert called and called[0][0] == "t1"


def test_main_paths(monkeypatch, spi, capsys):
    class Args:
        target = "dev"
        bundle_file = "databricks.yml"
        dry_run = True
        rollback = True

    monkeypatch.setattr(spi, "parse_args", lambda: Args)
    assert spi.main() == 1

    class Args2:
        target = "dev"
        bundle_file = "databricks.yml"
        dry_run = True
        rollback = False

    monkeypatch.setattr(spi, "parse_args", lambda: Args2)
    monkeypatch.setattr(spi, "build_runtime_context", lambda _args: (_ for _ in ()).throw(ValueError("boom")))
    assert spi.main() == 1

    class Args3:
        target = "dev"
        bundle_file = "databricks.yml"
        dry_run = True
        rollback = False

    monkeypatch.setattr(spi, "parse_args", lambda: Args3)

    ctx = spi.RuntimeContext(
        target="dev",
        bundle_dir=Path.cwd(),
        variables={"x": "1"},
        bundle_meta={"target": "dev"},
        dry_run=True,
        rollback=False,
    )
    monkeypatch.setattr(spi, "build_runtime_context", lambda _args: (ctx, []))
    monkeypatch.setattr(spi, "process_resource_file", lambda _resource, _ctx: spi.ProcessingStats())

    assert spi.main() == 0
    out = capsys.readouterr().out
    assert "summary: modified_sql_files=0" in out
