#!/usr/bin/env python3
"""Seal and verify exact-SHA DEV assets prepared through the heavy-work gate."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import sys

ENTRYPOINTS = ("dashboard", "v3app", "widget", "portal", "survey", "superadmin", "superadmin_pages")
PROOF = "DEV_BUILT_ASSETS.json"
CONTRACT = "BUILT_ASSETS_CONTRACT = 1"


def regular_file(root: Path, relative: str) -> Path:
    if root.is_symlink():
        raise ValueError("asset root is a symlink")
    path = PurePosixPath(relative)
    if not relative or path.is_absolute() or ".." in path.parts or "\\" in relative or ":" in relative:
        raise ValueError(f"unsafe asset path: {relative}")
    target = root
    for part in path.parts:
        target = target / part
        if target.is_symlink():
            raise ValueError(f"asset symlink: {relative}")
    if not target.is_file() or target.stat().st_size == 0:
        raise ValueError(f"missing/empty asset: {relative}")
    return target


def compatible(release: Path) -> None:
    source = regular_file(release, "lib/onelink/dev_runtime.rb")
    if CONTRACT not in source.read_text(encoding="utf-8"):
        raise ValueError("release does not support the DEV built-assets contract; deploy with flags off first")


def inventory(root: Path) -> dict[str, str]:
    regular_file(root, "public/packs/js/sdk.js")
    files = {}
    vite = root / "public/vite"
    if vite.is_symlink() or not vite.is_dir():
        raise ValueError("missing public/vite directory")
    for path in sorted(vite.rglob("*")):
        if path.is_symlink():
            raise ValueError("asset symlinks are not permitted")
        if path.is_file():
            relative = path.relative_to(root).as_posix()
            files[relative] = hashlib.sha256(regular_file(root, relative).read_bytes()).hexdigest()
    sdk = "public/packs/js/sdk.js"
    files[sdk] = hashlib.sha256(regular_file(root, sdk).read_bytes()).hexdigest()
    return files


def manifest(root: Path) -> dict:
    combined = {}
    for name in ("manifest.json", "manifest-assets.json"):
        path = regular_file(root, f"public/vite/.vite/{name}")
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("invalid Vite manifest")
        if combined.keys() & data.keys():
            raise ValueError("duplicate Vite manifest entries")
        combined.update(data)
    for name in ENTRYPOINTS:
        key = f"entrypoints/{name}.js"
        if not isinstance(combined.get(key), dict) or not combined[key].get("isEntry"):
            raise ValueError(f"missing Vite entrypoint: {key}")
    for entry in combined.values():
        if not isinstance(entry, dict) or not isinstance(entry.get("file"), str):
            raise ValueError("invalid Vite asset entry")
        regular_file(root, "public/vite/" + entry["file"])
        for key in ("css", "assets"):
            values = entry.get(key, [])
            if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
                raise ValueError(f"invalid Vite {key} list")
            for value in values:
                regular_file(root, "public/vite/" + value)
        for key in ("imports", "dynamicImports"):
            values = entry.get(key, [])
            if not isinstance(values, list) or any(not isinstance(value, str) or value not in combined for value in values):
                raise ValueError(f"dangling Vite {key}")
    return combined


def verify(root: Path, sha: str) -> dict:
    manifest(root)
    proof = json.loads(regular_file(root, PROOF).read_text(encoding="utf-8"))
    if not isinstance(proof, dict) or proof.get("version") != 1 or proof.get("git_sha") != sha or proof.get("mode") != "production":
        raise ValueError("DEV asset proof does not match the requested SHA/mode")
    if proof.get("files") != inventory(root):
        raise ValueError("DEV asset inventory or SHA-256 differs from the sealed build")
    return proof


def install(artifact: Path, sha: str, release: Path) -> None:
    proof = verify(artifact, sha)
    compatible(release)
    # A same-SHA mode change may target current. Reuse only an intact artifact;
    # never rewrite a partially changed live asset tree.
    if (release / PROOF).exists():
        verify(release, sha)
        if json.loads((release / PROOF).read_text(encoding="utf-8")) != proof:
            raise ValueError("release already contains a different sealed artifact")
        return
    for target in (release / "public/vite", release / "public/packs/js/sdk.js"):
        if target.exists() or target.is_symlink():
            raise ValueError("unsealed generated assets already exist; refuse to overwrite")
    # Validate destination parents before copy (archive paths must be ordinary dirs).
    for relative in ("public", "public/packs", "public/packs/js"):
        target = release / relative
        if target.is_symlink() or (target.exists() and not target.is_dir()):
            raise ValueError("unsafe release asset destination")
    shutil.copytree(artifact / "public/vite", release / "public/vite")
    (release / "public/packs/js").mkdir(parents=True, exist_ok=True)
    shutil.copy2(artifact / "public/packs/js/sdk.js", release / "public/packs/js/sdk.js")
    shutil.copy2(artifact / PROOF, release / PROOF)
    verify(release, sha)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("seal", "verify", "install", "urls", "compatible"))
    parser.add_argument("root", type=Path)
    parser.add_argument("sha")
    parser.add_argument("--release", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.sha):
        parser.error("expected a full Git SHA")
    try:
        if args.command == "compatible":
            compatible(args.root)
        elif args.command == "seal":
            manifest(args.root)
            proof = {"version": 1, "git_sha": args.sha, "mode": "production", "files": inventory(args.root)}
            (args.root / PROOF).write_text(json.dumps(proof, sort_keys=True) + "\n", encoding="utf-8")
        elif args.command == "install":
            if args.release is None:
                parser.error("install requires --release")
            install(args.root, args.sha, args.release)
        else:
            proof = verify(args.root, args.sha)
            if args.command == "urls":
                data = manifest(args.root)
                paths = {"public/vite/" + data[f"entrypoints/{name}.js"]["file"] for name in ENTRYPOINTS}
                paths.add("public/packs/js/sdk.js")
                for path in sorted(paths):
                    print(f"/{path.removeprefix('public/')} {proof['files'][path]}")
        return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"DEV asset validation failed: {error}", file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
