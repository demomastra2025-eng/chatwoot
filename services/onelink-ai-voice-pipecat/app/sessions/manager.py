"""Atomic one-owner reservation of Pipecat call sessions."""

from __future__ import annotations

import asyncio
import hashlib
import json
from dataclasses import dataclass
from enum import Enum
from typing import Any


class ReservationKind(Enum):
    CREATED = "created"
    DUPLICATE = "duplicate"
    CONFLICT = "conflict"
    CAPACITY_EXHAUSTED = "capacity_exhausted"


@dataclass(eq=False, slots=True)
class SessionRecord:
    call_ref: str
    fingerprint: str
    task: asyncio.Task[None] | None = None


@dataclass(frozen=True, slots=True)
class Reservation:
    kind: ReservationKind
    record: SessionRecord | None = None


class SessionManager:
    """Own active sessions and reject duplicate or over-capacity attach races."""

    def __init__(self, max_concurrent_sessions: int):
        self._max_concurrent_sessions = max_concurrent_sessions
        self._records: dict[str, SessionRecord] = {}
        self._lock = asyncio.Lock()

    @property
    def active_count(self) -> int:
        return len(self._records)

    async def reserve(self, call_ref: str, payload: dict[str, Any]) -> Reservation:
        fingerprint = _fingerprint(payload)
        async with self._lock:
            existing = self._records.get(call_ref)
            if existing is not None:
                kind = (
                    ReservationKind.DUPLICATE
                    if existing.fingerprint == fingerprint
                    else ReservationKind.CONFLICT
                )
                return Reservation(kind=kind, record=existing)
            if len(self._records) >= self._max_concurrent_sessions:
                return Reservation(kind=ReservationKind.CAPACITY_EXHAUSTED)

            record = SessionRecord(call_ref=call_ref, fingerprint=fingerprint)
            self._records[call_ref] = record
            return Reservation(kind=ReservationKind.CREATED, record=record)

    async def bind_task(self, record: SessionRecord, task: asyncio.Task[None]) -> None:
        async with self._lock:
            if self._records.get(record.call_ref) is not record:
                task.cancel()
                return
            record.task = task

    async def release(self, call_ref: str, record: object) -> bool:
        async with self._lock:
            if self._records.get(call_ref) is not record:
                return False
            del self._records[call_ref]
            return True

    async def shutdown(self) -> None:
        async with self._lock:
            records = tuple(self._records.values())
            self._records.clear()
        tasks = [record.task for record in records if record.task is not None]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)


def _fingerprint(payload: dict[str, Any]) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()
