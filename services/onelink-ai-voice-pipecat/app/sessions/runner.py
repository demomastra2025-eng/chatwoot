"""Production session runner: attach -> context -> Pipecat worker -> finalization."""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any, Protocol

from pipecat.frames.frames import LLMRunFrame
from pipecat.workers.runner import WorkerRunner

from app.api.models import RuntimeControl, RuntimeStream
from app.callbacks.outbox import CallbackOutbox
from app.clients.onelink import Correlation, OnelinkApiError, OnelinkClient
from app.clients.runtime_control import RuntimeControlClient
from app.config import Settings
from app.pipeline.context import VoiceContext
from app.pipeline.factory import PipelineAssembly, build_pipeline
from app.recordings.writer import DualChannelRecorder
from app.sessions.state import SessionState

logger = logging.getLogger(__name__)
OUTBOX_REPLAY_INTERVAL_SECONDS = 5.0
RUNTIME_HEARTBEAT_INTERVAL_SECONDS = 15.0
RUNTIME_END_CALL_CALLBACK_TIMEOUT_MS = 1_000
RUNTIME_CONTROL_ACTION_TIMEOUT_SECONDS = 5.0
RUNTIME_CONTROL_CLEANUP_TIMEOUT_SECONDS = 3.0


class RecorderCloser(Protocol):
    async def close(self) -> dict[str, Any]: ...


@dataclass(slots=True)
class TerminalDecision:
    status: str = "completed"
    reason: str = "runtime_closed"
    error: dict[str, Any] | None = None
    decided: bool = False
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def set(
        self,
        status: str,
        reason: str,
        error: dict[str, Any] | None = None,
    ) -> bool:
        async with self.lock:
            if self.decided:
                return False
            self.status = status
            self.reason = reason
            self.error = error
            self.decided = True
            return True


