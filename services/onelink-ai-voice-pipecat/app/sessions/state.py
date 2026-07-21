"""Per-call lifecycle state and exactly-once Rails callbacks."""

from __future__ import annotations

import asyncio
import time
from collections.abc import Awaitable, Callable, Coroutine
from datetime import UTC, datetime
from typing import Any

from app.callbacks.outbox import CallbackOutbox
from app.clients.onelink import Correlation, OnelinkApiError, OnelinkClient


class SessionState:
    """Own transcript sequence, tool fences and terminal callback for one call."""

    def __init__(
        self,
        *,
        client: OnelinkClient,
        correlation: Correlation,
        callback_outbox: CallbackOutbox | None = None,
        tool_action_handler: Callable[[dict[str, Any]], Awaitable[dict[str, Any] | None]]
        | None = None,
    ):
        self.client = client
        self.correlation = correlation
        self.callback_outbox = callback_outbox
        self.started_at = datetime.now(UTC)
        self.started_monotonic = time.monotonic()
        self.last_activity_monotonic = self.started_monotonic
        self.user_turn = 0
        self._transcript: list[dict[str, Any]] = []
        self._pending_transcript: list[dict[str, Any]] = []
        self._sequence = 0
        self._event_sequence = 0
        self._transcript_lock = asyncio.Lock()
        self._finalize_lock = asyncio.Lock()
        self._tool_lock = asyncio.Lock()
        self._tool_results: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._active_tool_calls = 0
        self._background_tasks: set[asyncio.Task[Any]] = set()
        self._tool_action_handler = tool_action_handler
        self._finalized = False
        self._finalize_payload: dict[str, Any] | None = None

    @property
    def duration_ms(self) -> int:
        return max(0, round((time.monotonic() - self.started_monotonic) * 1_000))

    @property
    def finalized(self) -> bool:
        return self._finalized

    @property
    def tool_in_progress(self) -> bool:
        return self._active_tool_calls > 0

    def touch(self) -> None:
        self.last_activity_monotonic = time.monotonic()

    def touch_user(self) -> None:
        self.user_turn += 1
        self.touch()

    def spawn(self, work: Coroutine[Any, Any, Any]) -> None:
        task = asyncio.create_task(work)
        self._background_tasks.add(task)
        task.add_done_callback(self._background_tasks.discard)

    async def drain_background(self, *, timeout_seconds: float = 2.0) -> None:
        deadline = time.monotonic() + timeout_seconds
        while self._background_tasks:
            tasks = list(self._background_tasks)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
                return
            done, pending = await asyncio.wait(tasks, timeout=remaining)
            for task in done:
                if not task.cancelled():
                    task.exception()
            if pending:
                for task in pending:
                    task.cancel()
                await asyncio.gather(*pending, return_exceptions=True)
                return
            await asyncio.sleep(0)

    async def add_transcript(
        self,
        speaker: str,
        text: str,
        *,
        final: bool,
        timestamp: str | None = None,
    ) -> None:
        normalized = text.strip()
        if not normalized:
            return
        self.touch()
        async with self._transcript_lock:
            self._sequence += 1
            item = {
                "speaker": speaker,
                "text": normalized,
                "final": final,
                "sequence": self._sequence,
                "at": timestamp or datetime.now(UTC).isoformat(),
            }
            self._transcript.append(item)
            self._pending_transcript.append(item)

    async def flush_transcript(self, *, final: bool = False) -> bool:
        async with self._transcript_lock:
            if not self._pending_transcript:
                return False
            items = list(self._pending_transcript)
            await self.client.send_transcript(
                self.correlation,
                items=items,
                final=final,
            )
            del self._pending_transcript[: len(items)]
            return True

    async def safe_event(self, event: str, payload: dict[str, Any] | None = None) -> bool:
        self._event_sequence += 1
        event_id = f"pipecat:{self.correlation.runtime_session_id}:{self._event_sequence}:{event}"
        try:
            await self.client.send_event(
                self.correlation,
                event_type=event,
                payload=payload or {},
                event_id=event_id,
                sequence=self._event_sequence,
            )
            return True
        except (OnelinkApiError, TimeoutError):
            return False

    async def safe_control(
        self,
        action: str,
        payload: dict[str, Any] | None = None,
        *,
        tool_call_id: str | None = None,
        tool_name: str | None = None,
    ) -> bool:
        try:
            control_payload = {
                **(payload or {}),
                "tool_call_id": tool_call_id,
                "tool_name": tool_name,
            }
            await self.client.send_control(
                self.correlation,
                action=action,
                metadata={
                    key: value for key, value in control_payload.items() if value is not None
                },
            )
            return True
        except (OnelinkApiError, TimeoutError):
            await self.safe_event(action, payload or {})
            return False

    async def execute_tool(
        self,
        name: str,
        arguments: dict[str, Any],
        tool_call_id: str,
        *,
        timeout_ms: int,
    ) -> dict[str, Any]:
        creator = False
        async with self._tool_lock:
            future = self._tool_results.get(tool_call_id)
            if future is None:
                future = asyncio.get_running_loop().create_future()
                self._tool_results[tool_call_id] = future
                creator = True
        if not creator:
            return await asyncio.shield(future)

        self._active_tool_calls += 1
        self.touch()
        try:
            self.spawn(
                self.safe_control(
                    "tool_started",
                    {"arguments": arguments},
                    tool_call_id=tool_call_id,
                    tool_name=name,
                )
            )
            try:
                result = await self.client.call_tool(
                    self.correlation,
                    name,
                    arguments,
                    tool_call_id=tool_call_id,
                    timeout_seconds=timeout_ms / 1_000,
                )
                if (
                    isinstance(result, dict)
                    and result.get("action")
                    and self._tool_action_handler is not None
                ):
                    transport_result = await self._tool_action_handler(result)
                    if transport_result:
                        result = {**result, "runtime_control": transport_result}
                self.spawn(
                    self.safe_control(
                        "tool_completed",
                        {"result": result},
                        tool_call_id=tool_call_id,
                        tool_name=name,
                    )
                )
            except (OnelinkApiError, TimeoutError) as error:
                result = {
                    "error": "tool_execution_failed",
                    "code": getattr(error, "code", "TOOL_TIMEOUT"),
                }
                self.spawn(
                    self.safe_control(
                        "tool_failed",
                        result,
                        tool_call_id=tool_call_id,
                        tool_name=name,
                    )
                )
            future.set_result(result)
            return result
        except BaseException:
            if not future.done():
                future.cancel()
            raise
        finally:
            self._active_tool_calls -= 1
            self.touch()

    async def finalize(
        self,
        *,
        status: str,
        reason: str,
        recording: dict[str, Any] | None = None,
        error: dict[str, Any] | None = None,
        extra: dict[str, Any] | None = None,
    ) -> bool:
        async with self._finalize_lock:
            if self._finalized:
                return False
            await self.drain_background()
            try:
                await self.flush_transcript(final=True)
            except (OnelinkApiError, TimeoutError):
                pass

            recording_ref = None
            if recording and recording.get("duration_sec"):
                recording_ref = recording.get("storage_key")
                try:
                    recording_event_id = (
                        f"recording_stored:{self.correlation.account_id}:"
                        f"{self.correlation.call_ref}:{recording.get('sha256')}"
                    )
                    if self.callback_outbox is not None:
                        await self.callback_outbox.deliver_recording(
                            self.client,
                            self.correlation,
                            payload=recording,
                            event_id=recording_event_id,
                        )
                    else:
                        await self.client.recording_stored(
                            self.correlation,
                            payload=recording,
                            event_id=recording_event_id,
                        )
                except (OnelinkApiError, TimeoutError):
                    pass

            final_transcript = [item for item in self._transcript if item["final"]]
            partial_transcript = [item for item in self._transcript if not item["final"]]
            if self._finalize_payload is None:
                self._event_sequence += 1
                self._finalize_payload = {
                    "event_type": "finalize",
                    "event_seq": self._event_sequence,
                    "status": status,
                    "reason": reason,
                    "started_at": self.started_at.isoformat(),
                    "ended_at": datetime.now(UTC).isoformat(),
                    "duration_ms": self.duration_ms,
                    "final_transcript": final_transcript,
                    "partial_transcript": partial_transcript,
                    "incomplete_transcript": bool(partial_transcript),
                    "provider_call_id": self.correlation.call_ref,
                    "ai_session_id": self.correlation.runtime_session_id,
                    "provider_session_id": self.correlation.runtime_session_id,
                    "recording_ref": recording_ref,
                    "recording_status": recording.get("recording_status") if recording else None,
                    "degraded": recording.get("degraded") if recording else False,
                    "missing_direction": recording.get("missing_direction") if recording else None,
                    "recording": recording,
                    "runtime_engine": "pipecat",
                    "error": error,
                    **(extra or {}),
                }
            payload = self._finalize_payload
            event_id = f"finalize:{self.correlation.runtime_session_id}:{self.correlation.call_ref}"
            if self.callback_outbox is not None:
                await self.callback_outbox.deliver_finalize(
                    self.client,
                    self.correlation,
                    payload=payload,
                    event_id=event_id,
                )
            else:
                await self.client.finalize_call(
                    self.correlation,
                    payload=payload,
                    event_id=event_id,
                )
            self._finalized = True
            return True
