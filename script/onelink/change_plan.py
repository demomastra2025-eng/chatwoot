#!/usr/bin/env python3
"""Classify a Git range for OneLink CI and enforce migration release policy."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Iterable

RUBY_SUFFIXES = {".rb", ".rake"}
FRONTEND_SUFFIXES = {
    ".cjs",
    ".css",
    ".js",
    ".jsx",
    ".mjs",
    ".mts",
    ".scss",
    ".ts",
    ".tsx",
    ".vue",
}
RUBY_ROOTS = ("app/", "config/", "db/", "enterprise/", "lib/", "spec/")
FRONTEND_ROOTS = ("app/javascript/", "enterprise/app/javascript/", "test/", "tests/")
CONTAINER_FILES = {
    "Dockerfile",
    "Gemfile",
    "Gemfile.lock",
    "package.json",
    "pnpm-lock.yaml",
    "docker/Dockerfile",
    ".dockerignore",
}
HIGH_RISK_ROOTS = (
    ".github/workflows/",
    "config/initializers/",
    "config/routes",
    "db/migrate/",
    "deploy/",
    "docker/",
    "enterprise/app/policies/",
    "app/policies/",
    "app/jobs/",
    "app/services/whatsapp/",
    "app/services/telegram/",
    "app/services/telephony/",
    "services/onelink-ai-voice/",
    "services/onelink-ai-voice-pipecat/",
)
SIDECAR_ROOTS = (
    "enterprise/media-server/",
    "services/onelink-ai-voice/",
    "services/onelink-ai-voice-pipecat/",
    "services/weixin-personal-gateway/",
)
DESTRUCTIVE_MIGRATION_PATTERN = re.compile(
    r"\b(remove_column|remove_columns|drop_table|rename_column|change_column|"
    r"change_column_null|change_column_default|remove_index|rename_table)\b"
)



def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], check=True, text=True, stdout=subprocess.PIPE
    ).stdout


def changed_files(base: str, head: str) -> list[str]:
    output = git("diff", "--name-only", "--diff-filter=ACMRD", base, head)
    return sorted({line.strip() for line in output.splitlines() if line.strip()})


def classify(paths: Iterable[str]) -> dict[str, bool]:
    files = list(paths)
    backend = any(
        Path(path).suffix in RUBY_SUFFIXES
        or path.startswith(RUBY_ROOTS)
        or path in {"Gemfile", "Gemfile.lock"}
        for path in files
    )
    frontend = any(
        Path(path).suffix in FRONTEND_SUFFIXES
        or path.startswith(FRONTEND_ROOTS)
        or path in {"package.json", "pnpm-lock.yaml", "vite.config.mts"}
        for path in files
    )
    migrations = any(path.startswith("db/migrate/") for path in files)
    container = any(
        path in CONTAINER_FILES
        or path.endswith("/Dockerfile")
        or path.startswith("docker-compose")
        or path.startswith("docker/")
        for path in files
    )
    high_risk = any(path.startswith(HIGH_RISK_ROOTS) for path in files)
    sidecar = any(path.startswith(SIDECAR_ROOTS) for path in files)
    runtime = any(
        not path.startswith(("docs/", ".github/"))
        and not path.lower().endswith((".md", ".mdx"))
        for path in files
    )
    return {
        "backend": backend,
        "container": container,
        "frontend": frontend,
        "high_risk": high_risk,
        "migrations": migrations,
        "runtime": runtime,
        "sidecar": sidecar,
    }


def related_specs(paths: Iterable[str]) -> list[str]:
    specs: set[str] = set()
    for raw_path in paths:
        path = Path(raw_path)
        if raw_path.startswith("spec/") and raw_path.endswith("_spec.rb"):
            specs.add(raw_path)
            continue
        if path.suffix != ".rb":
            continue
        if raw_path.startswith("enterprise/app/"):
            candidate = Path("spec/enterprise") / Path(raw_path).relative_to("enterprise/app")
        elif raw_path.startswith("app/"):
            candidate = Path("spec") / Path(raw_path).relative_to("app")
        elif raw_path.startswith("lib/"):
            candidate = Path("spec") / path
        else:
            continue
        candidate = candidate.with_name(f"{candidate.stem}_spec.rb")
        if candidate.is_file():
            specs.add(candidate.as_posix())
    return sorted(specs)


def validate_migrations(paths: Iterable[str]) -> list[str]:
    violations: list[str] = []
    for raw_path in paths:
        if not raw_path.startswith("db/migrate/") or not raw_path.endswith(".rb"):
            continue
        path = Path(raw_path)
        if not path.is_file():
            continue
        content = path.read_text(encoding="utf-8")
        if DESTRUCTIVE_MIGRATION_PATTERN.search(content):
            violations.append(raw_path)
    return violations


def emit_github_output(path: Path, plan: dict[str, bool], files: list[str]) -> None:
    with path.open("a", encoding="utf-8") as output:
        for key, value in sorted(plan.items()):
            output.write(f"{key}={'true' if value else 'false'}\n")
        output.write(f"changed_count={len(files)}\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument(
        "--list", choices=("files", "ruby", "frontend", "specs", "migrations")
    )
    parser.add_argument("--validate-migrations", action="store_true")
    parser.add_argument("--validate-release-surface", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    files = changed_files(args.base, args.head)
    plan = classify(files)

    if args.github_output:
        emit_github_output(args.github_output, plan, files)

    if args.list:
        selected = files
        if args.list == "ruby":
            selected = [path for path in files if Path(path).suffix in RUBY_SUFFIXES]
        elif args.list == "frontend":
            selected = [path for path in files if Path(path).suffix in FRONTEND_SUFFIXES]
        elif args.list == "specs":
            selected = related_specs(files)
        elif args.list == "migrations":
            selected = [path for path in files if path.startswith("db/migrate/")]
        print("\n".join(selected))
    elif not args.github_output:
        print(json.dumps({"files": files, "plan": plan}, sort_keys=True))

    if args.validate_migrations:
        violations = validate_migrations(files)
        if violations:
            print(
                "Automatic releases accept expand-compatible migrations only. "
                "Run destructive contract cleanup as a separate reviewed maintenance task:",
                file=sys.stderr,
            )
            for violation in violations:
                print(f"  - {violation}", file=sys.stderr)
            return 2
    if args.validate_release_surface:
        sidecar_files = [path for path in files if path.startswith(SIDECAR_ROOTS)]
        if sidecar_files:
            print(
                "This release changes embedded sidecars that require their own immutable "
                "images and rollout workflow:",
                file=sys.stderr,
            )
            for path in sidecar_files:
                print(f"  - {path}", file=sys.stderr)
            return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
