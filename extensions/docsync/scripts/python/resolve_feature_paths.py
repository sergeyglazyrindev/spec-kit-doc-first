#!/usr/bin/env python3
"""Resolve the active feature's artifact paths for the docsync extension.

Deliberately self-contained: the docsync extension owns this script rather
than depending on core's ``check_prerequisites.py``, so
``speckit.docsync.usespec`` and ``speckit.docsync.refreshspec`` keep working
regardless of core's command set. It is a trimmed twin of core
``check_prerequisites.py``'s ``--paths-only`` mode -- it resolves the project
root and the active feature directory and reports every artifact path next
to it, without requiring any of them to exist (paths-only resolution
performs no validation; callers decide what a missing file means for them).
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

HELP_TEXT = """Usage: resolve_feature_paths.py [OPTIONS]

Resolve the active feature's artifact paths for the docsync extension.

OPTIONS:
  --json        Output in JSON format
  --paths-only  Accepted for call-site symmetry with core's
                check_prerequisites.py; this script only ever resolves
                paths, so the flag is a no-op.
  --help, -h    Show this help message

EXAMPLES:
  ./resolve_feature_paths.py --json
"""


def _die(*lines: str) -> "None":
    for line in lines:
        print(line, file=sys.stderr)
    raise SystemExit(1)


def find_specify_root(start_dir: Path | None = None) -> Path | None:
    """Find the project root by searching upward for the .specify marker."""
    current = (start_dir or Path.cwd()).resolve()
    while True:
        if (current / ".specify").is_dir():
            return current
        parent = current.parent
        if parent == current:
            return None
        current = parent


def get_project_root(script_file: Path) -> Path:
    """Resolve the project root, honouring an explicit SPECIFY_INIT_DIR override.

    Mirrors core ``get_repo_root``: strict on an invalid override, with no
    silent fallback to the current directory.
    """
    raw = os.environ.get("SPECIFY_INIT_DIR", "")
    if raw:
        candidate = Path(raw)
        if not candidate.is_absolute():
            candidate = Path.cwd() / candidate
        try:
            init_root = candidate.resolve(strict=True)
        except OSError:
            init_root = None
        if init_root is None or not init_root.is_dir():
            _die(
                "ERROR: SPECIFY_INIT_DIR does not point to an existing "
                f"directory: {raw}"
            )
        if not (init_root / ".specify").is_dir():
            _die(
                "ERROR: SPECIFY_INIT_DIR is not a Spec Kit project "
                f"(no .specify/ directory): {init_root}"
            )
        return init_root

    root = find_specify_root()
    if root is not None:
        return root

    # Installed scripts live at .specify/extensions/docsync/scripts/python/.
    root = find_specify_root(script_file.resolve().parent)
    if root is not None:
        return root

    _die("ERROR: Not inside a Spec Kit project (no .specify/ directory found).")
    raise AssertionError("unreachable")  # pragma: no cover - _die always exits


def read_feature_json_feature_directory(repo_root: Path) -> str:
    """Read .specify/feature.json's feature_directory value, or empty string."""
    feature_json = repo_root / ".specify" / "feature.json"
    if not feature_json.is_file():
        return ""
    try:
        data = json.loads(feature_json.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return ""
    value = data.get("feature_directory") if isinstance(data, dict) else None
    return value if isinstance(value, str) else ""


def persist_feature_json(repo_root: Path, feature_dir_value: str) -> None:
    """Write feature_directory to .specify/feature.json when it changed.

    Mirrors core's persist_feature_json, including the lexical prefix strip:
    with a symlinked <repo>/specs, resolve() would escape the repo and persist
    a machine-specific absolute path rather than the relative "specs/NNN-name"
    the bash and PowerShell twins store.
    """
    value = feature_dir_value
    relative = Path(value)
    if relative.is_absolute():
        try:
            value = relative.relative_to(repo_root).as_posix()
        except ValueError:
            value = str(relative)

    if read_feature_json_feature_directory(repo_root) == value:
        return

    specify_dir = repo_root / ".specify"
    specify_dir.mkdir(parents=True, exist_ok=True)
    (specify_dir / "feature.json").write_bytes(
        (json.dumps({"feature_directory": value}, separators=(",", ":")) + "\n").encode(
            "utf-8"
        )
    )


def main(argv: list[str]) -> int:
    json_mode = False
    for arg in argv:
        if arg == "--json":
            json_mode = True
        elif arg == "--paths-only":
            pass
        elif arg in ("--help", "-h"):
            print(HELP_TEXT, end="")
            return 0
        else:
            print(
                f"ERROR: Unknown option '{arg}'. Use --help for usage information.",
                file=sys.stderr,
            )
            return 1

    repo_root = get_project_root(Path(__file__))

    # Resolve the feature directory. Priority:
    #   1. SPECIFY_FEATURE_DIRECTORY (explicit override)
    #   2. .specify/feature.json "feature_directory"
    # No feature on record is a distinct, recognizable failure (this exact
    # message) so callers such as speckit.docsync.usespec can treat "no
    # current feature yet" as a branch to handle rather than a hard stop.
    raw_feature_dir = os.environ.get("SPECIFY_FEATURE_DIRECTORY", "")
    if raw_feature_dir and os.environ.get("SPECIFY_FEATURE_NO_PERSIST", "") not in (
        "1",
        "true",
    ):
        persist_feature_json(repo_root, raw_feature_dir)
    if not raw_feature_dir:
        raw_feature_dir = read_feature_json_feature_directory(repo_root)
        if not raw_feature_dir:
            _die(
                "ERROR: No current feature on record. Set SPECIFY_FEATURE_DIRECTORY, "
                "or run the Spec Kit specify command (or speckit.docsync.usespec) "
                "to create .specify/feature.json."
            )

    feature_dir = Path(raw_feature_dir)
    if not feature_dir.is_absolute():
        feature_dir = repo_root / feature_dir

    if not feature_dir.is_dir():
        _die(
            f"ERROR: Feature directory not found: {feature_dir}",
            "Run the Spec Kit specify command (or speckit.docsync.usespec) "
            "first to create the feature structure.",
        )

    paths = {
        "REPO_ROOT": str(repo_root),
        "FEATURE_DIR": str(feature_dir),
        "FEATURE_SPEC": str(feature_dir / "spec.md"),
        "IMPL_PLAN": str(feature_dir / "plan.md"),
        "TASKS": str(feature_dir / "tasks.md"),
        "RESEARCH": str(feature_dir / "research.md"),
        "DATA_MODEL": str(feature_dir / "data-model.md"),
        "QUICKSTART": str(feature_dir / "quickstart.md"),
        "CONTRACTS_DIR": str(feature_dir / "contracts"),
    }

    if json_mode:
        sys.stdout.write(json.dumps(paths, separators=(",", ":")) + "\n")
    else:
        for key, value in paths.items():
            print(f"{key}:{value}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
