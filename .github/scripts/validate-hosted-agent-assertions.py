#!/usr/bin/env python3
"""Validate hosted-agent E2E assertions against job artifacts."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


class AssertionsError(ValueError):
    """Raised when an assertions file does not match the supported schema."""


def _require_keys(value: dict[str, Any], allowed: set[str], context: str) -> None:
    unknown = set(value) - allowed
    if unknown:
        raise AssertionsError(f"{context} has unknown key(s): {', '.join(sorted(unknown))}")


def _load_assertions(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise AssertionsError(f"could not read assertions JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise AssertionsError("assertions document must be an object")
    _require_keys(value, {"when", "assertions"}, "document")

    when = value.get("when")
    if not isinstance(when, dict):
        raise AssertionsError("document.when must be an object")
    _require_keys(when, {"toolbox_label"}, "document.when")
    if not isinstance(when.get("toolbox_label"), str) or not when["toolbox_label"]:
        raise AssertionsError("document.when.toolbox_label must be a non-empty string")

    assertions = value.get("assertions")
    if not isinstance(assertions, list) or not assertions:
        raise AssertionsError("document.assertions must be a non-empty array")
    for index, assertion in enumerate(assertions, start=1):
        context = f"document.assertions[{index}]"
        if not isinstance(assertion, dict):
            raise AssertionsError(f"{context} must be an object")
        _require_keys(assertion, {"source", "turn", "regex", "min_matches"}, context)
        source = assertion.get("source")
        if source not in {"response", "console_log"}:
            raise AssertionsError(f"{context}.source must be response or console_log")
        if not isinstance(assertion.get("regex"), str) or not assertion["regex"]:
            raise AssertionsError(f"{context}.regex must be a non-empty string")
        try:
            re.compile(assertion["regex"])
        except re.error as exc:
            raise AssertionsError(f"{context}.regex is invalid: {exc}") from exc
        min_matches = assertion.get("min_matches", 1)
        if not isinstance(min_matches, int) or isinstance(min_matches, bool) or min_matches < 1:
            raise AssertionsError(f"{context}.min_matches must be a positive integer")
        if source == "response":
            turn = assertion.get("turn")
            if not isinstance(turn, int) or isinstance(turn, bool) or turn < 1:
                raise AssertionsError(f"{context}.turn must be a positive integer for response assertions")
        elif "turn" in assertion:
            raise AssertionsError(f"{context}.turn is only supported for response assertions")
    return value


def _write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--assertions-json", type=Path, required=True)
    parser.add_argument("--toolbox-label", default="")
    parser.add_argument("--response-template", required=True)
    parser.add_argument("--console-log", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        document = _load_assertions(args.assertions_json)
    except AssertionsError as exc:
        report = {"status": "invalid", "error": str(exc), "assertions": []}
        _write_report(args.report, report)
        print(f"::error::Invalid hosted-agent assertions: {exc}")
        return 2

    expected_label = document["when"]["toolbox_label"]
    if args.toolbox_label != expected_label:
        report = {
            "status": "not_applicable",
            "reason": f"toolbox_label is {args.toolbox_label!r}, expected {expected_label!r}",
            "assertions": [],
        }
        _write_report(args.report, report)
        print(f"Assertions not applicable: {report['reason']}")
        return 0

    results = []
    failed = False
    for index, assertion in enumerate(document["assertions"], start=1):
        source = assertion["source"]
        if source == "response":
            source_path = Path(args.response_template.format(turn=assertion["turn"]))
        else:
            source_path = args.console_log

        source_exists = source_path.is_file()
        text = source_path.read_text(encoding="utf-8", errors="replace") if source_exists else ""
        matches = len(list(re.finditer(assertion["regex"], text)))
        required = assertion.get("min_matches", 1)
        passed = source_exists and matches >= required
        failed = failed or not passed
        result = {
            "index": index,
            "source": source,
            "source_path": str(source_path),
            "source_exists": source_exists,
            "regex": assertion["regex"],
            "matches": matches,
            "min_matches": required,
            "status": "passed" if passed else "failed",
        }
        if "turn" in assertion:
            result["turn"] = assertion["turn"]
        results.append(result)
        if passed:
            print(f"PASS assertion {index}: {source} matched {matches} time(s)")
        else:
            print(
                f"::error::Hosted-agent assertion {index} failed: {source_path} "
                f"matched {matches} time(s), expected at least {required}"
            )

    report = {"status": "failed" if failed else "passed", "assertions": results}
    _write_report(args.report, report)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