class PipecatSessionRunner:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.callback_outbox = CallbackOutbox(
            settings.recording_root / "voice-recordings" / ".pipecat-callback-outbox"
        )
        self._outbox_replay_task: asyncio.Task[None] | None = None

    async def start(self) -> None:
        await self.callback_outbox.prepare()
        if self._outbox_replay_task is None:
            self._outbox_replay_task = asyncio.create_task(
                self._replay_outbox(), name="pipecat-callback-outbox"
            )

    async def stop(self) -> None:
        task = self._outbox_replay_task
        self._outbox_replay_task = None
        if task is not None:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def _replay_outbox(self) -> None:
        while True:
            try:
                callback_url = self.settings.callback_base_url
                assert callback_url is not None
                async with OnelinkClient(
                    base_url=str(callback_url),
                    token=self.settings.callback_token.get_secret_value(),
                    timeout_seconds=self.settings.callback_timeout_seconds,
                    max_retries=self.settings.callback_max_retries,
                ) as client:
                    await self.callback_outbox.replay(client)
            except asyncio.CancelledError:
                raise
            except Exception as error:
                logger.warning(
                    "Pipecat callback outbox pass deferred error_class=%s",
                    type(error).__name__,
                )
            await asyncio.sleep(OUTBOX_REPLAY_INTERVAL_SECONDS)

    async def __call__(self, payload: dict[str, Any]) -> None:
        runtime_stream = RuntimeStream.model_validate(payload.get("runtime_stream"))
        runtime_control = _runtime_control(payload.get("runtime_control"))
        call_ref = str(payload.get("call_ref") or "").strip()
        if not call_ref:
            raise ValueError("call_ref is required for Pipecat runtime")

        callback_url = self.settings.callback_base_url
        assert callback_url is not None
        callback_token = self.settings.callback_token.get_secret_value()
        async with OnelinkClient(
            base_url=str(callback_url),
            token=callback_token,
            timeout_seconds=self.settings.callback_timeout_seconds,
            max_retries=self.settings.callback_max_retries,
        ) as client:
            control_client = (
                RuntimeControlClient(runtime_control) if runtime_control is not None else None
            )
            requested_action: dict[str, str | None] = {"action": None}

            rails_managed_end_call = _rails_manages_end_call(payload)

            state = SessionState(
                client=client,
                correlation=Correlation(
                    call_ref=call_ref,
                    runtime_session_id=runtime_stream.runtime_session_id,
                    account_id=payload.get("account_id"),
                    conversation_id=payload.get("conversation_id"),
                    call_session_id=payload.get("call_session_id"),
                    inbox_id=payload.get("inbox_id"),
                ),
                callback_outbox=self.callback_outbox,
            )
            try:
                raw_context = payload.pop("_preflight_context", None)
                if raw_context is None:
                    context_payload = _context_payload(
                        payload, runtime_stream.runtime_session_id
                    )
                    raw_context = await client.get_context(context_payload)
                raw_context = {
                    **raw_context,
                    "runtime_engine": "pipecat",
                    "runtime_session_id": runtime_stream.runtime_session_id,
                }
                context = VoiceContext.model_validate(raw_context)
                _assert_tenant_scope(payload, context)
                self.settings.provider_credentials(context.ai.provider)
                state.correlation = context.correlation
                _filter_tools_for_transport(
                    context,
                    has_runtime_control=control_client is not None,
                    rails_managed_end_call=rails_managed_end_call,
                )
                recorder = (
                    DualChannelRecorder(
                        root=self.settings.recording_root,
                        account_id=context.account_id,
                        call_ref=context.call_ref,
                    )
                    if context.recording.enabled
                    else None
                )
                await self._run_worker(
                    context=context,
                    state=state,
                    recorder=recorder,
                    runtime_stream=runtime_stream,
                    requested_action=requested_action,
                    control_client=control_client,
                    rails_managed_end_call=rails_managed_end_call,
                )
            except asyncio.CancelledError:
                if not state.finalized:
                    await state.finalize(status="failed", reason="runtime_cancelled")
                raise
            except Exception as error:
                if not state.finalized:
                    await state.finalize(
                        status="failed",
                        reason="runtime_bootstrap_failed",
                        error={"code": type(error).__name__},
                    )
                raise
            finally:
                if requested_action["action"] not in {"transfer", "end_call"}:
                    await _end_call_safely(control_client)

    async def preflight(self, payload: dict[str, Any]) -> dict[str, Any]:
        call_ref = str(payload.get("call_ref") or "").strip()
        if not call_ref:
            raise ValueError("call_ref is required for Pipecat preflight")
        runtime_stream = payload.get("runtime_stream") or {}
        runtime_session_id = str(
            runtime_stream.get("runtime_session_id") or f"preflight:{call_ref}"
        )
        callback_url = self.settings.callback_base_url
        assert callback_url is not None
        async with OnelinkClient(
            base_url=str(callback_url),
            token=self.settings.callback_token.get_secret_value(),
            timeout_seconds=self.settings.callback_timeout_seconds,
            max_retries=self.settings.callback_max_retries,
        ) as client:
            raw_context = await client.get_context(
                _context_payload(payload, runtime_session_id)
            )
        context = VoiceContext.model_validate(raw_context)
        _assert_tenant_scope(payload, context)
        self.settings.provider_credentials(context.ai.provider)
        return raw_context

    async def _run_worker(
        self,
        *,
        context: VoiceContext,
        state: SessionState,
        recorder: DualChannelRecorder | None,
        runtime_stream: RuntimeStream,
        requested_action: dict[str, str | None],
        control_client: RuntimeControlClient | None,
        rails_managed_end_call: bool,
    ) -> None:
        terminal = TerminalDecision()
        assembly: PipelineAssembly | None = None
        recording: dict[str, Any] | None = None
        recording_error: dict[str, str] | None = None
        try:
            assembly = build_pipeline(
                context=context,
                state=state,
                recorder=recorder,
                runtime_stream=runtime_stream,
                settings=self.settings,
            )

            async def tool_action(result: dict[str, Any]) -> dict[str, Any] | None:
                async def rails_end_call() -> dict[str, Any]:
                    return await state.execute_tool(
                        "end_call",
                        {
                            "reason": "manager_callback_completed",
                            "ended_by": "system",
                        },
                        f"callback-end-call:{state.correlation.runtime_session_id}",
                        timeout_ms=5_000,
                    )

                return await _execute_tool_action(
                    result,
                    speak_exact=assembly.speak_exact,
                    control_client=control_client,
                    requested_action=requested_action,
                    rails_managed_end_call=rails_managed_end_call,
                    rails_end_call=rails_end_call if rails_managed_end_call else None,
                )

            state.bind_tool_action_handler(tool_action)
            self._register_handlers(assembly, state, terminal)
            watchdog = asyncio.create_task(
                self._watchdog(
                    context,
                    state,
                    assembly,
                    terminal,
                    requested_action,
                    control_client,
                ),
                name=f"pipecat-watchdog:{context.call_ref}",
            )
            heartbeat = asyncio.create_task(
                self._heartbeat_loop(context, state, assembly, terminal),
                name=f"pipecat-heartbeat:{context.call_ref}",
            )
            try:
                runner = WorkerRunner(handle_sigint=False, handle_sigterm=False)
                await runner.run(assembly.worker)
            finally:
                watchdog.cancel()
                heartbeat.cancel()
                await asyncio.gather(watchdog, heartbeat, return_exceptions=True)
            if not terminal.decided:
                await terminal.set("completed", "runtime_closed")
        except asyncio.CancelledError:
            await terminal.set("failed", "runtime_cancelled")
            raise
        except Exception as error:
            await terminal.set(
                "failed",
                "provider_error",
                {"code": type(error).__name__},
            )
        finally:
            if assembly is not None and not assembly.worker.has_finished():
                await assembly.worker.cancel(reason=terminal.reason)
            if recorder is not None:
                recording, recording_error = await _close_recorder(recorder)
            await state.finalize(
                status=terminal.status,
                reason=terminal.reason,
                recording=recording,
                error=terminal.error or recording_error,
            )

    def _register_handlers(
        self,
        assembly: PipelineAssembly,
        state: SessionState,
        terminal: TerminalDecision,
    ) -> None:
        @assembly.transport.event_handler("on_connected")
        async def on_connected(_transport: object, _websocket: object) -> None:
            state.touch()
            state.spawn(state.safe_control("ai_answered", {"runtime_engine": "pipecat"}))
            state.spawn(state.safe_event("runtime_connected", {"provider": assembly.provider}))
            if assembly.start_on_connect:
                await assembly.worker.queue_frame(LLMRunFrame())

        @assembly.transport.event_handler("on_disconnected")
        async def on_disconnected(_transport: object, _websocket: object) -> None:
            await terminal.set("completed", "media_stream_closed")
            await assembly.worker.cancel(reason="media_stream_closed")

        @assembly.worker.event_handler("on_pipeline_error")
        async def on_pipeline_error(_worker: object, frame: object) -> None:
            await terminal.set(
                "failed",
                "provider_error",
                {"code": type(frame).__name__},
            )

    async def _watchdog(
        self,
        context: VoiceContext,
        state: SessionState,
        assembly: PipelineAssembly,
        terminal: TerminalDecision,
        requested_action: dict[str, str | None],
        control_client: RuntimeControlClient | None,
    ) -> None:
        started = time.monotonic()
        observed_user_turn = state.user_turn
        silence_stage = 0
        silence_thresholds = (
            context.ai.silence_prompt_after_ms,
            context.ai.second_silence_prompt_after_ms,
            context.ai.max_silence_ms,
        )
        while not terminal.decided:
            await asyncio.sleep(0.1)
            action = requested_action.get("action")
            if action in {"transfer", "end_call"}:
                status = "transferred" if action == "transfer" else "completed"
                await terminal.set(status, f"tool_{action}")
                await assembly.worker.cancel(reason=f"tool_{action}")
                return
            now = time.monotonic()
            if now - started >= context.ai.max_duration_sec:
                await terminal.set("completed", "max_duration")
                await _end_call_safely(control_client)
                await assembly.worker.cancel(reason="max_duration")
                return

            if state.user_turn != observed_user_turn:
                observed_user_turn = state.user_turn
                silence_stage = 0
            if state.tool_in_progress or assembly.activity.bot_speaking:
                continue
            idle_ms = (now - state.last_activity_monotonic) * 1_000
            if not context.ai.silence_prompt_enabled:
                continue
            if silence_stage >= len(silence_thresholds):
                continue
            silence_threshold = silence_thresholds[silence_stage]
            if silence_threshold == 0:
                silence_stage += 1
                continue
            if idle_ms < silence_threshold:
                continue

            if silence_stage == 0:
                silence_stage = 1
                await _queue_exact_message(assembly, context.ai.silence_prompt)
            elif silence_stage == 1:
                silence_stage = 2
                await _queue_exact_message(assembly, context.ai.second_silence_prompt)
            else:
                silence_stage = 3
                if not context.ai.end_call_on_silence_enabled:
                    continue
                await _queue_exact_message(assembly, context.ai.final_silence_message)
                await _end_call_safely(control_client)
                await terminal.set("completed", "max_silence")
                await assembly.worker.cancel(reason="max_silence")
                return

    async def _heartbeat_loop(
        self,
        context: VoiceContext,
        state: SessionState,
        assembly: PipelineAssembly,
        terminal: TerminalDecision,
    ) -> None:
        while not terminal.decided:
            response = await state.safe_heartbeat()
            if response and response.get("terminal"):
                await terminal.set("completed", "server_terminal_state")
                await assembly.worker.cancel(reason="server_terminal_state")
                return
            await asyncio.sleep(RUNTIME_HEARTBEAT_INTERVAL_SECONDS)


