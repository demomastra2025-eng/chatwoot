import asyncio
import time
from contextlib import suppress
from types import SimpleNamespace
from typing import Any, cast

import pytest

from app.clients.onelink import OnelinkApiError
from app.config import Settings
from app.pipeline.context import ToolDefinition, VoiceContext
from app.sessions import runner as runner_module
from app.sessions.runner import (
    PipecatSessionRunner,
    TerminalDecision,
    _assert_tenant_scope,
    _close_recorder,
    _end_call_safely,
    _execute_terminal_action,
    _execute_tool_action,
    _filter_tools_for_transport,
    _rails_manages_end_call,
    _runtime_session_id,
)


class FailingRecorder:
    async def close(self):
        raise OSError("synthetic storage failure")


def test_tenant_scope_rejects_inbox_mismatch():
    context = SimpleNamespace(account_id=42, inbox_id=9, call_ref="call-1")

    with pytest.raises(OnelinkApiError) as raised:
        _assert_tenant_scope(
            {"account_id": 42, "inbox_id": 10, "call_ref": "call-1"},
            cast(Any, context),
        )

    assert raised.value.code == "inbox_scope_mismatch"


def test_runtime_session_id_prefers_route_identity_over_media_stream_identity():
    assert (
        _runtime_session_id(
            {
                "runtime_session_id": "runtime-route-pipecat-1",
                "runtime_stream": {"runtime_session_id": "runtime-media-stream-1"},
            },
            call_ref="call-1",
        )
        == "runtime-route-pipecat-1"
    )
    assert (
        _runtime_session_id(
            {"runtime_stream": {"runtime_session_id": "runtime-media-stream-1"}},
            call_ref="call-1",
        )
        == "runtime-media-stream-1"
    )
    assert _runtime_session_id({}, call_ref="call-1") == "preflight:call-1"


def test_tenant_scope_allows_missing_inbox_on_either_side():
    context = SimpleNamespace(account_id=42, inbox_id=None, call_ref="call-1")

    _assert_tenant_scope(
        {"account_id": 42, "inbox_id": 10, "call_ref": "call-1"},
        cast(Any, context),
    )
    _assert_tenant_scope(
        {"account_id": 42, "call_ref": "call-1"},
        cast(Any, SimpleNamespace(account_id=42, inbox_id=9, call_ref="call-1")),
    )


class WatchdogAssembly:
    def __init__(self):
        self.messages = []
        self.cancellations = []
        self.worker = self
        self.activity = SimpleNamespace(bot_speaking=False, user_speaking=False)
        self.tool_dialogue = SimpleNamespace(awaiting_continuation=False)

    async def speak_exact(self, message):
        self.messages.append(message)
        return True

    async def cancel(self, *, reason):
        self.cancellations.append(reason)


@pytest.mark.asyncio
async def test_recording_close_error_becomes_terminal_degradation():
    recording, error = await _close_recorder(FailingRecorder())

    assert recording["recording_status"] == "failed"
    assert recording["degraded"] is True
    assert recording["duration_sec"] == 0
    assert error == {
        "code": "recording_finalize_failed",
        "error_class": "OSError",
    }


class FailingContextClient:
    def __init__(self):
        self.finalizations = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return None

    async def get_context(self, _payload):
        raise OnelinkApiError("context unavailable", code="context_unavailable")

    async def finalize_call(self, correlation, **kwargs):
        self.finalizations.append((correlation, kwargs))
        return {"status": "ok"}


class SuccessfulContextClient:
    def __init__(self, context):
        self.context = context

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return None

    async def get_context(self, _payload):
        return self.context


class RecordingRuntimeControlClient:
    def __init__(self):
        self.actions = []

    async def execute(self, result):
        self.actions.append(result)
        return {"status": "accepted"}


class TransferFailingRuntimeControlClient(RecordingRuntimeControlClient):
    async def execute(self, result):
        self.actions.append(result)
        if result["action"] == "transfer":
            raise OnelinkApiError("operator did not answer", code="transfer_timeout")
        return {"status": "accepted"}


@pytest.mark.asyncio
async def test_hard_timeout_transport_end_call_is_direct_and_bounded():
    control = RecordingRuntimeControlClient()

    await _end_call_safely(cast(Any, control))

    assert control.actions == [{"action": "end_call"}]


