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
)
IMMUTABLE_RELEASE_SIDECAR_ROOTS = ("services/onelink-ai-voice/",)
# Captain control is enforced through model callbacks, so its regression specs
# (including the legacy-column rollout bridge) live with the models.
CAPTAIN_CONTROL_SPECS = (
    "spec/models/conversation_spec.rb",
    "spec/enterprise/models/message_spec.rb",
)
# The Captain takeover callback runs before every public reply in every inbox,
# so its changes also run the reply paths that rely on the caller's cached
# conversation inbox, channel and communication thread.
MESSAGE_CALLBACK_SPECS = CAPTAIN_CONTROL_SPECS + (
    "spec/listeners/action_cable_listener_spec.rb",
    "spec/listeners/whatsapp_typing_listener_spec.rb",
    "spec/services/messages/update_content_service_spec.rb",
    "spec/services/whatsapp_web/send_on_whatsapp_web_service_spec.rb",
)
COMPANION_SPECS = {
    "enterprise/app/services/captain/conversation/": CAPTAIN_CONTROL_SPECS,
    "enterprise/app/models/enterprise/conversation.rb": CAPTAIN_CONTROL_SPECS,
    "enterprise/app/models/enterprise/message.rb": MESSAGE_CALLBACK_SPECS,
}
DESTRUCTIVE_MIGRATION_PATTERN = re.compile(
    r"\b(remove_column|remove_columns|drop_table|rename_column|change_column|"
    r"change_column_null|change_column_default|remove_index|rename_table)\b"
)
# This one guarded SET DEFAULT only repairs a missing UUID generator on an
# existing CRM table. Keep the exception bound to this migration and its exact
# nil checks; unmatched default changes remain destructive.
SAFE_STAGE_VISIT_UUID_DEFAULT_MIGRATION = "db/migrate/20261004120100_create_crm_lifecycle_tables.rb"
SAFE_STAGE_VISIT_UUID_DEFAULT_BLOCK = re.compile(
    r"""
    correlation_id_column\s*=\s*connection\.columns\(\s*:crm_stage_visits\s*\)\.find\s+do\s*\|\s*column\s*\|\s*
        column\.name\s*==\s*'correlation_id'\s*
    end\s*
    raise\s+'crm_stage_visits\.correlation_id\s+is\s+missing'\s+unless\s+correlation_id_column\s*
    actual_uuid_defaults\s*=\s*\[\s*
        correlation_id_column\.default\s*,\s*correlation_id_column\.default_function\s*
    \]\s*
    has_expected_uuid_default\s*=\s*actual_uuid_defaults\.include\?\(\s*'gen_random_uuid\(\)'\s*\)\s*
    has_no_uuid_default\s*=\s*actual_uuid_defaults\.all\?\(\s*&:nil\?\s*\)\s*
    if\s+has_no_uuid_default\s*
    change_column_default\s*\(\s*:crm_stage_visits\s*,\s*:correlation_id\s*,
        \s*->\s*\{\s*'gen_random_uuid\(\)'\s*\}\s*\)\s*
    elsif\s+!has_expected_uuid_default\s*
    raise\s+["']Unexpected\s+crm_stage_visits\.correlation_id\s+default:\s*
        \#\{actual_uuid_defaults\.inspect\}["']\s*
    end
    """,
    re.DOTALL | re.VERBOSE,
)
# Production runs migrations while the previous release is still serving, so an
# "expand" migration must also be cheap and short-locked, not only additive.
# These rules flag the statements that hold a strong lock for as long as the
# table is large; each one has a safe form (see script/onelink/README.md).
UNSAFE_UPDATE_PATTERN = re.compile(r"\bUPDATE\s+\S+\s+SET\b|\.update_all\b", re.IGNORECASE)
BATCHING_MARKER_PATTERN = re.compile(
    r"\b(in_batches|find_in_batches|find_each|each_batch|each_id_range|BATCH_SIZE)\b"
    r"|\bLIMIT\s+(\d|#\{)",
    re.IGNORECASE,
)
CREATE_TABLE_PATTERN = re.compile(r"\bcreate_table\s*\(?\s*:(\w+)")
FIRST_TABLE_ARGUMENT_PATTERN = re.compile(r"\(?\s*:(\w+)")
ENFORCED_FOREIGN_KEY_PATTERN = re.compile(r"foreign_key:\s*(true\b|\{)")
CONCURRENT_INDEX_PATTERN = re.compile(r"algorithm:\s*:concurrently")
UNINDEXED_REFERENCE_PATTERN = re.compile(r"index:\s*(false\b|\{[^}]*algorithm:\s*:concurrently)")
NOT_VALID_PATTERN = re.compile(r"validate:\s*false\b")


def strip_ruby_comments(content: str) -> str:
    return "\n".join(
        line for line in content.splitlines() if not line.lstrip().startswith("#")
    )


def statement_arguments(content: str, start: int) -> str:
    """Return the arguments of the Ruby call that begins at ``start``.

    The call ends at the first newline outside brackets and quotes that does not
    continue the expression (trailing comma, operator or backslash).
    """
    depth = 0
    quote = ""
    index = start
    while index < len(content):
        char = content[index]
        if quote:
            if char == "\\":
                index += 1
            elif char == quote:
                quote = ""
        elif char in "'\"":
            quote = char
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "\n" and depth <= 0:
            before = content[start:index].rstrip()
            following = content[index:].lstrip()
            if not (before.endswith((",", "\\", "(", "||", "&&", "+")) or following.startswith(".")):
                break
        index += 1
    return content[start:index]


