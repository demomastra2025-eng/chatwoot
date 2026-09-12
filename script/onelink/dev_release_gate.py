#!/usr/bin/env python3
"""Fail-closed ancestry, contract, and semantic rollback gate for DEV releases."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
CRITICAL_PREFIXES = (
    "app/controllers/api/v1/accounts/scheduling/",
    "app/services/integrations/medelement/",
    "app/services/scheduling/",
    "spec/requests/api/v1/accounts/scheduling/",
    "spec/services/integrations/medelement/",
)


class GateError(RuntimeError):
    pass


@dataclass(frozen=True)
class Change:
    status: str
    paths: tuple[str, ...]

    @property
    def critical(self) -> bool:
        return any(path.startswith(CRITICAL_PREFIXES) for path in self.paths)

    @property
    def deleted(self) -> bool:
        return self.status.startswith("D")


@dataclass(frozen=True)
class ContractManifest:
    required_ancestor: str
    protected_files: dict[str, str]
    contract_specs: tuple[str, ...]


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=check,
        capture_output=True,
        text=True,
    )


def validate_commit(repo: Path, sha: str, label: str) -> None:
    if not SHA_PATTERN.fullmatch(sha):
        raise GateError(f"{label} is not a full lowercase SHA: {sha!r}")
    result = git(repo, "cat-file", "-e", f"{sha}^{{commit}}", check=False)
    if result.returncode != 0:
        raise GateError(f"{label} commit is unavailable in the deployment repository: {sha}")


def read_live_sha(current: Path) -> str:
    marker = current / ".git_sha"
    try:
        sha = marker.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise GateError(f"cannot read live SHA marker {marker}: {error}") from error
    if not SHA_PATTERN.fullmatch(sha):
        raise GateError(f"invalid live SHA marker {marker}: {sha!r}")
    return sha


def load_contract_manifest(path: Path) -> ContractManifest:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if payload.get("version") != 1:
            raise ValueError("unsupported manifest version")
        required_ancestor = payload["required_ancestor"]
        protected_files = payload["protected_files"]
        contract_specs = tuple(payload["contract_specs"])
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise GateError(f"invalid contract manifest {path}: {error}") from error

    if not SHA_PATTERN.fullmatch(required_ancestor):
        raise GateError("contract manifest required_ancestor is not a full lowercase SHA")
    if not isinstance(protected_files, dict) or not protected_files:
        raise GateError("contract manifest protected_files must be a non-empty object")
    if not contract_specs or any(not isinstance(path, str) or not path for path in contract_specs):
        raise GateError("contract manifest contract_specs must be a non-empty string list")
    for protected_path, digest in protected_files.items():
        if not isinstance(protected_path, str) or protected_path.startswith("/") or ".." in Path(protected_path).parts:
            raise GateError(f"invalid protected path in contract manifest: {protected_path!r}")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise GateError(f"invalid baseline SHA-256 for protected path: {protected_path}")
    return ContractManifest(required_ancestor, protected_files, contract_specs)


def is_ancestor(repo: Path, ancestor: str, candidate: str) -> bool:
    result = git(repo, "merge-base", "--is-ancestor", ancestor, candidate, check=False)
    if result.returncode not in (0, 1):
        raise GateError(result.stderr.strip() or "git merge-base failed")
    return result.returncode == 0


def change_plan(repo: Path, live_sha: str, candidate_sha: str) -> list[Change]:
    output = git(repo, "diff", "--name-status", "--find-renames", live_sha, candidate_sha).stdout
    changes: list[Change] = []
    for line in output.splitlines():
        fields = line.split("\t")
        if len(fields) < 2:
            continue
        changes.append(Change(status=fields[0], paths=tuple(fields[1:])))
    return changes


def object_id(repo: Path, sha: str, path: str) -> str | None:
    result = git(repo, "rev-parse", f"{sha}:{path}", check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def validate_manifest_baseline(repo: Path, manifest: ContractManifest) -> None:
    validate_commit(repo, manifest.required_ancestor, "contract baseline SHA")
    for path, expected_digest in manifest.protected_files.items():
        result = git(repo, "show", f"{manifest.required_ancestor}:{path}", check=False)
        if result.returncode != 0:
            raise GateError(f"protected file is missing from contract baseline: {path}")
        actual_digest = hashlib.sha256(result.stdout.encode()).hexdigest()
        if actual_digest != expected_digest:
            raise GateError(f"contract baseline hash mismatch for protected file: {path}")


def historical_object_ids(repo: Path, live_sha: str, path: str) -> set[str]:
    live_object_id = object_id(repo, live_sha, path)
    commits = git(repo, "log", "--first-parent", "--format=%H", live_sha, "--", path).stdout.splitlines()
    historical: set[str] = set()
    for commit in commits:
        commit_object_id = object_id(repo, commit, path)
        if commit_object_id and commit_object_id != live_object_id:
            historical.add(commit_object_id)
    return historical


def semantic_rollbacks(repo: Path, live_sha: str, candidate_sha: str, manifest: ContractManifest, changed_paths: set[str]) -> list[str]:
    rollbacks: list[str] = []
    for path in manifest.protected_files.keys() & changed_paths:
        live_object_id = object_id(repo, live_sha, path)
        candidate_object_id = object_id(repo, candidate_sha, path)
        if candidate_object_id and candidate_object_id != live_object_id and candidate_object_id in historical_object_ids(repo, live_sha, path):
            rollbacks.append(path)
    return rollbacks


def critical_revert_commits(repo: Path, live_sha: str, candidate_sha: str, manifest: ContractManifest | None) -> list[str]:
    paths = list(CRITICAL_PREFIXES)
    if manifest:
        paths.extend(manifest.protected_files)
    output = git(repo, "log", "--format=%H%x09%s", f"{live_sha}..{candidate_sha}", "--", *paths).stdout
    return [line for line in output.splitlines() if "\tRevert " in line]


def evaluate(
    repo: Path,
    live_sha: str,
    candidate_sha: str,
    allow_rollback: bool = False,
    manifest: ContractManifest | None = None,
) -> list[Change]:
    validate_commit(repo, live_sha, "live SHA")
    validate_commit(repo, candidate_sha, "candidate SHA")
    if manifest:
        validate_manifest_baseline(repo, manifest)

    changes = change_plan(repo, live_sha, candidate_sha)
    changed_paths = {path for change in changes for path in change.paths}
    protected_paths = set(manifest.protected_files) if manifest else set()
    contract_paths = protected_paths | (set(manifest.contract_specs) if manifest else set())
    descendant = is_ancestor(repo, live_sha, candidate_sha)
    unified_descendant = not manifest or is_ancestor(repo, manifest.required_ancestor, candidate_sha)
    critical_changes = [change for change in changes if change.critical or contract_paths.intersection(change.paths)]
    critical_deletions = [change for change in critical_changes if change.deleted]
    missing_contract_paths = sorted(path for path in contract_paths if object_id(repo, candidate_sha, path) is None)
    reverts = critical_revert_commits(repo, live_sha, candidate_sha, manifest) if descendant else []
    rollbacks = semantic_rollbacks(repo, live_sha, candidate_sha, manifest, changed_paths) if descendant and manifest else []

    print(f"live_sha={live_sha}")
    print(f"candidate_sha={candidate_sha}")
    print(f"candidate_descends_from_live={'yes' if descendant else 'no'}")
    if manifest:
        print(f"required_ancestor={manifest.required_ancestor}")
        print(f"candidate_descends_from_required_ancestor={'yes' if unified_descendant else 'no'}")
        print(f"protected_contract_files={len(manifest.protected_files)}")
        print(f"contract_specs={len(manifest.contract_specs)}")
    print(f"contract_tests_required={'true' if critical_changes else 'false'}")
    for change in changes:
        marker = " critical" if change in critical_changes else ""
        joined_paths = "\t".join(change.paths)
        print(f"change={change.status}\t{joined_paths}{marker}")
    for revert in reverts:
        print(f"critical_revert={revert}")
    for path in rollbacks:
        print(f"semantic_rollback={path}")
    for path in missing_contract_paths:
        print(f"missing_contract_path={path}")

    violations: list[str] = []
    if not descendant:
        violations.append("candidate is divergent/non-descendant from the actual live SHA")
    if not unified_descendant:
        violations.append("candidate does not descend from the required unified contract SHA")
    if critical_deletions or reverts:
        violations.append("candidate removes or explicitly reverts scheduling/provider-critical code")
    if missing_contract_paths:
        violations.append("candidate is missing files required by the scheduling/provider contract manifest")
    if rollbacks:
        violations.append("candidate restores historical protected contract content in a descendant commit")
    if violations and not allow_rollback:
        raise GateError("; ".join(violations))

    print("gate_status=rollback-authorized" if violations else "gate_status=pass")
    return changes


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--current", required=True, type=Path)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--contract-manifest", required=True, type=Path)
    parser.add_argument("--allow-rollback", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        live_sha = read_live_sha(args.current)
        manifest = load_contract_manifest(args.contract_manifest)
        evaluate(args.repo, live_sha, args.candidate, allow_rollback=args.allow_rollback, manifest=manifest)
    except GateError as error:
        print(f"gate_status=blocked\nreason={error}", file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