@pytest.mark.asyncio
async def test_all_zero_silence_thresholds_disable_every_watchdog_stage():
    context = SimpleNamespace(
        ai=SimpleNamespace(
            max_duration_sec=900,
            silence_prompt_enabled=True,
            silence_prompt_after_ms=0,
            second_silence_prompt_after_ms=0,
            max_silence_ms=0,
            end_call_on_silence_enabled=True,
            silence_prompt="Вы меня слышите?",
            second_silence_prompt="Остаётесь на линии?",
            final_silence_message="Завершаю звонок.",
        )
    )
    state = SimpleNamespace(
        user_turn=0,
        tool_in_progress=False,
        last_activity_monotonic=time.monotonic() - 60,
    )
    assembly = WatchdogAssembly()
    terminal = TerminalDecision()
    task = asyncio.create_task(
        PipecatSessionRunner._watchdog(
            cast(Any, None),
            cast(Any, context),
            cast(Any, state),
            cast(Any, assembly),
            terminal,
            {"action": None},
            None,
        )
    )

    await asyncio.sleep(0.4)
    task.cancel()
    with suppress(asyncio.CancelledError):
        await task

    assert assembly.messages == []
    assert assembly.cancellations == []
    assert terminal.decided is False


@pytest.mark.asyncio
async def test_silence_watchdog_waits_while_assistant_is_speaking():
    context = SimpleNamespace(
        ai=SimpleNamespace(
            max_duration_sec=900,
            silence_prompt_enabled=True,
            silence_prompt_after_ms=1,
            second_silence_prompt_after_ms=0,
            max_silence_ms=0,
            end_call_on_silence_enabled=True,
            silence_prompt="Вы меня слышите?",
            second_silence_prompt="Остаётесь на линии?",
            final_silence_message="Завершаю звонок.",
        )
    )
    state = SimpleNamespace(
        user_turn=0,
        tool_in_progress=False,
        last_activity_monotonic=time.monotonic() - 60,
    )
    assembly = WatchdogAssembly()
    assembly.activity.bot_speaking = True
    terminal = TerminalDecision()
    task = asyncio.create_task(
        PipecatSessionRunner._watchdog(
            cast(Any, None),
            cast(Any, context),
            cast(Any, state),
            cast(Any, assembly),
            terminal,
            {"action": None},
            None,
        )
    )

    await asyncio.sleep(0.25)
    task.cancel()
    with suppress(asyncio.CancelledError):
        await task

    assert assembly.messages == []
    assert assembly.cancellations == []
    assert terminal.decided is False


@pytest.mark.asyncio
async def test_silence_watchdog_waits_while_caller_is_speaking():
    context = SimpleNamespace(
        ai=SimpleNamespace(
            max_duration_sec=900,
            silence_prompt_enabled=True,
            silence_prompt_after_ms=1,
            second_silence_prompt_after_ms=0,
            max_silence_ms=0,
            end_call_on_silence_enabled=True,
            silence_prompt="Вы меня слышите?",
            second_silence_prompt="Остаётесь на линии?",
            final_silence_message="Завершаю звонок.",
        )
    )
    state = SimpleNamespace(
        user_turn=1,
        tool_in_progress=False,
        last_activity_monotonic=time.monotonic() - 60,
    )
    assembly = WatchdogAssembly()
    assembly.activity.user_speaking = True
    terminal = TerminalDecision()
    task = asyncio.create_task(
        PipecatSessionRunner._watchdog(
            cast(Any, None),
            cast(Any, context),
            cast(Any, state),
            cast(Any, assembly),
            terminal,
            {"action": None},
            None,
        )
    )

    await asyncio.sleep(0.25)
    task.cancel()
    with suppress(asyncio.CancelledError):
        await task

    assert assembly.messages == []
    assert assembly.cancellations == []
    assert terminal.decided is False


@pytest.mark.asyncio
async def test_silence_watchdog_stays_quiet_after_end_call_is_requested():
    context = SimpleNamespace(
        ai=SimpleNamespace(
            max_duration_sec=900,
            silence_prompt_enabled=True,
            silence_prompt_after_ms=1,
            second_silence_prompt_after_ms=0,
            max_silence_ms=0,
            end_call_on_silence_enabled=True,
            silence_prompt="Вы меня слышите?",
            second_silence_prompt="Остаётесь на линии?",
            final_silence_message="Завершаю звонок.",
        )
    )
    state = SimpleNamespace(
        user_turn=0,
        tool_in_progress=False,
        termination_requested=True,
        last_activity_monotonic=time.monotonic() - 60,
    )
    assembly = WatchdogAssembly()
    terminal = TerminalDecision()
    task = asyncio.create_task(
        PipecatSessionRunner._watchdog(
            cast(Any, None),
            cast(Any, context),
            cast(Any, state),
            cast(Any, assembly),
            terminal,
            {"action": None},
            None,
        )
    )

    await asyncio.sleep(0.25)
    task.cancel()
    with suppress(asyncio.CancelledError):
        await task

    assert assembly.messages == []
    assert assembly.cancellations == []
    assert terminal.decided is False


