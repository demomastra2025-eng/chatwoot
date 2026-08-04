"""Durable, idempotent delivery for terminal Pipecat callbacks."""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Protocol

from app.clients.onelink import Correlation

logger = logging.getLogger(__name__)
_KINDS = frozenset({"finalize", "recording_stored"})


class CallbackClient(Protocol):
    async def finalize_call(
        self,
        correlation: Correlation,
        *,
        payload: dict[str, Any],
        event_id: str,
    ) -> dict[str, Any]: ...

    async def recording_stored(
        self,
        correlation: Correlation,
        *,
        payload: dict[str, Any],
        event_id: str,
    ) -> dict[str, Any]: ...


class CallbackOutbox:
    """Persist callbacks before delivery and replay them until Rails accepts them."""

    def __init__(self, root: Path):
        self.root = root
        self._write_lock = asyncio.Lock()

    async def prepare(self) -> None:
        await asyncio.to_thread(self._prepare_sync)

    async def deliver_finalize(
        self,
        client: CallbackClient,
        correlation: Correlation,
        *,
        payload: dict[str, Any],
        event_id: str,
        foreground_timeout_seconds: float | None = None,
    ) -> None:
        path = await self._persist("finalize", correlation, payload, event_id)
        await self._deliver(
            client.finalize_call(correlation, payload=payload, event_id=event_id),
            foreground_timeout_seconds,
        )
        await self._ack(path)

    async def deliver_recording(
        self,
        client: CallbackClient,
        correlation: Correlation,
        *,
        payload: dict[str, Any],
        event_id: str,
        foreground_timeout_seconds: float | None = None,
    ) -> None:
        path = await self._persist("recording_stored", correlation, payload, event_id)
        await self._deliver(
            client.recording_stored(correlation, payload=payload, event_id=event_id),
            foreground_timeout_seconds,
        )
        await self._ack(path)

    @staticmethod
    async def _deliver(work: Any, timeout_seconds: float | None) -> None:
        if timeout_seconds is None:
            await work
            return
        async with asyncio.timeout(timeout_seconds):
            await work

    async def replay(
        self,
        client: CallbackClient,
        *,
        delivery_timeout_seconds: float | None = None,
        concurrency: int = 4,
    ) -> int:
        await self.prepare()
        entries: list[tuple[Path, dict[str, Any]]] = []
        for path in await asyncio.to_thread(self._entry_paths):
            try:
                entry = await asyncio.to_thread(self._read_entry, path)
            except Exception as error:  # Keep the durable entry for the next bounded pass.
                logger.warning(
                    "Pipecat callback replay deferred file=%s error_class=%s",
                    path.name,
                    type(error).__name__,
                )
                continue
            entries.append((path, entry))

        # Closing the call in the product is user-visible and must not sit
        # behind a slow recording callback. Stable sorting preserves FIFO
        # within each callback kind, while bounded concurrency prevents one
        # unhealthy endpoint from head-of-line blocking every durable entry.
        entries.sort(key=lambda item: item[1]["kind"] != "finalize")
        semaphore = asyncio.Semaphore(max(1, concurrency))

        async def deliver(path: Path, entry: dict[str, Any]) -> int:
            async with semaphore:
                try:
                    correlation = Correlation(**entry["correlation"])
                    if entry["kind"] == "finalize":
                        work = client.finalize_call(
                            correlation,
                            payload=entry["payload"],
                            event_id=entry["event_id"],
                        )
                    else:
                        work = client.recording_stored(
                            correlation,
                            payload=entry["payload"],
                            event_id=entry["event_id"],
                        )
                    await self._deliver(work, delivery_timeout_seconds)
                    await self._ack(path)
                    return 1
                except Exception as error:  # Keep the durable entry for the next pass.
                    logger.warning(
                        "Pipecat callback replay deferred file=%s error_class=%s",
                        path.name,
                        type(error).__name__,
                    )
                    return 0

        return sum(await asyncio.gather(*(deliver(path, entry) for path, entry in entries)))

    async def _persist(
        self,
        kind: str,
        correlation: Correlation,
        payload: dict[str, Any],
        event_id: str,
    ) -> Path:
        if kind not in _KINDS:
            raise ValueError("unsupported callback outbox kind")
        entry = {
            "version": 1,
            "kind": kind,
            "event_id": event_id,
            "correlation": correlation.payload(),
            "payload": payload,
            "created_at": datetime.now(UTC).isoformat(),
        }
        encoded = json.dumps(entry, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        filename = f"{hashlib.sha256(event_id.encode('utf-8')).hexdigest()}.json"
        path = self.root / filename
        async with self._write_lock:
            await asyncio.to_thread(self._write_atomic, path, encoded)
        return path

    async def _ack(self, path: Path) -> None:
        async with self._write_lock:
            await asyncio.to_thread(self._ack_sync, path)

    def _prepare_sync(self) -> None:
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.root.chmod(0o700)

    def _entry_paths(self) -> list[Path]:
        return sorted(self.root.glob("*.json"))

    @staticmethod
    def _read_entry(path: Path) -> dict[str, Any]:
        entry = json.loads(path.read_text(encoding="utf-8"))
        if (
            not isinstance(entry, dict)
            or entry.get("kind") not in _KINDS
            or not isinstance(entry.get("event_id"), str)
            or not isinstance(entry.get("correlation"), dict)
            or not isinstance(entry.get("payload"), dict)
        ):
            raise ValueError("invalid callback outbox entry")
        return entry

    def _write_atomic(self, path: Path, encoded: str) -> None:
        self._prepare_sync()
        if path.exists():
            existing = self._read_entry(path)
            candidate = json.loads(encoded)
            existing.pop("created_at", None)
            candidate.pop("created_at", None)
            if existing != candidate:
                raise ValueError("callback event id conflicts with a different payload")
            return
        temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(encoded)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
            self._fsync_root()
        finally:
            temporary.unlink(missing_ok=True)

    def _ack_sync(self, path: Path) -> None:
        try:
            path.unlink()
        except FileNotFoundError:
            return
        self._fsync_root()

    def _fsync_root(self) -> None:
        descriptor = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
