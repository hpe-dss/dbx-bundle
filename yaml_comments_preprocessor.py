#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
────────────────────────────────────────────────────────────────────────
Directives on YAML Comments
────────────────────────────────────────────────────────────────────────
# N: IF ( cond )          …  # N: FI
     · nesting with N identifier.
# RNMIF ( cond ) new_attr
     · renames next yaml key if condition is true.
# RNMIF ( cond ) find | replace
     · replaces just first ocurrence of <find> inside next YAML value.

conditions   :  var  ==, !=, in, not in   literal
variables     :  ctx["target"] (-t) + declared with -DVAR=value
validate mode :  --check  (-t not required)

Samples:
  python yaml_comments_preprocessor.py -t prod -i in.yml -o out.yml
  python yaml_comments_preprocessor.py --check  -i in.yml
  python yaml_comments_preprocessor.py -t qa -Dregion='"us-east1"' -i in.yml
"""

import argparse
import ast
import re
import sys
from pathlib import Path



SUPPORTED_OPS = {
    "==":     lambda a, b: a == b,
    "!=":     lambda a, b: a != b,
    "in":     lambda a, b: a in b,
    "not in": lambda a, b: a not in b,
}


condition_regex = re.compile(r"(\w+)\s*(==|!=|in|not in)\s*(.+)", re.I)
contextual_variables:dict = {}
input_f:Path = None
output_f:Path = None
check:bool = False


def parse_arguments():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-i", "--input",  type=Path, help="input YAML (STDIN by default)")
    p.add_argument("-o", "--output", type=Path, help="output YAML  (STDOUT by default)")
    p.add_argument("-t", "--target", help="default value for target (mandatory when not --check)")
    p.add_argument("-D", action="append", default=[], metavar="VAR=value", help="extra variables (repeatible)")
    p.add_argument("--check", action="store_true", help="Just validates input YAML")
    ns = p.parse_args()
    global check
    check = ns.check
    global input_f
    input_f = ns.input
    global output_f
    output_f = ns.output
    
    if not check and ns.target is None:
        p.error("-t/--target is mandatory when not --check")
    
    global contextual_variables
    if ns.target is not None:
        contextual_variables["target"] = ns.target

    for d in ns.D:
        if "=" not in d:
            p.error(f"-D wrong format: {d!r}  (must be VAR=value)")
        k, v = str(d).split("=", 1)
        try:
            contextual_variables[k] = ast.literal_eval(v)
        except Exception:
            contextual_variables[k] = v


def evaluate_condition(expr: str, line_no: int, errs: list[str]) -> bool:
    match = condition_regex.fullmatch(expr.strip())
    if not match:
        errs.append(f"line {line_no}: invalid condition → {expr!r}")
        return False
    var, op, raw_value = match.groups()
    if var not in contextual_variables:
        errs.append(f"line {line_no}: variable {var!r} is not defined")
        return False
    try:
        value = ast.literal_eval(raw_value.strip())
    except Exception as e:
        errs.append(f"line {line_no}: invalid value → {raw_value!r} ({e})")
        return False
    return SUPPORTED_OPS[op](contextual_variables[var], value)


def transform(lines: list[str]):
    output_lines, errors = [], []

    if_stack: list[tuple[int, bool]] = []
    pending_key: str | None = None
    pending_val: tuple[str, str] | None = None  # (find, repl)

    regex_if  = re.compile(r"\s*#\s*(\d+)\s*:\s*IF\s*\(\s*(.+?)\s*\)\s*$", re.I)
    regex_fi  = re.compile(r"\s*#\s*(\d+)\s*:\s*FI\b\s*$", re.I)
    regex_rename = re.compile(r"\s*#\s*RNMIF\s*\(\s*(.+?)\s*\)\s+(.+)\s*$", re.I)

    def skip_lines() -> bool:
        return any(not keep_line for _, keep_line in if_stack)

    for line_number, line_content in enumerate(lines, 1):

        if match_if := regex_if.match(line_content):
            if_number, if_condition = int(match_if[1]), match_if[2]
            keep_line = not skip_lines() and evaluate_condition(if_condition, line_number, errors)
            if_stack.append((if_number, keep_line))
            continue


        if match_fi := regex_fi.match(line_content):
            fi_number = int(match_fi[1])
            if not if_stack:
                errors.append(f"L{line_number}: # {fi_number}:FI found but there is not {fi_number}:IF block open.")
            elif if_stack[-1][0] != fi_number:
                errors.append(f"L{line_number}: # FI closing N={fi_number}, expected N={if_stack[-1][0]}")
            else:
                if_stack.pop()
            continue

        if skip_lines():
            continue

        if match_rnm := regex_rename.match(line_content):
            rnm_condition, action = match_rnm.groups()
            if evaluate_condition(rnm_condition, line_number, errors):
                if "|" in action and not action.strip().startswith(("'", '"')):
                    try:
                        find, repl = map(str.strip, action.split("|", 1))
                    except ValueError:
                        errors.append(f"L{line_number}: wrong syntaxis for find | replace.")
                    else:
                        pending_val = (find, repl)
                else:
                    pending_key = action.strip()
            continue

        # ----- rename key (mode 1) -----
        if pending_key is not None:
            if line_content.strip() and not line_content.lstrip().startswith("#") and ":" in line_content:
                indent, _ = re.match(r"^(\s*)(.*)", line_content).groups()
                _, rest = line_content.split(":", 1)
                output_lines.append(f"{indent}{pending_key}:{rest}")
                pending_key = None
                continue

        # ----- rename in value (mode 2) -----
        if pending_val is not None:
            if line_content.strip() and not line_content.lstrip().startswith("#") and ":" in line_content:
                key, rest = line_content.split(":", 1)
                find, repl = pending_val
                output_lines.append(f"{key}:{rest.replace(find, repl)}")
                pending_val = None
                continue

        output_lines.append(line_content)

    if if_stack:
        errors.append("end of file: closing # N: FI not found.")
    if pending_key:
        errors.append("end of file: RNMIF pending renaming no more YAML lines found.")
    if pending_val:
        errors.append("end of file: RNMIF find|replace renaming no more YAML lines found.")

    if check:
        return None, errors
    return output_lines, errors


def main():
    parse_arguments()
    raw = input_f.read_text() if input_f else sys.stdin.read()
    processed, errs = transform(raw.splitlines(keepends=True))

    if errs:
        prefix = str(input_f) if input_f else "<stdin>"
        for e in errs:
            print(f"{prefix}: {e}", file=sys.stderr)
        sys.exit(1)
        
    if check:
        print(f"{input_f or '<stdin>'}: OK")
        sys.exit(0)
    else:
        dst = output_f.open("w") if output_f else sys.stdout
        dst.writelines(processed)
        if dst is not sys.stdout:
            dst.close()


if __name__ == "__main__":
    main()