@pytest.mark.asyncio
async def test_silence_watchdog_waits_for_post_tool_model_continuation():
    context = SimpleNamespace(
        ai=SimpleNamespace(
            max_duration_sec=900,
            silence_prompt_enabled=True,
            silence_prompt_after_ms=1,
            second_silence_prompt_after_ms=0,
            max_silence_ms=0,
            end_call_on_silence_enabled=True,
            silence_prompt="Вы меня слышите?",
            second_silence_prompt="Остаётесь на линии?",
            final_silence_message="Завершаю звонок.",
        )
    )
    state = SimpleNamespace(
        user_turn=0,
        tool_in_progress=False,
        last_activity_monotonic=time.monotonic() - 60,
    )
    assembly = WatchdogAssembly()
    assembly.tool_dialogue.awaiting_continuation = True
    terminal = TerminalDecision()
    task = asyncio.create_task(
        PipecatSessionRunner._watchdog(
            cast(Any, None),
            cast(Any, context),
            cast(Any, state),
            cast(Any, assembly),
            terminal,
            {"action": None},
            None,
        )
    )

    await asyncio.sleep(0.25)
    task.cancel()
    with suppress(asyncio.CancelledError):
        await task

    assert assembly.messages == []
    assert terminal.decided is False


@pytest.mark.asyncio
async def test_max_silence_speaks_then_ends_transport_before_pipeline_cancel():
    events = []
    context = SimpleNamespace(
        ai=SimpleNamespace(
            max_duration_sec=900,
            silence_prompt_enabled=True,
            silence_prompt_after_ms=0,
            second_silence_prompt_after_ms=0,
            max_silence_ms=1,
            end_call_on_silence_enabled=True,
            silence_prompt="Вы меня слышите?",
            second_silence_prompt="Остаётесь на линии?",
            final_silence_message="Завершаю звонок.",
        )
    )
    state = SimpleNamespace(
        user_turn=0,
        tool_in_progress=False,
        last_activity_monotonic=time.monotonic() - 60,
    )

    class OrderedAssembly:
        def __init__(self):
            self.worker = self
            self.activity = SimpleNamespace(bot_speaking=False, user_speaking=False)
            self.tool_dialogue = SimpleNamespace(awaiting_continuation=False)

        async def speak_exact(self, message):
            events.append(("speech", message))
            return True

        async def cancel(self, *, reason):
            events.append(("cancel", reason))

    class OrderedControl(RecordingRuntimeControlClient):
        async def execute(self, result):
            events.append(("control", result["action"]))
            return await super().execute(result)

    terminal = TerminalDecision()
    await asyncio.wait_for(
        PipecatSessionRunner._watchdog(
            cast(Any, None),
            cast(Any, context),
            cast(Any, state),
            cast(Any, OrderedAssembly()),
            terminal,
            {"action": None},
            cast(Any, OrderedControl()),
        ),
        timeout=1,
    )

    assert events == [
        ("speech", "Завершаю звонок."),
        ("control", "end_call"),
        ("cancel", "max_silence"),
    ]
    assert terminal.reason == "max_silence"


@pytest.mark.asyncio
async def test_callback_handoff_speaks_before_ending_the_call():
    events = []
    requested_action: dict[str, str | None] = {"action": None}

    class OrderedRuntimeControlClient(RecordingRuntimeControlClient):
        async def execute(self, result):
            events.append(("control", result["action"]))
            return await super().execute(result)

    async def speak_exact(message):
        events.append(("speech", message))

    response = await _execute_tool_action(
        {
            "action": "callback_handoff",
            "message": "Наш менеджер вам перезвонит.",
        },
        speak_exact=speak_exact,
        control_client=cast(Any, OrderedRuntimeControlClient()),
        rails_managed_end_call=False,
        requested_action=requested_action,
    )

    assert events == [
        ("speech", "Наш менеджер вам перезвонит."),
        ("control", "end_call"),
    ]
    assert response == {"status": "accepted"}
    assert requested_action == {"action": "end_call"}