def calls(content: str, name: str) -> list[str]:
    pattern = re.compile(rf"(?<![\w:])(?:\w+\.)?{re.escape(name)}\b")
    return [statement_arguments(content, match.end()) for match in pattern.finditer(content)]


def unsafe_migration_rules(content: str) -> list[str]:
    """Names the lock-heavy statements in a migration; empty when it is a safe expand."""
    code = strip_ruby_comments(content)
    created_tables = set(CREATE_TABLE_PATTERN.findall(code))
    rules: list[str] = []

    def on_existing_table(arguments: str) -> bool:
        match = FIRST_TABLE_ARGUMENT_PATTERN.match(arguments)
        return not (match and match.group(1) in created_tables)

    if any(
        on_existing_table(arguments) and not CONCURRENT_INDEX_PATTERN.search(arguments)
        for arguments in calls(code, "add_index")
    ):
        rules.append("add_index without algorithm: :concurrently")
    if any(not NOT_VALID_PATTERN.search(arguments) for arguments in calls(code, "add_foreign_key")):
        rules.append("add_foreign_key without validate: false")
    if any(not NOT_VALID_PATTERN.search(arguments) for arguments in calls(code, "add_check_constraint")):
        rules.append("add_check_constraint without validate: false")
    references = calls(code, "add_reference") + calls(code, "add_belongs_to")
    if any(
        on_existing_table(arguments)
        and (ENFORCED_FOREIGN_KEY_PATTERN.search(arguments) or not UNINDEXED_REFERENCE_PATTERN.search(arguments))
        for arguments in references
    ):
        rules.append("add_reference with a foreign key or a non-concurrent index")
    table_references = calls(code, "t.references") + calls(code, "t.belongs_to")
    if any(ENFORCED_FOREIGN_KEY_PATTERN.search(arguments) for arguments in table_references):
        rules.append("create_table references with an enforced foreign key")
    if UNSAFE_UPDATE_PATTERN.search(code) and not BATCHING_MARKER_PATTERN.search(code):
        rules.append("UPDATE of existing rows without batches")
    return rules



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
        not path.startswith(SIDECAR_ROOTS)
        and (
            Path(path).suffix in FRONTEND_SUFFIXES
            or path.startswith(FRONTEND_ROOTS)
            or path in {"package.json", "pnpm-lock.yaml", "vite.config.mts"}
        )
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
        for prefix, companions in COMPANION_SPECS.items():
            if raw_path.startswith(prefix):
                specs.update(spec for spec in companions if Path(spec).is_file())
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


def frontend_files(paths: Iterable[str]) -> list[str]:
    return existing_files_with_suffixes(
        (path for path in paths if not path.startswith(SIDECAR_ROOTS)),
        FRONTEND_SUFFIXES,
    )


def migration_violations(paths: Iterable[str]) -> list[tuple[str, str]]:
    """Return (path, rule) for every changed migration that is not a safe expand."""
    violations: list[tuple[str, str]] = []
    for raw_path in paths:
        if not raw_path.startswith("db/migrate/") or not raw_path.endswith(".rb"):
            continue
        path = Path(raw_path)
        if not path.is_file():
            continue
        content = path.read_text(encoding="utf-8")
        if raw_path == SAFE_STAGE_VISIT_UUID_DEFAULT_MIGRATION:
            content = SAFE_STAGE_VISIT_UUID_DEFAULT_BLOCK.sub("", content)
        if DESTRUCTIVE_MIGRATION_PATTERN.search(content):
            violations.append((raw_path, "destructive or contracting schema change"))
        violations.extend((raw_path, rule) for rule in unsafe_migration_rules(content))
    return violations


def validate_migrations(paths: Iterable[str]) -> list[str]:
    return list(dict.fromkeys(path for path, _ in migration_violations(paths)))


def unsupported_release_sidecars(paths: Iterable[str]) -> list[str]:
    return sorted(
        path
        for path in paths
        if path.startswith(SIDECAR_ROOTS)
        and not path.startswith(IMMUTABLE_RELEASE_SIDECAR_ROOTS)
    )


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
            selected = frontend_files(files)
        elif args.list == "specs":
            selected = related_specs(files)
        elif args.list == "migrations":
            selected = [path for path in files if path.startswith("db/migrate/")]
        sys.stdout.write("".join(f"{path}\n" for path in selected))
    elif not args.github_output:
        print(json.dumps({"files": files, "plan": plan}, sort_keys=True))

    if args.validate_migrations:
        violations = migration_violations(files)
        if violations:
            print(
                "Automatic releases accept short-locked expand migrations only (additive, "
                "NOT VALID keys and checks, concurrent indexes, batched backfills). "
                "Run destructive contract cleanup as a separate reviewed maintenance task:",
                file=sys.stderr,
            )
            for path, rule in violations:
                print(f"  - {path}: {rule}", file=sys.stderr)
            return 2
    if args.validate_release_surface:
        sidecar_files = unsupported_release_sidecars(files)
        if sidecar_files:
            print(
                "This release changes sidecars that are not covered by the immutable "
                "release workflow:",
                file=sys.stderr,
            )
            for path in sidecar_files:
                print(f"  - {path}", file=sys.stderr)
            return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