async def _end_call_safely(control_client: RuntimeControlClient | None) -> None:
    if control_client is None:
        return
    try:
        await asyncio.wait_for(
            control_client.execute({"action": "end_call"}),
            timeout=RUNTIME_CONTROL_CLEANUP_TIMEOUT_SECONDS,
        )
    except (OnelinkApiError, TimeoutError):
        pass


async def _close_recorder(
    recorder: RecorderCloser,
) -> tuple[dict[str, Any], dict[str, str] | None]:
    try:
        recording = await recorder.close()
    except Exception as error:
        recording = {
            "recording_status": "failed",
            "degraded": True,
            "reason": "recording_finalize_failed",
            "duration_ms": 0,
            "duration_sec": 0,
            "recorded_by": "pipecat",
            "error_class": type(error).__name__,
        }
    if recording.get("recording_status") != "failed":
        return recording, None
    return recording, {
        "code": "recording_finalize_failed",
        "error_class": str(recording.get("error_class") or "RecordingError"),
    }


def _context_payload(payload: dict[str, Any], runtime_session_id: str) -> dict[str, Any]:
    safe = {
        key: value
        for key, value in payload.items()
        if key not in {"runtime_stream", "runtime_control", "janus"}
    }
    sip_profile = safe.get("sip_profile")
    if isinstance(sip_profile, dict):
        safe["sip_profile"] = {
            key: sip_profile.get(key)
            for key in ("id", "profile_kind", "voice_agent")
            if sip_profile.get(key) is not None
        }
    safe["runtime_engine"] = "pipecat"
    safe["runtime_session_id"] = runtime_session_id
    return safe