@pytest.mark.asyncio
async def test_end_call_intent_is_visible_while_runtime_control_is_in_flight():
    requested_action: dict[str, str | None] = {"action": None}
    control_started = asyncio.Event()
    release_control = asyncio.Event()

    class SlowEndCallControlClient(RecordingRuntimeControlClient):
        async def execute(self, result):
            control_started.set()
            await release_control.wait()
            return await super().execute(result)

    execution = asyncio.create_task(
        _execute_terminal_action(
            {"action": "end_call", "reason": "caller requested hangup"},
            control_client=cast(Any, SlowEndCallControlClient()),
            requested_action=requested_action,
            rails_managed_end_call=False,
        )
    )

    await asyncio.wait_for(control_started.wait(), timeout=0.1)
    assert requested_action == {"action": "end_call"}
    release_control.set()
    assert await execution == {"status": "accepted"}


@pytest.mark.asyncio
async def test_callback_handoff_uses_rails_end_call_without_runtime_control():
    requested_action: dict[str, str | None] = {"action": None}
    spoken = []

    async def speak_exact(message):
        spoken.append(message)
        return True

    async def rails_end_call():
        requested_action["action"] = "end_call"
        return {"action": "end_call", "status": "completed"}

    response = await _execute_tool_action(
        {
            "action": "callback_handoff",
            "message": "Наш менеджер вам перезвонит.",
        },
        speak_exact=speak_exact,
        control_client=None,
        rails_managed_end_call=True,
        requested_action=requested_action,
        rails_end_call=rails_end_call,
    )

    assert spoken == ["Наш менеджер вам перезвонит."]
    assert response == {"action": "end_call", "status": "completed"}
    assert requested_action == {"action": "end_call"}


@pytest.mark.asyncio
async def test_terminal_action_fails_closed_when_announcement_does_not_complete():
    requested_action: dict[str, str | None] = {"action": None}
    control = RecordingRuntimeControlClient()

    async def speak_exact(_message):
        return False

    with pytest.raises(OnelinkApiError) as raised:
        await _execute_tool_action(
            {
                "action": "transfer",
                "message": "Сейчас соединю со специалистом.",
            },
            speak_exact=speak_exact,
            control_client=cast(Any, control),
            rails_managed_end_call=False,
            requested_action=requested_action,
        )

    assert raised.value.code == "terminal_announcement_incomplete"
    assert control.actions == []
    assert requested_action == {"action": None}


@pytest.mark.asyncio
async def test_transfer_fallback_fails_closed_when_announcement_does_not_complete():
    requested_action: dict[str, str | None] = {"action": None}
    control = TransferFailingRuntimeControlClient()
    announcements = iter([True, False])

    async def speak_exact(_message):
        return next(announcements)

    with pytest.raises(OnelinkApiError) as raised:
        await _execute_tool_action(
            {
                "action": "transfer",
                "message": "Сейчас соединю со специалистом.",
                "fallback_action": "callback",
                "fallback_message": "Менеджер вам перезвонит.",
            },
            speak_exact=speak_exact,
            control_client=cast(Any, control),
            rails_managed_end_call=False,
            requested_action=requested_action,
        )

    assert raised.value.code == "fallback_announcement_incomplete"
    assert [item["action"] for item in control.actions] == ["transfer"]
    assert requested_action == {"action": "transfer"}


@pytest.mark.asyncio
async def test_failed_transfer_uses_callback_fallback_after_both_messages():
    spoken = []
    requested_action: dict[str, str | None] = {"action": None}
    control = TransferFailingRuntimeControlClient()

    async def speak_exact(message):
        spoken.append(message)

    response = await _execute_tool_action(
        {
            "action": "transfer",
            "destination": "sip:operator@example.test",
            "message": "Сейчас соединю со специалистом.",
            "fallback_action": "callback",
            "fallback_message": "Соединить не удалось. Менеджер вам перезвонит.",
        },
        speak_exact=speak_exact,
        control_client=cast(Any, control),
        rails_managed_end_call=False,
        requested_action=requested_action,
    )

    assert spoken == [
        "Сейчас соединю со специалистом.",
        "Соединить не удалось. Менеджер вам перезвонит.",
    ]
    assert [item["action"] for item in control.actions] == ["transfer", "end_call"]
    assert response is not None
    assert response["status"] == "fallback_completed"
    assert response["fallback_action"] == "callback"
    assert requested_action == {"action": "end_call"}


