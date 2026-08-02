"""Per-call lifecycle state and exactly-once Rails callbacks."""

from __future__ import annotations

import asyncio
import hashlib
import json
import time
from collections.abc import Awaitable, Callable, Coroutine
from datetime import UTC, datetime
from typing import Any

from app.callbacks.outbox import CallbackOutbox
from app.clients.onelink import Correlation, OnelinkApiError, OnelinkClient

SEMANTIC_MUTATION_FENCE_TOOLS = frozenset({"create_deal"})


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
        self._control_sequence = 0
        self._transcript_lock = asyncio.Lock()
        self._finalize_lock = asyncio.Lock()
        self._tool_lock = asyncio.Lock()
        self._tool_results: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._tool_fingerprints: dict[str, str] = {}
        self._semantic_tool_results: dict[
            tuple[str, int], asyncio.Future[dict[str, Any]]
        ] = {}
        self._active_tool_calls = 0
        self._background_tasks: set[asyncio.Task[Any]] = set()
        self._tool_action_handler = tool_action_handler
        self._termination_requested = False
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

    @property
    def termination_requested(self) -> bool:
        return self._termination_requested

    def request_termination(self) -> None:
        self._termination_requested = True
        self.touch()

    def touch(self) -> None:
        self.last_activity_monotonic = time.monotonic()

    def touch_user(self) -> None:
        self.user_turn += 1
        self.touch()

    def bind_tool_action_handler(
        self,
        handler: Callable[[dict[str, Any]], Awaitable[dict[str, Any] | None]],
    ) -> None:
        if self._active_tool_calls:
            raise RuntimeError("Cannot bind terminal action handler during tool execution")
        self._tool_action_handler = handler

    def spawn(self, work: Coroutine[Any, Any, Any]) -> asyncio.Task[Any]:
        task = asyncio.create_task(work)
        self._background_tasks.add(task)
        task.add_done_callback(self._background_tasks.discard)
        return task

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

    async def safe_event(
        self,
        event: str,
        payload: dict[str, Any] | None = None,
        *,
        event_id: str | None = None,
    ) -> bool:
        self._event_sequence += 1
        event_id = event_id or (
            f"pipecat:{self.correlation.runtime_session_id}:{self._event_sequence}:{event}"
        )
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

    async def safe_heartbeat(self) -> dict[str, Any] | None:
        try:
            return await self.client.send_heartbeat(self.correlation)
        except (OnelinkApiError, TimeoutError):
            return None

    async def safe_control(
        self,
        action: str,
        payload: dict[str, Any] | None = None,
        *,
        tool_call_id: str | None = None,
        tool_name: str | None = None,
    ) -> bool:
        self._control_sequence += 1
        event_id = (
            f"pipecat-control:{self.correlation.runtime_session_id}:"
            f"{self._control_sequence}:{action}"
        )
        control_payload = {
            **(payload or {}),
            "tool_call_id": tool_call_id,
            "tool_name": tool_name,
        }
        try:
            await self.client.send_control(
                self.correlation,
                action=action,
                event_key=event_id,
                metadata={
                    key: value for key, value in control_payload.items() if value is not None
                },
            )
            return True
        except (OnelinkApiError, TimeoutError):
            await self.safe_event(action, control_payload, event_id=event_id)
            return False

    async def execute_tool(
        self,
        name: str,
        arguments: dict[str, Any],
        tool_call_id: str,
        *,
        timeout_ms: int,
    ) -> dict[str, Any]:
        tool_call_id = tool_call_id.strip()
        if not tool_call_id:
            return {"error": "tool_execution_failed", "code": "TOOL_IDEMPOTENCY_KEY_REQUIRED"}
        fingerprint = self._tool_fingerprint(name, arguments)
        semantic_key = self._semantic_tool_key(name)
        creator = False
        semantic_reused = False
        semantic_reuse_key: tuple[str, int] | None = None
        async with self._tool_lock:
            future = self._tool_results.get(tool_call_id)
            if future is None:
                semantic_lookup_key = semantic_key
                if semantic_key is not None:
                    call_scope_key = (semantic_key[0], -1)
                    if call_scope_key in self._semantic_tool_results:
                        semantic_lookup_key = call_scope_key
                semantic_future = (
                    self._semantic_tool_results.get(semantic_lookup_key)
                    if semantic_lookup_key is not None
                    else None
                )
                if (
                    semantic_lookup_key is not None
                    and semantic_future is not None
                    and not self._semantic_result_reusable(semantic_future)
                ):
                    self._semantic_tool_results.pop(semantic_lookup_key, None)
                    semantic_future = None
                future = semantic_future or asyncio.get_running_loop().create_future()
                self._tool_results[tool_call_id] = future
                self._tool_fingerprints[tool_call_id] = fingerprint
                if semantic_future is None:
                    if semantic_key:
                        self._semantic_tool_results[semantic_key] = future
                    creator = True
                else:
                    semantic_reused = True
                    semantic_reuse_key = semantic_lookup_key
            elif self._tool_fingerprints.get(tool_call_id) != fingerprint:
                return {"error": "tool_execution_failed", "code": "TOOL_IDEMPOTENCY_CONFLICT"}
        if not creator:
            if semantic_reused and semantic_reuse_key:
                self.spawn(
                    self.safe_control(
                        "tool_suppressed",
                        {
                            "dedupe_scope": (
                                "call" if semantic_reuse_key[1] < 0 else "caller_turn"
                            ),
                            "duplicate": True,
                            "user_turn": self.user_turn,
                        },
                        tool_call_id=tool_call_id,
                        tool_name=name,
                    )
                )
            return await asyncio.shield(future)

        self._active_tool_calls += 1
        self.touch()
        try:
            self.spawn(
                self.safe_control(
                    "tool_started",
                    self._tool_audit_metadata(arguments),
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
                terminal_action = False
                if (
                    isinstance(result, dict)
                    and result.get("action")
                    and self._tool_action_handler is not None
                ):
                    terminal_action = self._terminal_action(result)
                    if terminal_action:
                        completion_task = self.spawn(
                            self._complete_terminal_tool(
                                name=name,
                                result=result,
                                tool_call_id=tool_call_id,
                            )
                        )
                        result = await asyncio.shield(completion_task)
                    else:
                        result = await self._apply_tool_action(result)
                if not terminal_action:
                    self.spawn(
                        self.safe_control(
                            "tool_completed",
                            self._tool_audit_metadata(result),
                            tool_call_id=tool_call_id,
                            tool_name=name,
                        )
                    )
            except (OnelinkApiError, TimeoutError) as error:
                outcome_unknown = semantic_key is not None and self._tool_outcome_unknown(
                    error
                )
                result = {
                    "error": (
                        "tool_execution_outcome_unknown"
                        if outcome_unknown
                        else "tool_execution_failed"
                    ),
                    "code": getattr(error, "code", "TOOL_TIMEOUT"),
                }
                if outcome_unknown:
                    result.update({"status": "outcome_unknown", "retryable": False})
                terminal_fallback = {
                    "action": "end_call",
                    "status": "accepted",
                    "reason": arguments.get("reason") or "ai_voice_end_call",
                    "callback_error": result["code"],
                }
                if name.strip().lower() in {"end_call", "hangup"} and self._tool_action_handler:
                    completion_task = self.spawn(
                        self._complete_terminal_tool(
                            name=name,
                            result=terminal_fallback,
                            tool_call_id=tool_call_id,
                        )
                    )
                    try:
                        result = await asyncio.shield(completion_task)
                    except (OnelinkApiError, TimeoutError):
                        pass
                if result.get("action") != "end_call":
                    self.spawn(
                        self.safe_control(
                            "tool_failed",
                            result,
                            tool_call_id=tool_call_id,
                            tool_name=name,
                        )
                    )
            future.set_result(result)
            if semantic_key and result.get("status") == "outcome_unknown":
                async with self._tool_lock:
                    self._semantic_tool_results[(semantic_key[0], -1)] = future
            elif semantic_key and self._tool_result_failed(result):
                async with self._tool_lock:
                    self._remove_semantic_future_locked(future)
            return result
        except BaseException:
            if not future.done():
                future.cancel()
            if semantic_key:
                async with self._tool_lock:
                    self._remove_semantic_future_locked(future)
            raise
        finally:
            self._active_tool_calls -= 1
            self.touch()

    @staticmethod
    def _terminal_action(result: dict[str, Any]) -> bool:
        return str(result.get("action") or "").strip().lower() in {
            "transfer",
            "callback_handoff",
            "end_call",
            "hangup",
        }

    @staticmethod
    def _tool_fingerprint(name: str, value: Any) -> str:
        canonical = json.dumps(
            {"tool_name": name.strip(), "value": value},
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            default=str,
        )
        return hashlib.sha256(canonical.encode()).hexdigest()

    def _semantic_tool_key(self, name: str) -> tuple[str, int] | None:
        normalized = name.strip().lower()
        if normalized not in SEMANTIC_MUTATION_FENCE_TOOLS:
            return None
        return normalized, self.user_turn

    def _remove_semantic_future_locked(
        self, future: asyncio.Future[dict[str, Any]]
    ) -> None:
        for key, candidate in list(self._semantic_tool_results.items()):
            if candidate is future:
                self._semantic_tool_results.pop(key, None)

    @staticmethod
    def _tool_outcome_unknown(error: OnelinkApiError | TimeoutError) -> bool:
        if isinstance(error, TimeoutError):
            return True
        if error.code in {"transport_error", "invalid_json", "invalid_contract"}:
            return True
        return error.status == 0 or error.status in {408, 429} or error.status >= 500

    @classmethod
    def _semantic_result_reusable(
        cls, future: asyncio.Future[dict[str, Any]]
    ) -> bool:
        if future.cancelled():
            return False
        if not future.done():
            return True
        try:
            return not cls._tool_result_failed(future.result())
        except BaseException:
            return False

    @staticmethod
    def _tool_result_failed(result: dict[str, Any]) -> bool:
        status = str(result.get("status") or "").lower()
        if status == "outcome_unknown":
            return False
        return bool(result.get("error")) or status in {"error", "failed"}

    @classmethod
    def _tool_audit_metadata(cls, value: Any) -> dict[str, Any]:
        keys = sorted(str(key) for key in value)[:50] if isinstance(value, dict) else []
        return {"keys": keys, "fingerprint": cls._tool_fingerprint("audit", value)}

    async def _apply_tool_action(self, result: dict[str, Any]) -> dict[str, Any]:
        if self._tool_action_handler is None:
            return result
        transport_result = await self._tool_action_handler(result)
        if not transport_result:
            return result
        if transport_result.get("continue_call") is True:
            return {
                "status": "failed",
                "action": "continue",
                "error": "transfer_failed",
                "runtime_control": transport_result,
            }
        return {**result, "runtime_control": transport_result}

    async def _complete_terminal_tool(
        self,
        *,
        name: str,
        result: dict[str, Any],
        tool_call_id: str,
    ) -> dict[str, Any]:
        completed = await self._apply_tool_action(result)
        self.spawn(
            self.safe_control(
                "tool_completed",
                self._tool_audit_metadata(completed),
                tool_call_id=tool_call_id,
                tool_name=name,
            )
        )
        return completed

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
