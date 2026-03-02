from __future__ import annotations

import sys

import pytest

from conftest import load_script_module


@pytest.fixture
def ycp():
    return load_script_module("yaml_comments_preprocessor.py", "yaml_comments_preprocessor_test")


def test_parse_arguments_requires_target_when_not_check(monkeypatch, ycp):
    monkeypatch.setattr(sys, "argv", ["prog"])
    with pytest.raises(SystemExit):
        ycp.parse_arguments()


def test_parse_arguments_with_target_and_defines(monkeypatch, tmp_path, ycp):
    in_file = tmp_path / "in.yml"
    out_file = tmp_path / "out.yml"
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "prog",
            "-i",
            str(in_file),
            "-o",
            str(out_file),
            "-t",
            "prod",
            "-D",
            "x=1",
            "-D",
            "name='franc'",
        ],
    )

    ycp.parse_arguments()

    assert ycp.check is False
    assert ycp.input_f == in_file
    assert ycp.output_f == out_file
    assert ycp.contextual_variables["target"] == "prod"
    assert ycp.contextual_variables["x"] == 1
    assert ycp.contextual_variables["name"] == "franc"


def test_evaluate_condition_success_and_errors(ycp):
    ycp.contextual_variables.clear()
    ycp.contextual_variables.update({"target": "prod", "items": ["a", "b"]})

    errors: list[str] = []
    assert ycp.evaluate_condition("target == 'prod'", 1, errors) is True
    assert ycp.evaluate_condition("target != 'dev'", 2, errors) is True
    assert ycp.evaluate_condition("'a' in items", 3, errors) is False

    assert ycp.evaluate_condition("missing == 1", 4, errors) is False
    assert any("is not defined" in e for e in errors)

    prev_len = len(errors)
    assert ycp.evaluate_condition("target == [", 5, errors) is False
    assert len(errors) == prev_len + 1


def test_transform_if_and_rnmif_key_and_value(ycp):
    ycp.check = False
    ycp.contextual_variables.clear()
    ycp.contextual_variables.update({"target": "prod"})

    lines = [
        "# 1: IF (target == 'prod')\n",
        "name: app\n",
        "# 1: FI\n",
        "# RNMIF (target == 'prod') environment\n",
        "target: local\n",
        "# RNMIF (target == 'prod') local | prod\n",
        "path: local/file\n",
    ]

    processed, errors = ycp.transform(lines)

    assert errors == []
    assert processed is not None
    assert "name: app\n" in processed
    assert "environment: local\n" in processed
    assert "path: prod/file\n" in processed


def test_transform_reports_structure_errors(ycp):
    ycp.check = False
    ycp.contextual_variables.clear()
    ycp.contextual_variables.update({"target": "prod"})

    lines = [
        "# 9: FI\n",
        "# RNMIF (target == 'prod') renamed\n",
    ]

    processed, errors = ycp.transform(lines)

    assert processed is not None
    assert any("found but there is not" in e for e in errors)
    assert any("RNMIF pending renaming" in e for e in errors)


def test_transform_check_mode_returns_none_output(ycp):
    ycp.check = True
    ycp.contextual_variables.clear()
    ycp.contextual_variables.update({"target": "dev"})

    processed, errors = ycp.transform(["# 1: IF (target == 'prod')\n", "a: b\n", "# 1: FI\n"])

    assert processed is None
    assert errors == []


def test_main_check_success(monkeypatch, tmp_path, capsys, ycp):
    in_file = tmp_path / "input.yml"
    in_file.write_text("x: 1\n", encoding="utf-8")

    monkeypatch.setattr(sys, "argv", ["prog", "--check", "-i", str(in_file)])

    with pytest.raises(SystemExit) as exc:
        ycp.main()

    out = capsys.readouterr().out
    assert exc.value.code == 0
    assert f"{in_file}: OK" in out


def test_main_returns_error_on_transform_errors(monkeypatch, tmp_path, capsys, ycp):
    in_file = tmp_path / "input.yml"
    in_file.write_text("# 1: FI\n", encoding="utf-8")

    monkeypatch.setattr(sys, "argv", ["prog", "--check", "-i", str(in_file)])

    with pytest.raises(SystemExit) as exc:
        ycp.main()

    err = capsys.readouterr().err
    assert exc.value.code == 1
    assert "found but there is not" in err