def _assert_tenant_scope(payload: dict[str, Any], context: VoiceContext) -> None:
    requested_account = payload.get("account_id")
    if requested_account is not None and str(requested_account) != str(context.account_id):
        raise OnelinkApiError("OneLink context account mismatch", code="account_scope_mismatch")
    requested_inbox = payload.get("inbox_id")
    if (
        requested_inbox is not None
        and context.inbox_id is not None
        and str(requested_inbox) != str(context.inbox_id)
    ):
        raise OnelinkApiError("OneLink context inbox mismatch", code="inbox_scope_mismatch")
    requested_call_ref = str(payload.get("call_ref") or "")
    if requested_call_ref != context.call_ref:
        raise OnelinkApiError("OneLink context call mismatch", code="call_scope_mismatch")


def _runtime_control(value: Any) -> RuntimeControl | None:
    return RuntimeControl.model_validate(value) if value is not None else None


def _rails_manages_end_call(payload: dict[str, Any]) -> bool:
    provider = str(payload.get("provider") or "").strip().lower()
    call_ref = str(payload.get("call_ref") or "").strip().lower()
    return provider == "whatsapp_cloud" or call_ref.startswith("whatsapp:")


def _filter_tools_for_transport(
    context: VoiceContext,
    *,
    has_runtime_control: bool,
    rails_managed_end_call: bool,
) -> None:
    if has_runtime_control:
        for tool in context.tools:
            if tool.name == "end_call":
                tool.timeout_ms = min(tool.timeout_ms, RUNTIME_END_CALL_CALLBACK_TIMEOUT_MS)
        return
    unavailable = set()
    rails_managed_callback = (
        rails_managed_end_call and context.ai.manager_handoff_mode == "callback"
    )
    if not rails_managed_callback:
        unavailable.add("request_transfer")
    if not rails_managed_end_call:
        unavailable.add("end_call")
    context.tools = [tool for tool in context.tools if tool.name not in unavailable]


