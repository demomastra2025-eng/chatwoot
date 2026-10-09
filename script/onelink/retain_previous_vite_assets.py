#!/usr/bin/env python3
"""Retain bounded Vite files from verified, previously deployed production images."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from typing import Callable


APP_IMAGE_REPOSITORY = "ghcr.io/demomastra2025-eng/chatwoot"
VOICE_IMAGE_REPOSITORY = "ghcr.io/demomastra2025-eng/onelink-ai-voice"
CURRENT_MANIFEST = "public/vite/.vite/manifest.json"
ASSETS_MANIFEST = "public/vite/.vite/manifest-assets.json"
MAX_RETAINED_VERSIONS = 2
MAX_DEPLOYMENTS_TO_SCAN = 500
API_PAGE_SIZE = 100
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
MAX_GIT_SHA_MARKER_BYTES = 128
MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_TOTAL_BYTES = 256 * 1024 * 1024
MAX_FILES = 4096
MAX_STATUS_ROWS = 1000

GIT_SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
APP_IMAGE_RE = re.compile(re.escape(APP_IMAGE_REPOSITORY) + r"@sha256:([0-9a-f]{64})\Z")
VOICE_IMAGE_RE = re.compile(re.escape(VOICE_IMAGE_REPOSITORY) + r"@sha256:[0-9a-f]{64}\Z")
SERVICE_WORKER_RE = re.compile(
    r"(?:^|/)(?:service[-_.]?worker|sw)(?:$|[._-])[^/]*\.(?:js|mjs)\Z",
    re.IGNORECASE,
)


def safe_asset_path(value: object) -> str:
    if not isinstance(value, str) or not value or "\\" in value or ":" in value:
        raise ValueError("invalid Vite asset path")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError("invalid Vite asset path")

    path = PurePosixPath(value)
    if path.is_absolute() or path.as_posix() != value or any(part in ("", ".", "..") for part in value.split("/")):
        raise ValueError("unsafe Vite asset path")
    return value


def retained_path(value: str) -> bool:
    lower = value.lower()
    name = lower.rsplit("/", 1)[-1]
    if lower.endswith((".html", ".htm")):
        return False
    if "/.vite/" in f"/{lower}/" or re.fullmatch(r"manifest(?:-[a-z0-9_-]+)?\.json", name):
        return False
    if SERVICE_WORKER_RE.search(lower):
        return False
    return True


def manifest_references(manifests: list[dict]) -> list[str]:
    if not manifests:
        raise ValueError("no Vite manifests were supplied")

    keys: set[str] = set()
    for manifest in manifests:
        if not isinstance(manifest, dict):
            raise ValueError("invalid Vite manifest")
        if any(not isinstance(key, str) or not key for key in manifest):
            raise ValueError("invalid Vite manifest key")
        keys.update(manifest)

    references: set[str] = set()
    for manifest in manifests:
        for entry in manifest.values():
            if not isinstance(entry, dict) or not isinstance(entry.get("file"), str):
                raise ValueError("invalid Vite manifest entry")
            candidates = [entry["file"]]
            for key in ("css", "assets"):
                values = entry.get(key, [])
                if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
                    raise ValueError(f"invalid Vite manifest {key}")
                candidates.extend(values)
            for key in ("imports", "dynamicImports"):
                values = entry.get(key, [])
                if not isinstance(values, list) or any(not isinstance(value, str) or value not in keys for value in values):
                    raise ValueError(f"invalid Vite manifest {key}")

            for candidate in candidates:
                path = safe_asset_path(candidate)
                if retained_path(path):
                    references.add(path)

    if not references:
        raise ValueError("Vite manifests reference no retainable files")
    if len(references) > MAX_FILES:
        raise ValueError("Vite manifest exceeds the retained file limit")
    return sorted(references)


def extract_single_regular_tar(stream: io.BufferedIOBase, expected_name: str, max_bytes: int) -> bytes:
    """Read one regular file from a Docker copy tar stream, without path extraction."""
    expected_basename = PurePosixPath(expected_name).name
    try:
        with tarfile.open(fileobj=stream, mode="r|") as archive:
            member = archive.next()
            if member is None:
                raise ValueError("empty Docker copy archive")

            member_path = member.name
            if (
                not member_path
                or member_path.startswith("/")
                or "\\" in member_path
                or ":" in member_path
                or any(part in ("", ".", "..") for part in member_path.split("/"))
                or PurePosixPath(member_path).name != expected_basename
            ):
                raise ValueError("unsafe Docker copy archive member")
            if not member.isfile() or member.size < 0 or member.size > max_bytes:
                raise ValueError("Docker copy member is not a bounded regular file")

            source = archive.extractfile(member)
            if source is None:
                raise ValueError("Docker copy member has no regular-file data")
            content = source.read(member.size + 1)
            if len(content) != member.size:
                raise ValueError("Docker copy member length mismatch")
            if archive.next() is not None:
                raise ValueError("Docker copy archive contains extra members")
            return content
    except tarfile.TarError as error:
        raise ValueError("invalid Docker copy tar archive") from error


def _docker_copy_file(container: str, relative: str, *, max_bytes: int, optional: bool = False) -> bytes | None:
    safe_asset_path(relative)
    stderr_file = tempfile.TemporaryFile()
    process = subprocess.Popen(
        ["docker", "cp", f"{container}:/app/{relative}", "-"],
        stdout=subprocess.PIPE,
        stderr=stderr_file,
    )
    try:
        if process.stdout is None:
            raise ValueError("Docker copy did not provide an archive stream")
        try:
            data = extract_single_regular_tar(process.stdout, relative, max_bytes)
        except ValueError:
            process.kill()
            process.wait()
            stderr_file.seek(0)
            detail = stderr_file.read(4096).decode("utf-8", errors="replace")
            if optional and process.returncode != 0 and (
                "could not find the file" in detail.lower() or "no such file or directory" in detail.lower()
            ):
                return None
            if process.returncode != 0:
                raise ValueError("Docker could not read a required Vite file") from None
            raise
        return_code = process.wait(timeout=120)
        if return_code != 0:
            stderr_file.seek(0)
            detail = stderr_file.read(4096).decode("utf-8", errors="replace")
            if optional and (
                "could not find the file" in detail.lower() or "no such file or directory" in detail.lower()
            ):
                return None
            raise ValueError("Docker could not read a required Vite file")
        return data
    except (OSError, subprocess.SubprocessError):
        if process.poll() is None:
            process.kill()
            process.wait()
        raise ValueError("Docker copy failed") from None
    finally:
        if process.stdout is not None:
            process.stdout.close()
        stderr_file.close()


def parse_image_reference(sha: object, image: object) -> tuple[str, str]:
    if not isinstance(sha, str) or not GIT_SHA_RE.fullmatch(sha):
        raise ValueError("production deployment has an invalid Git SHA")
    if not isinstance(image, str):
        raise ValueError("production deployment has no immutable app image")
    match = APP_IMAGE_RE.fullmatch(image)
    if match is None:
        raise ValueError("production deployment app image is outside the canonical repository/digest format")
    return sha, match.group(1)


def production_payload(deployment: dict) -> dict:
    payload = deployment.get("payload")
    if isinstance(payload, str):
        try:
            payload = json.loads(payload)
        except json.JSONDecodeError as error:
            raise ValueError("successful production deployment payload is invalid") from error
    if not isinstance(payload, dict):
        raise ValueError("successful production deployment has no image proof payload")
    if not isinstance(payload.get("voice_image"), str) or not VOICE_IMAGE_RE.fullmatch(payload["voice_image"]):
        raise ValueError("successful production deployment voice image proof is invalid")
    return payload


def deployment_qualifies(statuses: list[dict]) -> bool:
    """GitHub may mark the prior successful deployment inactive after a new rollout."""
    if not isinstance(statuses, list):
        raise ValueError("GitHub returned invalid production deployment statuses")
    if not statuses:
        return False
    if any(not isinstance(status, dict) or not isinstance(status.get("state"), str) for status in statuses):
        raise ValueError("GitHub returned a malformed production deployment status")
    latest = statuses[0]["state"]
    if latest == "success":
        return True
    return latest == "inactive" and any(status["state"] == "success" for status in statuses)


def select_previous_images(
    fetch_deployments: Callable[[int], list[dict]],
    fetch_statuses: Callable[[int], list[dict]],
) -> list[dict[str, str]]:
    """Select newest successful production proof for each of at most two distinct SHAs."""
    selected: list[dict[str, str]] = []
    seen_shas: set[str] = set()
    scanned = 0

    for page in range(1, (MAX_DEPLOYMENTS_TO_SCAN // API_PAGE_SIZE) + 2):
        deployments = fetch_deployments(page)
        if not isinstance(deployments, list):
            raise ValueError("GitHub returned an invalid production deployment page")
        if not deployments:
            break

        for deployment in deployments:
            scanned += 1
            if scanned > MAX_DEPLOYMENTS_TO_SCAN:
                raise ValueError("production deployment history exceeded the bounded scan limit")
            if not isinstance(deployment, dict):
                raise ValueError("GitHub returned an invalid production deployment record")
            if deployment.get("environment") != "production":
                continue
            deployment_id = deployment.get("id")
            if not isinstance(deployment_id, int) or deployment_id < 1:
                raise ValueError("production deployment record has no valid identifier")

            statuses = fetch_statuses(deployment_id)
            if not isinstance(statuses, list):
                raise ValueError("GitHub returned invalid production deployment statuses")
            if not deployment_qualifies(statuses):
                continue

            sha = deployment.get("sha")
            if not isinstance(sha, str) or not GIT_SHA_RE.fullmatch(sha):
                raise ValueError("successful production deployment has an invalid Git SHA")
            if sha in seen_shas:
                continue

            payload = production_payload(deployment)
            sha, digest = parse_image_reference(sha, payload.get("image"))
            selected.append({"sha": sha, "image": payload["image"], "digest": digest})
            seen_shas.add(sha)
            if len(selected) == MAX_RETAINED_VERSIONS:
                return selected

        if len(deployments) < API_PAGE_SIZE:
            break
    return selected


def _github_api_array(endpoint: str, *, paginate: bool) -> list:
    command = ["gh", "api"]
    if paginate:
        command.extend(("--paginate", "--slurp"))
    command.append(endpoint)
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        raise ValueError("GitHub API request failed; response details are withheld")
    try:
        pages = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError("GitHub API returned invalid JSON") from error
    if paginate:
        if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
            raise ValueError("GitHub API returned an invalid paginated array")
        return [item for page in pages for item in page]
    if not isinstance(pages, list):
        raise ValueError("GitHub API returned an invalid array")
    return pages


def resolve_previous_images(repository: str) -> list[dict[str, str]]:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("invalid GitHub repository name")
    deployment_endpoint = f"repos/{repository}/deployments?environment=production&per_page={API_PAGE_SIZE}"

    def deployments(page: int) -> list[dict]:
        if page == 1:
            endpoint = deployment_endpoint
        else:
            endpoint = f"{deployment_endpoint}&page={page}"
        return _github_api_array(endpoint, paginate=False)

    def statuses(deployment_id: int) -> list[dict]:
        endpoint = f"repos/{repository}/deployments/{deployment_id}/statuses?per_page={API_PAGE_SIZE}"
        result = _github_api_array(endpoint, paginate=True)
        if len(result) > MAX_STATUS_ROWS:
            raise ValueError("production deployment status history exceeded its limit")
        return result

    return select_previous_images(deployments, statuses)


def read_image_specs(serialized: str) -> list[dict[str, str]]:
    try:
        specs = json.loads(serialized)
    except json.JSONDecodeError as error:
        raise ValueError("selected production image list is invalid JSON") from error
    if not isinstance(specs, list) or len(specs) > MAX_RETAINED_VERSIONS:
        raise ValueError("selected production image list exceeds its limit")

    result = []
    seen = set()
    for spec in specs:
        if not isinstance(spec, dict):
            raise ValueError("selected production image proof is invalid")
        sha, digest = parse_image_reference(spec.get("sha"), spec.get("image"))
        if sha in seen:
            raise ValueError("selected production image list contains a duplicate SHA")
        if spec.get("digest") != digest:
            raise ValueError("selected production image digest does not match its reference")
        seen.add(sha)
        result.append({"sha": sha, "image": spec["image"], "digest": digest})
    return result


def reset_output(output: Path) -> None:
    if output.is_symlink():
        raise ValueError("retained asset context is a symlink")
    output.mkdir(parents=True, exist_ok=True)
    public = output / "public"
    origins = output / "origins.json"
    for managed in (public, origins):
        if managed.is_symlink():
            raise ValueError("retained asset context contains a symlink")
        if managed.is_dir():
            shutil.rmtree(managed)
        elif managed.exists():
            managed.unlink()
    _write_origins(output, {"version": 1, "versions": []})


def _read_origins(output: Path) -> dict:
    path = output / "origins.json"
    if not path.exists():
        return {"version": 1, "versions": []}
    if path.is_symlink() or not path.is_file():
        raise ValueError("retained asset origin metadata is not a regular file")
    try:
        result = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError("retained asset origin metadata is invalid") from error
    if not isinstance(result, dict) or result.get("version") != 1 or not isinstance(result.get("versions"), list):
        raise ValueError("retained asset origin metadata has an unsupported shape")
    if len(result["versions"]) > MAX_RETAINED_VERSIONS:
        raise ValueError("retained asset origin metadata exceeds its version limit")
    seen_shas = set()
    for version in result["versions"]:
        if not isinstance(version, dict) or not isinstance(version.get("files"), dict):
            raise ValueError("retained asset version metadata is invalid")
        sha = version.get("sha")
        digest = version.get("digest")
        parse_image_reference(sha, f"{APP_IMAGE_REPOSITORY}@sha256:{digest}")
        if sha in seen_shas:
            raise ValueError("retained asset metadata contains a duplicate SHA")
        seen_shas.add(sha)
        if not version["files"] or len(version["files"]) > MAX_FILES:
            raise ValueError("retained asset version file metadata is invalid")
        for relative, detail in version["files"].items():
            path = safe_asset_path(relative)
            if not retained_path(path) or not isinstance(detail, dict):
                raise ValueError("retained asset file metadata is invalid")
            size = detail.get("size")
            if not isinstance(size, int) or size < 0 or size > MAX_FILE_BYTES:
                raise ValueError("retained asset file size metadata is invalid")
            if not isinstance(detail.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", detail["sha256"]):
                raise ValueError("retained asset file hash metadata is invalid")
    return result


def _write_origins(output: Path, metadata: dict) -> None:
    path = output / "origins.json"
    temporary = output / ".origins.json.tmp"
    if temporary.is_symlink():
        raise ValueError("retained asset metadata temp path is a symlink")
    temporary.write_text(json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def _safe_local_path(root: Path, relative: str, *, create_parents: bool = False) -> Path:
    safe_asset_path(relative)
    if root.is_symlink():
        raise ValueError("retained asset root is a symlink")
    target = root
    parts = PurePosixPath(relative).parts
    for part in parts[:-1]:
        target = target / part
        if target.is_symlink():
            raise ValueError("retained asset destination has a symlink parent")
        if target.exists() and not target.is_dir():
            raise ValueError("retained asset destination parent is not a directory")
        if create_parents and not target.exists():
            target.mkdir()
    return target / parts[-1]


def merge_assets(output: Path, sha: str, image: str, files: dict[str, bytes]) -> None:
    sha, digest = parse_image_reference(sha, image)
    if not isinstance(files, dict) or not files:
        raise ValueError("retained Vite file set is empty")
    if len(files) > MAX_FILES:
        raise ValueError("retained Vite file count exceeds its limit")

    normalized: dict[str, bytes] = {}
    total_size = 0
    for relative, content in files.items():
        path = safe_asset_path(relative)
        if not retained_path(path):
            raise ValueError("excluded file appeared in retained Vite assets")
        if not isinstance(content, bytes) or len(content) > MAX_FILE_BYTES:
            raise ValueError("retained Vite file exceeds its size limit")
        total_size += len(content)
        if total_size > MAX_TOTAL_BYTES:
            raise ValueError("retained Vite files exceed their total byte limit")
        normalized[path] = content

    metadata = _read_origins(output)
    versions = metadata["versions"]
    prior_version = next((version for version in versions if version.get("sha") == sha), None)
    if prior_version is not None:
        if prior_version.get("digest") != digest:
            raise ValueError("same production SHA has conflicting immutable image digests")
        raise ValueError("production SHA was already collected")
    if len(versions) >= MAX_RETAINED_VERSIONS:
        raise ValueError("retained Vite version limit exceeded")

    version_files = {}
    target_root = output / "public" / "vite"
    if output.is_symlink():
        raise ValueError("retained asset context is a symlink")
    output.mkdir(parents=True, exist_ok=True)
    public_root = output / "public"
    if public_root.is_symlink() or (public_root.exists() and not public_root.is_dir()):
        raise ValueError("retained asset public directory is unsafe")
    public_root.mkdir(exist_ok=True)
    if target_root.is_symlink():
        raise ValueError("retained asset output root is a symlink")
    if target_root.exists() and not target_root.is_dir():
        raise ValueError("retained asset output root is not a directory")
    target_root.mkdir(exist_ok=True)

    # Validate every current retained path before copying any file from this image.
    for version in versions:
        for relative, detail in version["files"].items():
            target = _safe_local_path(target_root, relative)
            if target.is_symlink() or not target.is_file():
                raise ValueError("retained asset metadata references a missing or unsafe file")
            if (
                target.stat().st_size != detail["size"]
                or hashlib.sha256(target.read_bytes()).hexdigest() != detail["sha256"]
            ):
                raise ValueError("retained asset differs from its origin metadata")
    for relative, content in normalized.items():
        target = _safe_local_path(target_root, relative)
        if target.is_symlink():
            raise ValueError("retained asset output contains a symlink")
        if target.exists():
            if not target.is_file() or target.read_bytes() != content:
                raise ValueError(f"retained Vite asset conflicts with an earlier image: {relative}")
        version_files[relative] = {"sha256": hashlib.sha256(content).hexdigest(), "size": len(content)}

    distinct_paths = set(normalized)
    for version in versions:
        if isinstance(version, dict) and isinstance(version.get("files"), dict):
            distinct_paths.update(version["files"])
    if len(distinct_paths) > MAX_FILES:
        raise ValueError("retained Vite file count exceeds its limit")
    existing_bytes = 0
    for relative in distinct_paths:
        target = _safe_local_path(target_root, relative)
        if target.exists():
            existing_bytes += target.stat().st_size
    missing_bytes = sum(
        len(content)
        for relative, content in normalized.items()
        if not _safe_local_path(target_root, relative).exists()
    )
    if existing_bytes + missing_bytes > MAX_TOTAL_BYTES:
        raise ValueError("retained Vite files exceed their total byte limit")

    for relative, content in normalized.items():
        target = _safe_local_path(target_root, relative, create_parents=True)
        if not target.exists():
            target.write_bytes(content)

    versions.append({"sha": sha, "digest": digest, "files": version_files})
    _write_origins(output, {"version": 1, "versions": versions})


def collect_image(output: Path, container: str, sha: str, image: str) -> None:
    sha, digest = parse_image_reference(sha, image)
    if not re.fullmatch(r"[0-9a-f]{12,64}", container):
        raise ValueError("invalid Docker container identifier")

    marker = _docker_copy_file(
        container,
        ".git_sha",
        max_bytes=MAX_GIT_SHA_MARKER_BYTES,
        optional=True,
    )
    if marker is None:
        raise ValueError("production image revision marker is missing")
    if not re.fullmatch(rb"[0-9a-f]{40}\n", marker):
        raise ValueError("production image revision marker is invalid")
    if marker[:-1].decode("ascii") != sha:
        raise ValueError("production image revision marker does not match its deployment proof")

    manifest_data = _docker_copy_file(container, CURRENT_MANIFEST, max_bytes=MAX_MANIFEST_BYTES)
    if manifest_data is None:
        raise ValueError("current Vite manifest is missing")
    try:
        manifests = [json.loads(manifest_data)]
    except json.JSONDecodeError as error:
        raise ValueError("current Vite manifest is invalid JSON") from error

    asset_manifest_data = _docker_copy_file(
        container, ASSETS_MANIFEST, max_bytes=MAX_MANIFEST_BYTES, optional=True
    )
    if asset_manifest_data is not None:
        try:
            manifests.append(json.loads(asset_manifest_data))
        except json.JSONDecodeError as error:
            raise ValueError("Vite assets manifest is invalid JSON") from error

    paths = manifest_references(manifests)
    files = {}
    total_size = 0
    for relative in paths:
        content = _docker_copy_file(
            container, f"public/vite/{relative}", max_bytes=MAX_FILE_BYTES
        )
        if content is None:
            raise ValueError("a referenced Vite file is missing from the production image")
        files[relative] = content
        total_size += len(content)
        if total_size > MAX_TOTAL_BYTES:
            raise ValueError("retained Vite files exceed their total byte limit")

    merge_assets(output, sha, image, files)


def _repo_from_env() -> str:
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("GITHUB_REPOSITORY is missing or invalid")
    return repository


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    reset = subparsers.add_parser("reset", help="clear only generated files in the staging directory")
    reset.add_argument("--output", type=Path, required=True)

    resolve = subparsers.add_parser("resolve", help="resolve prior successful production images")
    resolve.add_argument("--repo", default=None)
    resolve.add_argument("--github-output", type=Path, default=None)

    list_images = subparsers.add_parser("list-images", help="validate and print selected image specs as TSV")
    list_images.add_argument("images_json")

    collect = subparsers.add_parser("collect", help="extract referenced files from a verified image container")
    collect.add_argument("--output", type=Path, required=True)
    collect.add_argument("--container", required=True)
    collect.add_argument("--sha", required=True)
    collect.add_argument("--image", required=True)

    merge = subparsers.add_parser("merge", help="merge retained files into the newly precompiled Vite tree")
    merge.add_argument("--current", type=Path, required=True)
    merge.add_argument("--retained", type=Path, required=True)

    args = parser.parse_args()
    try:
        if args.command == "reset":
            reset_output(args.output)
        elif args.command == "resolve":
            images = resolve_previous_images(args.repo or _repo_from_env())
            output_path = args.github_output
            if output_path is None:
                output_value = os.environ.get("GITHUB_OUTPUT", "")
                if not output_value:
                    raise ValueError("GitHub output path is required")
                output_path = Path(output_value)
            if output_path.is_dir():
                raise ValueError("GitHub output path is required")
            with output_path.open("a", encoding="utf-8") as output:
                output.write(f"images={json.dumps(images, separators=(',', ':'))}\n")
        elif args.command == "list-images":
            for spec in read_image_specs(args.images_json):
                print(f"{spec['sha']}\t{spec['image']}")
        elif args.command == "collect":
            collect_image(args.output, args.container, args.sha, args.image)
        elif args.command == "merge":
            merge_staged_into_current(args.current, args.retained)
        return 0
    except (OSError, subprocess.SubprocessError, ValueError, tarfile.TarError, TypeError) as error:
        print(f"Previous Vite asset preparation failed: {error}", file=sys.stderr)
        return 65


def merge_staged_into_current(current: Path, retained: Path) -> None:
    if current.is_symlink() or not current.is_dir():
        raise ValueError("current Vite output is missing or unsafe")
    if retained.is_symlink():
        raise ValueError("retained Vite output is a symlink")
    if not retained.exists():
        return
    if not retained.is_dir():
        raise ValueError("retained Vite output is not a directory")

    staged: dict[str, Path] = {}
    total_bytes = 0
    for path in sorted(retained.rglob("*")):
        if path.is_symlink():
            raise ValueError("retained Vite output contains a symlink")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError("retained Vite output contains a non-regular entry")
        relative = path.relative_to(retained).as_posix()
        safe_asset_path(relative)
        if not retained_path(relative):
            raise ValueError("retained output contains an excluded Vite file")
        size = path.stat().st_size
        if size > MAX_FILE_BYTES:
            raise ValueError("retained Vite file exceeds its size limit")
        total_bytes += size
        if total_bytes > MAX_TOTAL_BYTES:
            raise ValueError("retained Vite output exceeds its total byte limit")
        staged[relative] = path
    if len(staged) > MAX_FILES:
        raise ValueError("retained Vite output exceeds its file count limit")

    # Preflight all conflicts before copying any retained file.
    missing: list[tuple[str, Path, Path]] = []
    for relative, source in staged.items():
        target = _safe_local_path(current, relative)
        if target.is_symlink():
            raise ValueError("current Vite output contains a conflicting symlink")
        if target.exists():
            if not target.is_file() or source.read_bytes() != target.read_bytes():
                raise ValueError(f"retained Vite asset conflicts with current build: {relative}")
        else:
            missing.append((relative, source, target))

    for _, source, target in missing:
        _safe_local_path(current, target.relative_to(current).as_posix(), create_parents=True)
        target.write_bytes(source.read_bytes())


if __name__ == "__main__":
    raise SystemExit(main())
