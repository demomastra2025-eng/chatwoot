#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


FILE_MAP = {
    "application": "application_swagger.json",
    "client": "client_swagger.json",
    "platform": "platform_swagger.json",
    "other": "other_swagger.json",
}


def candidate_dirs() -> list[Path]:
    dirs = []
    env_dir = os.environ.get("ONE_LINK_OPENAPI_DIR")
    if env_dir:
        dirs.append(Path(env_dir).expanduser())
    dirs.extend(
        [
            Path.cwd() / "docs" / "openapi",
            Path.cwd().parent / "docs" / "openapi",
            Path.home() / "onelink" / "docs" / "openapi",
            Path.home() / ".claude" / "skills" / "onelink-integrator" / "references" / "openapi",
        ]
    )
    seen = []
    for path in dirs:
        if path not in seen:
            seen.append(path)
    return seen


def resolve_openapi_dir() -> Path | None:
    for path in candidate_dirs():
        if path.is_dir() and any((path / name).exists() for name in FILE_MAP.values()):
            return path
    return None


def load_surface(path: Path) -> dict:
    return json.loads(path.read_text())


def iter_matches(doc: dict, query: str):
    query_lower = query.lower()
    for path, methods in doc.get("paths", {}).items():
        if query_lower in path.lower():
            yield path, None, None
        if not isinstance(methods, dict):
            continue
        for method, operation in methods.items():
            if not isinstance(operation, dict):
                continue
            haystacks = [
                operation.get("summary", ""),
                operation.get("description", ""),
                " ".join(operation.get("tags", []) or []),
            ]
            if any(query_lower in str(value).lower() for value in haystacks):
                yield path, method.upper(), operation.get("summary")


def main() -> int:
    parser = argparse.ArgumentParser(description="Search local One Link OpenAPI files.")
    parser.add_argument("query", help="Keyword to search in path names, summaries, and tags.")
    parser.add_argument(
        "--surface",
        choices=["application", "client", "platform", "other", "all"],
        default="all",
        help="Limit search to one OpenAPI surface.",
    )
    args = parser.parse_args()

    openapi_dir = resolve_openapi_dir()
    if openapi_dir is None:
        print("No local OpenAPI directory found.")
        print("Set ONE_LINK_OPENAPI_DIR or place the current One Link OpenAPI files in one of these locations:")
        for path in candidate_dirs():
            print(f"  - {path}")
        return 1

    surfaces = FILE_MAP.keys() if args.surface == "all" else [args.surface]
    found = False
    print(f"Using OpenAPI directory: {openapi_dir}")
    for surface in surfaces:
        path = openapi_dir / FILE_MAP[surface]
        if not path.exists():
            continue
        doc = load_surface(path)
        matches = list(iter_matches(doc, args.query))
        if not matches:
            continue
        found = True
        print(f"\n## {surface}")
        seen = set()
        for route, method, summary in matches:
            key = (route, method, summary)
            if key in seen:
                continue
            seen.add(key)
            if method:
                print(f"{method:6} {route}  {summary or ''}".rstrip())
            else:
                print(f"PATH   {route}")

    if not found:
        print(f'No matches for "{args.query}" in {openapi_dir}.')
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