async def _execute_terminal_action(
    result: dict[str, Any],
    *,
    control_client: RuntimeControlClient | None,
    requested_action: dict[str, str | None],
    rails_managed_end_call: bool,
) -> dict[str, Any] | None:
    action = str(result.get("action") or "").strip().lower()
    if action not in {"transfer", "callback_handoff", "end_call"}:
        return None
    runtime_action = "end_call" if action == "callback_handoff" else action
    runtime_result = {**result, "action": runtime_action}
    if control_client is not None:
        requested_action["action"] = runtime_action
        response = await asyncio.wait_for(
            control_client.execute(runtime_result),
            timeout=RUNTIME_CONTROL_ACTION_TIMEOUT_SECONDS,
        )
        return response
    if runtime_action == "end_call" and rails_managed_end_call:
        if result.get("transport_terminate_requested") is not True:
            raise OnelinkApiError(
                "WhatsApp transport termination was not accepted",
                code="whatsapp_transport_termination_failed",
            )
        requested_action["action"] = runtime_action
        return {"status": "accepted", "action": runtime_action, "transport": "whatsapp_cloud"}
    raise OnelinkApiError(
        "Runtime call control is unavailable",
        code="runtime_control_unavailable",
    )


async def _execute_tool_action(
    result: dict[str, Any],
    *,
    speak_exact: Any,
    control_client: RuntimeControlClient | None,
    requested_action: dict[str, str | None],
    rails_managed_end_call: bool,
    rails_end_call: Callable[[], Awaitable[dict[str, Any]]] | None = None,
) -> dict[str, Any] | None:
    action = str(result.get("action") or "").strip().lower()
    if action not in {"transfer", "callback_handoff", "end_call"}:
        return None

    message = str(result.get("message") or "").strip()
    if message:
        announcement_completed = await speak_exact(message)
        if announcement_completed is False:
            raise OnelinkApiError(
                "Terminal announcement did not complete",
                code="terminal_announcement_incomplete",
            )

    if action == "callback_handoff" and control_client is None and rails_managed_end_call:
        if rails_end_call is None:
            raise OnelinkApiError(
                "Rails end-call callback is unavailable",
                code="rails_end_call_unavailable",
            )
        response = await rails_end_call()
        if requested_action.get("action") != "end_call":
            raise OnelinkApiError(
                "Rails did not terminate the callback call",
                code="rails_end_call_failed",
            )
        return response

    try:
        return await _execute_terminal_action(
            result,
            control_client=control_client,
            requested_action=requested_action,
            rails_managed_end_call=rails_managed_end_call,
        )
    except (OnelinkApiError, TimeoutError) as error:
        if action != "transfer":
            raise

        fallback_action = str(result.get("fallback_action") or "continue").strip().lower()
        error_code = getattr(error, "code", "transfer_failed")
        if fallback_action == "continue":
            return {
                "status": "failed",
                "action": "transfer",
                "continue_call": True,
                "error": {"code": error_code},
            }

        fallback_message = str(result.get("fallback_message") or "").strip()
        if fallback_message:
            fallback_announcement_completed = await speak_exact(fallback_message)
            if fallback_announcement_completed is False:
                raise OnelinkApiError(
                    "Transfer fallback announcement did not complete",
                    code="fallback_announcement_incomplete",
                ) from error
        response = await _execute_terminal_action(
            {"action": "end_call"},
            control_client=control_client,
            requested_action=requested_action,
            rails_managed_end_call=rails_managed_end_call,
        )
        return {
            "status": "fallback_completed",
            "action": "transfer",
            "fallback_action": fallback_action,
            "error": {"code": error_code},
            "runtime_control": response,
        }


async def _queue_exact_message(assembly: PipelineAssembly, message: str) -> None:
    await assembly.speak_exact(message)