@pytest.mark.asyncio
async def test_failed_transfer_can_return_control_to_the_model():
    requested_action: dict[str, str | None] = {"action": None}

    async def speak_exact(_message):
        return None

    response = await _execute_tool_action(
        {
            "action": "transfer",
            "destination": "sip:operator@example.test",
            "message": "Сейчас соединю.",
            "fallback_action": "continue",
        },
        speak_exact=speak_exact,
        control_client=cast(Any, TransferFailingRuntimeControlClient()),
        rails_managed_end_call=False,
        requested_action=requested_action,
    )

    assert response is not None
    assert response["status"] == "failed"
    assert response["continue_call"] is True
    assert requested_action == {"action": "transfer"}


@pytest.mark.asyncio
async def test_terminal_control_timeout_is_bounded_and_preserves_ambiguous_transfer(monkeypatch):
    requested_action: dict[str, str | None] = {"action": None}

    class HangingRuntimeControlClient:
        async def execute(self, _result):
            await asyncio.Event().wait()

    monkeypatch.setattr(runner_module, "RUNTIME_CONTROL_ACTION_TIMEOUT_SECONDS", 0.01)
    with pytest.raises(TimeoutError):
        await asyncio.wait_for(
            _execute_terminal_action(
                {"action": "transfer", "destination": "sip:operator@example.test"},
                control_client=cast(Any, HangingRuntimeControlClient()),
                requested_action=requested_action,
                rails_managed_end_call=False,
            ),
            timeout=0.1,
        )

    assert requested_action == {"action": "transfer"}


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("stt_provider", "elevenlabs_api_key"),
    [("fish", ""), ("elevenlabs", "elevenlabs-secret")],
)
async def test_fish_preflight_accepts_both_stt_variants(
    monkeypatch, tmp_path, stt_provider, elevenlabs_api_key
):
    raw_context = {
        "call_ref": "sipuni:janus-ai:fish-preflight",
        "account_id": 42,
        "ai": {
            "provider": "fish",
            "stt_provider": stt_provider,
            "model": "openai/gpt-5.4-mini",
            "voice": "fish-voice-ref",
            "system_prompt": "Test prompt",
        },
    }
    client = SuccessfulContextClient(raw_context)
    monkeypatch.setattr(runner_module, "OnelinkClient", lambda **_kwargs: client)
    runner = PipecatSessionRunner(
        Settings.model_validate(
            {
                "internal_token": "voice-secret",
                "callback_base_url": "http://rails.internal",
                "callback_token": "callback-secret",
                "fish_api_key": "fish-secret",
                "openrouter_api_key": "openrouter-secret",
                "elevenlabs_api_key": elevenlabs_api_key,
                "recording_root": tmp_path,
            }
        )
    )

    result = await runner.preflight(
        {"call_ref": raw_context["call_ref"], "account_id": 42}
    )

    assert result["ai"]["stt_provider"] == stt_provider


@pytest.mark.asyncio
async def test_context_bootstrap_error_is_finalized_once(monkeypatch, tmp_path):
    client = FailingContextClient()
    control = RecordingRuntimeControlClient()
    monkeypatch.setattr(runner_module, "OnelinkClient", lambda **_kwargs: client)
    monkeypatch.setattr(runner_module, "RuntimeControlClient", lambda _capability: control)
    settings = Settings(
        internal_token="voice-secret",
        callback_base_url="http://rails.internal",
        callback_token="callback-secret",
        gemini_api_key="gemini-secret",
        recording_root=tmp_path,
    )
    runner = PipecatSessionRunner(settings)

    with pytest.raises(OnelinkApiError, match="context unavailable"):
        await runner(
            {
                "call_ref": "sipuni:janus-ai:bootstrap-failure",
                "account_id": 42,
                "conversation_id": 91,
                "call_session_id": 17,
                "inbox_id": 8,
                "runtime_stream": {
                    "runtime_session_id": "runtime-bootstrap-failure",
                    "stream_url": "ws://media.internal/runtime-stream",
                    "stream_token": "stream-token-secret-1234567890",
                },
                "runtime_control": {
                    "control_url": "http://voice.internal/runtime-control/capability",
                    "token": "control-token-secret-1234567890",
                },
            }
        )

    assert len(client.finalizations) == 1
    correlation, kwargs = client.finalizations[0]
    assert correlation.account_id == 42
    assert kwargs["payload"]["status"] == "failed"
    assert kwargs["payload"]["reason"] == "runtime_bootstrap_failed"
    assert kwargs["payload"]["error"] == {"code": "OnelinkApiError"}
    assert control.actions == [{"action": "end_call"}]


