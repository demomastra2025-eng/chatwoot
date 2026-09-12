#!/usr/bin/env python3
"""Verify that every tracked blob in a release matches an exact Git commit."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Entry:
    mode: str
    object_type: str
    object_id: str
    path: str


def git(repo: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace").strip())
    return result.stdout


def tracked_entries(repo: Path, sha: str) -> list[Entry]:
    output = git(repo, "ls-tree", "-r", "-z", "--full-tree", sha)
    entries: list[Entry] = []
    for record in output.split(b"\0"):
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, object_type, object_id = metadata.decode().split(" ", 2)
        entries.append(Entry(mode, object_type, object_id, os.fsdecode(raw_path)))
    return entries


def blob_id(data: bytes, object_format: str) -> str:
    digest = hashlib.new(object_format)
    digest.update(f"blob {len(data)}\0".encode())
    digest.update(data)
    return digest.hexdigest()


def verify(repo: Path, release: Path, sha: str) -> tuple[int, int, int, int]:
    object_format = git(repo, "rev-parse", "--show-object-format").decode().strip()
    missing: list[str] = []
    mismatched: list[str] = []
    gitlinks = 0
    tracked = 0

    for entry in tracked_entries(repo, sha):
        if entry.object_type == "commit":
            gitlinks += 1
            continue
        if entry.object_type != "blob":
            mismatched.append(f"{entry.path} (unsupported object type {entry.object_type})")
            continue

        tracked += 1
        target = release / entry.path
        if not os.path.lexists(target):
            missing.append(entry.path)
            continue

        try:
            if entry.mode == "120000":
                if not target.is_symlink():
                    mismatched.append(f"{entry.path} (expected symlink)")
                    continue
                data = os.fsencode(os.readlink(target))
            else:
                if target.is_symlink() or not target.is_file():
                    mismatched.append(f"{entry.path} (expected regular file)")
                    continue
                data = target.read_bytes()
                expected_executable = entry.mode == "100755"
                actual_executable = bool(target.stat().st_mode & stat.S_IXUSR)
                if expected_executable != actual_executable:
                    mismatched.append(f"{entry.path} (executable mode differs)")
                    continue
        except OSError as error:
            mismatched.append(f"{entry.path} ({error})")
            continue

        if blob_id(data, object_format) != entry.object_id:
            mismatched.append(entry.path)

    print(f"tracked_files={tracked}")
    print(f"gitlinks={gitlinks}")
    print(f"missing={len(missing)}")
    print(f"mismatch={len(mismatched)}")
    for path in missing[:20]:
        print(f"missing_path={path}")
    for path in mismatched[:20]:
        print(f"mismatch_path={path}")
    return tracked, gitlinks, len(missing), len(mismatched)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--release", required=True, type=Path)
    parser.add_argument("--sha", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.repo.joinpath(".git").exists():
        print(f"missing Git repository: {args.repo}", file=sys.stderr)
        return 66
    if not args.release.is_dir():
        print(f"missing release directory: {args.release}", file=sys.stderr)
        return 66
    try:
        git(args.repo, "cat-file", "-e", f"{args.sha}^{{commit}}")
        _, _, missing, mismatched = verify(args.repo, args.release, args.sha)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"release tree verification failed: {error}", file=sys.stderr)
        return 65
    return 0 if missing == 0 and mismatched == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
