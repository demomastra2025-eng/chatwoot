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
RUBY_METHOD_PATTERN = re.compile(
    r"^(?P<indent>\s*)def\s+(?:self\.)?(?P<name>[a-zA-Z_][a-zA-Z0-9_]*[!?=]?)(?=\s|\(|;|$)"
)
DESTRUCTIVE_SQL_PATTERN = re.compile(
    r"\b(?:DROP\s+(?:TABLE|INDEX)|TRUNCATE\s+(?:TABLE\s+)?|"
    r"ALTER\s+TABLE\b.*?\b(?:DROP|RENAME)\s+(?:COLUMN\s+)?)",
    re.IGNORECASE | re.DOTALL,
)
CONCURRENT_SQL_INDEX_DROP_PATTERN = re.compile(
    r"\bDROP\s+INDEX\s+CONCURRENTLY\s+(?:IF\s+EXISTS\s+)?"
    r"(?P<name>#\{[A-Z][A-Z0-9_]*\}|[a-zA-Z_][a-zA-Z0-9_]*|['\"][^'\"]+['\"])",
    re.IGNORECASE,
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
            if path.is_file():
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


def existing_files_with_suffixes(paths: Iterable[str], suffixes: set[str]) -> list[str]:
    return sorted(
        path for path in paths if Path(path).suffix in suffixes and Path(path).is_file()
    )


def ruby_method_bodies(content: str) -> dict[str, str]:
    lines = content.splitlines(keepends=True)
    methods: dict[str, str] = {}
    current: list[str] | None = None
    method_name = ""
    method_indent = ""

    for line in lines:
        match = RUBY_METHOD_PATTERN.match(line)
        if match:
            if current:
                methods[method_name] = "".join(current)
            current = [line]
            method_name = match.group("name")
            method_indent = match.group("indent")
            if re.search(r";\s*end\s*$", line):
                methods[method_name] = "".join(current)
                current = None
            continue

        if current is None:
            continue

        current.append(line)
        if line == f"{method_indent}end\n" or line == f"{method_indent}end":
            methods[method_name] = "".join(current)
            current = None

    if current:
        methods[method_name] = "".join(current)
    return methods


def reachable_migration_method_bodies(content: str) -> list[str]:
    methods = ruby_method_bodies(content)
    if not methods:
        return [content]

    pending = [name for name in ("up", "change") if name in methods]
    reachable: list[str] = []
    while pending:
        name = pending.pop()
        if name in reachable:
            continue
        reachable.append(name)
        body = methods[name]
        for helper_name in methods:
            helper_call = rf"(?<![a-zA-Z0-9_]){re.escape(helper_name)}(?![a-zA-Z0-9_])"
            if helper_name not in reachable and re.search(helper_call, body):
                pending.append(helper_name)

    return [methods[name] for name in reachable]


def migration_forward_content(content: str) -> str:
    return "".join(reachable_migration_method_bodies(content))


def without_comment_lines(content: str) -> str:
    return "".join(
        line
        for line in content.splitlines(keepends=True)
        if not line.lstrip().startswith(("#", "--"))
    )


def ruby_call_statements(content: str, call_name: str) -> list[tuple[int, int, str]]:
    lines = content.splitlines(keepends=True)
    offsets: list[int] = []
    offset = 0
    for line in lines:
        offsets.append(offset)
        offset += len(line)

    statements: list[tuple[int, int, str]] = []
    for index, line in enumerate(lines):
        if not re.search(rf"\b{re.escape(call_name)}\b", line):
            continue
        base_indent = len(line) - len(line.lstrip())
        end_index = index + 1
        while end_index < len(lines):
            next_line = lines[end_index]
            if not next_line.strip():
                break
            next_indent = len(next_line) - len(next_line.lstrip())
            if next_indent <= base_indent or re.search(r"\b(?:add_index|remove_index)\b", next_line):
                break
            end_index += 1
        start = offsets[index]
        end = offsets[end_index] if end_index < len(lines) else len(content)
        statements.append((start, end, content[start:end]))
    return statements


def index_name_from_statement(statement: str) -> str | None:
    match = re.search(r"\bname:\s*([A-Z][A-Z0-9_]*|['\"][^'\"]+['\"])", statement)
    return match.group(1) if match else None


def without_safe_concurrent_index_rebuilds(content: str) -> str:
    removals = ruby_call_statements(content, "remove_index")
    additions = ruby_call_statements(content, "add_index")
    safe_ranges: list[tuple[int, int]] = []

    for start, end, statement in removals:
        name = index_name_from_statement(statement)
        if not name or not re.search(r"\balgorithm:\s*:concurrently\b", statement):
            continue
        if any(
            add_start >= end
            and index_name_from_statement(add_statement) == name
            and re.search(r"\balgorithm:\s*:concurrently\b", add_statement)
            for add_start, _add_end, add_statement in additions
        ):
            safe_ranges.append((start, end))

    for start, end in reversed(safe_ranges):
        content = content[:start] + (" " * (end - start)) + content[end:]
    return content


def sql_execute_statements(content: str) -> list[tuple[int, int, str]]:
    lines = content.splitlines(keepends=True)
    offsets: list[int] = []
    offset = 0
    for line in lines:
        offsets.append(offset)
        offset += len(line)

    statements: list[tuple[int, int, str]] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if not re.search(r"\bexecute\b", line):
            index += 1
            continue
        end_index = index + 1
        heredoc = re.search(r"<<[-~]?[\"']?(?P<tag>[A-Z][A-Z0-9_]*)", line)
        if heredoc:
            tag = heredoc.group("tag")
            while end_index < len(lines):
                end_index += 1
                if lines[end_index - 1].strip() == tag:
                    break
        start = offsets[index]
        end = offsets[end_index] if end_index < len(lines) else len(content)
        statements.append((start, end, content[start:end]))
        index = end_index
    return statements


def without_safe_concurrent_sql_index_rebuilds(content: str) -> str:
    statements = sql_execute_statements(content)
    safe_ranges: list[tuple[int, int]] = []
    for statement_index, (start, _end, statement) in enumerate(statements):
        drop = CONCURRENT_SQL_INDEX_DROP_PATTERN.search(statement)
        if not drop:
            continue
        index_name = re.escape(drop.group("name"))
        create_pattern = re.compile(
            rf"\bCREATE\s+(?:UNIQUE\s+)?INDEX\s+CONCURRENTLY\s+"
            rf"(?:IF\s+NOT\s+EXISTS\s+)?{index_name}(?![a-zA-Z0-9_])",
            re.IGNORECASE,
        )
        if any(create_pattern.search(later[2]) for later in statements[statement_index + 1 :]):
            safe_ranges.append((start + drop.start(), start + drop.end()))

    for start, end in reversed(safe_ranges):
        content = content[:start] + (" " * (end - start)) + content[end:]
    return content


def validate_migrations(paths: Iterable[str]) -> list[str]:
    violations: list[str] = []
    for raw_path in paths:
        if not raw_path.startswith("db/migrate/") or not raw_path.endswith(".rb"):
            continue
        path = Path(raw_path)
        if not path.is_file():
            continue
        method_bodies = reachable_migration_method_bodies(path.read_text(encoding="utf-8"))
        method_bodies = [without_comment_lines(body) for body in method_bodies]
        method_bodies = [without_safe_concurrent_index_rebuilds(body) for body in method_bodies]
        method_bodies = [without_safe_concurrent_sql_index_rebuilds(body) for body in method_bodies]
        if any(
            DESTRUCTIVE_MIGRATION_PATTERN.search(body) or DESTRUCTIVE_SQL_PATTERN.search(body)
            for body in method_bodies
        ):
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
            selected = existing_files_with_suffixes(files, RUBY_SUFFIXES)
        elif args.list == "frontend":
            selected = existing_files_with_suffixes(files, FRONTEND_SUFFIXES)
        elif args.list == "specs":
            selected = related_specs(files)
        elif args.list == "migrations":
            selected = [path for path in files if path.startswith("db/migrate/")]
        sys.stdout.write("".join(f"{path}\n" for path in selected))
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
