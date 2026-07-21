from typing import Any, cast

import pytest

from app.clients.onelink import OnelinkApiError
from app.config import Settings
from app.pipeline.context import ToolDefinition, VoiceContext
from app.sessions import runner as runner_module
from app.sessions.runner import (
    PipecatSessionRunner,
    _close_recorder,
    _end_call_safely,
    _execute_terminal_action,
    _filter_tools_for_transport,
    _rails_manages_end_call,
)


class FailingRecorder:
    async def close(self):
        raise OSError("synthetic storage failure")


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


class RecordingRuntimeControlClient:
    def __init__(self):
        self.actions = []

    async def execute(self, result):
        self.actions.append(result)
        return {"status": "accepted"}


@pytest.mark.asyncio
async def test_hard_timeout_transport_end_call_is_direct_and_bounded():
    control = RecordingRuntimeControlClient()

    await _end_call_safely(cast(Any, control))

    assert control.actions == [{"action": "end_call"}]


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