def test_runtime_control_bounds_end_call_callback_before_direct_fallback():
    context = SimpleNamespace(
        tools=[
            ToolDefinition(name="end_call", description="hang up", timeout_ms=5_000),
            ToolDefinition(name="create_note", description="note", timeout_ms=800),
        ]
    )

    _filter_tools_for_transport(
        cast(Any, context),
        has_runtime_control=True,
        rails_managed_end_call=False,
    )

    assert context.tools[0].timeout_ms == 1_000
    assert context.tools[1].timeout_ms == 800


def test_whatsapp_transport_keeps_end_call_without_runtime_control():
    context = VoiceContext.model_validate(
        {
            "account_id": 42,
            "call_ref": "whatsapp:wa-call-1",
            "runtime_session_id": "runtime-wa-1",
            "ai": {
                "provider": "gemini-live",
                "model": "gemini-live-test",
                "voice": "test-voice",
                "system_prompt": "Test prompt",
            },
            "tools": [
                ToolDefinition(name="request_transfer", description="transfer"),
                ToolDefinition(name="end_call", description="hang up"),
                ToolDefinition(name="create_note", description="note"),
            ],
        }
    )

    _filter_tools_for_transport(
        context,
        has_runtime_control=False,
        rails_managed_end_call=True,
    )

    assert [tool.name for tool in context.tools] == ["end_call", "create_note"]


def test_whatsapp_callback_keeps_request_transfer_without_runtime_control():
    context = VoiceContext.model_validate(
        {
            "account_id": 42,
            "call_ref": "whatsapp:wa-call-callback",
            "runtime_session_id": "runtime-wa-callback",
            "ai": {
                "provider": "gemini-live",
                "model": "gemini-live-test",
                "voice": "test-voice",
                "system_prompt": "Test prompt",
                "manager_handoff_mode": "callback",
            },
            "tools": [
                ToolDefinition(name="request_transfer", description="callback"),
                ToolDefinition(name="end_call", description="hang up"),
            ],
        }
    )

    _filter_tools_for_transport(
        context,
        has_runtime_control=False,
        rails_managed_end_call=True,
    )

    assert [tool.name for tool in context.tools] == ["request_transfer", "end_call"]


def test_non_whatsapp_transport_removes_terminal_tools_without_runtime_control():
    context = VoiceContext.model_validate(
        {
            "account_id": 42,
            "call_ref": "sipuni:janus-ai:call-1",
            "runtime_session_id": "runtime-sip-1",
            "ai": {
                "provider": "gemini-live",
                "model": "gemini-live-test",
                "voice": "test-voice",
                "system_prompt": "Test prompt",
            },
            "tools": [
                ToolDefinition(name="request_transfer", description="transfer"),
                ToolDefinition(name="end_call", description="hang up"),
            ],
        }
    )

    _filter_tools_for_transport(
        context,
        has_runtime_control=False,
        rails_managed_end_call=False,
    )

    assert context.tools == []


@pytest.mark.asyncio
async def test_whatsapp_end_call_uses_rails_transport_termination_without_runtime_control():
    requested_action = {"action": None}

    result = await _execute_terminal_action(
        {
            "action": "end_call",
            "transport_terminate_requested": True,
        },
        control_client=None,
        requested_action=requested_action,
        rails_managed_end_call=True,
    )

    assert result == {
        "status": "accepted",
        "action": "end_call",
        "transport": "whatsapp_cloud",
    }
    assert requested_action == {"action": "end_call"}


@pytest.mark.asyncio
async def test_whatsapp_end_call_fails_closed_when_rails_did_not_terminate_transport():
    requested_action: dict[str, str | None] = {"action": None}
    with pytest.raises(OnelinkApiError) as raised:
        await _execute_terminal_action(
            {
                "action": "end_call",
                "transport_terminate_requested": False,
            },
            control_client=None,
            requested_action=requested_action,
            rails_managed_end_call=True,
        )

    assert raised.value.code == "whatsapp_transport_termination_failed"


def test_whatsapp_transport_is_detected_by_provider_or_call_ref():
    assert _rails_manages_end_call({"provider": "whatsapp_cloud", "call_ref": "call-1"})
    assert _rails_manages_end_call({"call_ref": "whatsapp:call-2"})
    assert not _rails_manages_end_call(
        {"provider": "sipuni", "call_ref": "sipuni:call-3"}
    )
