"""Human-like progress and continuation control around Pipecat tool calls."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable, Coroutine
from contextlib import suppress
from typing import Any, Protocol

from pipecat.services.llm_service import FunctionCallParams

from app.pipeline.context import AiSettings, ToolDefinition
from app.pipeline.processors import ConversationActivity

SpeechCallback = Callable[[str], Awaitable[bool | None]]


class ToolRuntimeState(Protocol):
    async def execute_tool(
        self,
        name: str,
        arguments: dict[str, Any],
        tool_call_id: str,
        *,
        timeout_ms: int,
    ) -> dict[str, Any]: ...

    async def safe_control(
        self,
        action: str,
        payload: dict[str, Any] | None = None,
        *,
        tool_call_id: str | None = None,
        tool_name: str | None = None,
    ) -> bool: ...

    def spawn(self, work: Coroutine[Any, Any, Any]) -> asyncio.Task[Any]: ...


class ToolDialogueCoordinator:
    """Coordinate progress speech without duplicating or blocking tool execution."""

    def __init__(
        self,
        *,
        ai: AiSettings,
        state: ToolRuntimeState,
        activity: ConversationActivity,
    ) -> None:
        self._ai = ai
        self._state = state
        self._activity = activity
        self._speak_exact: SpeechCallback | None = None
        self._run_instruction: SpeechCallback | None = None
        self._progress_lock = asyncio.Lock()

    def bind(
        self,
        *,
        speak_exact: SpeechCallback,
        run_instruction: SpeechCallback,
    ) -> None:
        self._speak_exact = speak_exact
        self._run_instruction = run_instruction

    async def execute(
        self,
        definition: ToolDefinition,
        params: FunctionCallParams,
    ) -> None:
        stop_progress = asyncio.Event()
        progress_task: asyncio.Task[None] | None = None
        if self._ai.provider != "gemini-live" and not _is_terminal_tool(definition.name):
            progress_task = asyncio.create_task(
                self._announce_progress(definition, stop_progress),
                name=f"pipecat-tool-progress:{params.tool_call_id}",
            )

        try:
            result = await self._state.execute_tool(
                definition.name,
                dict(params.arguments),
                params.tool_call_id,
                timeout_ms=definition.timeout_ms,
            )
        finally:
            stop_progress.set()
            if progress_task is not None:
                with suppress(asyncio.CancelledError):
                    await progress_task

        response_sequence = self._activity.turns_started
        await params.result_callback(result)
        if not _is_terminal_result(result):
            self._state.spawn(
                self._ensure_continuation(
                    definition=definition,
                    result=result,
                    response_sequence=response_sequence,
                    tool_call_id=params.tool_call_id,
                )
            )

    async def _announce_progress(
        self,
        definition: ToolDefinition,
        stopped: asyncio.Event,
    ) -> None:
        foreground_wait_ms = definition.foreground_wait_ms or self._ai.tool_foreground_wait_ms
        start_after_ms = self._ai.tool_start_after_ms
        if foreground_wait_ms > 0:
            start_after_ms = min(start_after_ms, foreground_wait_ms)
        if await _wait_until_stopped(stopped, start_after_ms):
            return
        async with self._progress_lock:
            if stopped.is_set() or self._speak_exact is None:
                return
            start_phrase = _first_phrase(self._ai.tool_start_phrases)
            if start_phrase:
                await self._safe_progress_speech(definition, "started", start_phrase)
            if await _wait_until_stopped(stopped, self._ai.tool_delay_after_ms):
                return
            delay_phrase = _first_phrase(self._ai.tool_delay_phrases)
            if delay_phrase:
                await self._safe_progress_speech(definition, "delayed", delay_phrase)

    async def _safe_progress_speech(
        self,
        definition: ToolDefinition,
        stage: str,
        phrase: str,
    ) -> None:
        try:
            self._state.spawn(
                self._state.safe_control(
                    "tool_progress",
                    {"stage": stage, "phrase": phrase},
                    tool_name=definition.name,
                )
            )
            if self._speak_exact is not None:
                await self._speak_exact(phrase)
        except Exception:
            # Progress speech is best effort and must never fail the actual tool.
            return

    async def _ensure_continuation(
        self,
        *,
        definition: ToolDefinition,
        result: dict[str, Any],
        response_sequence: int,
        tool_call_id: str,
    ) -> None:
        started = await self._activity.wait_for_turn_started_after(
            response_sequence,
            self._ai.post_tool_continuation_ms / 1_000,
        )
        if started:
            return
        self._state.spawn(
            self._state.safe_control(
                "post_tool_model_stall",
                {"result_status": "failed" if _is_error_result(result) else "completed"},
                tool_call_id=tool_call_id,
                tool_name=definition.name,
            )
        )
        if _is_error_result(result):
            failure_phrase = _first_phrase(self._ai.tool_failure_phrases)
            if failure_phrase and self._speak_exact is not None:
                await self._speak_exact(failure_phrase)
            return
        if self._run_instruction is not None:
            await self._run_instruction(
                f"Продолжи голосовой ответ клиенту после результата инструмента {definition.name}. "
                "Не молчи, ответь коротко и естественно, используя уже полученный результат."
            )


def _is_terminal_tool(name: str) -> bool:
    normalized = name.strip().lower()
    return normalized in {"request_transfer", "transfer", "handoff", "end_call", "hangup"}


def _is_terminal_result(result: object) -> bool:
    if not isinstance(result, dict):
        return False
    return str(result.get("action") or "").strip().lower() in {
        "transfer",
        "callback_handoff",
        "end_call",
        "hangup",
    }


def _is_error_result(result: object) -> bool:
    return isinstance(result, dict) and bool(result.get("error"))


def _first_phrase(values: list[str]) -> str:
    return next((value.strip() for value in values if value.strip()), "")


async def _wait_until_stopped(stopped: asyncio.Event, delay_ms: int) -> bool:
    if stopped.is_set():
        return True
    try:
        await asyncio.wait_for(stopped.wait(), timeout=delay_ms / 1_000)
    except TimeoutError:
        return False
    return True
