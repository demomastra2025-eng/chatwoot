import asyncio
from typing import Any, cast

import pytest

from app.callbacks.outbox import CallbackOutbox
from app.clients.onelink import Correlation, OnelinkApiError, OnelinkClient
from app.sessions.state import SessionState


class FakeClient:
    def __init__(self):
        self.events = []
        self.controls = []
        self.transcripts = []
        self.finalizations = []
        self.tools = []
        self.recordings = []

    async def send_event(self, correlation, **kwargs):
        self.events.append((correlation, kwargs))
        return {"status": "ok"}

    async def send_control(self, correlation, **kwargs):
        self.controls.append((correlation, kwargs))
        return {"status": "ok"}

    async def send_transcript(self, correlation, **kwargs):
        self.transcripts.append((correlation, kwargs))
        return {"status": "ok"}

    async def finalize_call(self, correlation, **kwargs):
        self.finalizations.append((correlation, kwargs))
        await asyncio.sleep(0)
        return {"status": "ok"}

    async def call_tool(self, correlation, name, arguments, **kwargs) -> dict[str, Any]:
        self.tools.append((correlation, name, arguments, kwargs))
        await asyncio.sleep(0)
        return {"message_id": 99}

    async def recording_stored(self, correlation, **kwargs):
        self.recordings.append((correlation, kwargs))
        return {"status": "ok"}


class FailFinalizeOnceClient(FakeClient):
    async def finalize_call(self, correlation, **kwargs):
        self.finalizations.append((correlation, kwargs))
        if len(self.finalizations) == 1:
            raise OnelinkApiError("temporary finalize failure")
        return {"status": "ok"}


class SlowControlClient(FakeClient):
    def __init__(self):
        super().__init__()
        self.control_gate = asyncio.Event()
        self.tool_called = asyncio.Event()

    async def send_control(self, correlation, **kwargs):
        await self.control_gate.wait()
        return await super().send_control(correlation, **kwargs)

    async def call_tool(self, correlation, name, arguments, **kwargs):
        self.tool_called.set()
        return await super().call_tool(correlation, name, arguments, **kwargs)


class GatedToolClient(FakeClient):
    def __init__(self):
        super().__init__()
        self.tool_gate = asyncio.Event()
        self.tool_called = asyncio.Event()

    async def call_tool(self, correlation, name, arguments, **kwargs):
        self.tool_called.set()
        await self.tool_gate.wait()
        return await super().call_tool(correlation, name, arguments, **kwargs)


class TransferToolClient(FakeClient):
    async def call_tool(self, correlation, name, arguments, **kwargs):
        self.tools.append((correlation, name, arguments, kwargs))
        return {
            "action": "transfer",
            "destination": "sip:operator@example.test",
            "operator_agent_aor": "sip:operator@example.test",
        }


class FailingToolClient(FakeClient):
    async def call_tool(self, correlation, name, arguments, **kwargs):
        self.tools.append((correlation, name, arguments, kwargs))
        raise OnelinkApiError("callback timed out", code="transport_error")


class SlowFailingToolClient(SlowControlClient):
    async def call_tool(self, correlation, name, arguments, **kwargs):
        self.tools.append((correlation, name, arguments, kwargs))
        raise OnelinkApiError("callback timed out", code="transport_error")


@pytest.fixture
def state():
    return SessionState(
        client=FakeClient(),
        correlation=Correlation(
            call_ref="call-1",
            runtime_session_id="runtime-1",
            account_id=7,
            conversation_id=11,
        ),
    )


@pytest.mark.asyncio
async def test_transcript_batch_and_exactly_once_finalize(state):
    await state.add_transcript("caller", "Здрав", final=False)
    await state.add_transcript("caller", "Здравствуйте", final=True)
    await state.add_transcript("ai", "Добрый день", final=True)

    results = await asyncio.gather(
        state.finalize(status="completed", reason="media_stream_closed"),
        state.finalize(status="completed", reason="media_stream_closed"),
    )

    assert results == [True, False]
    assert len(state.client.transcripts) == 1
    assert state.client.transcripts[0][1]["final"] is True
    assert len(state.client.finalizations) == 1
    payload = state.client.finalizations[0][1]["payload"]
    assert payload["status"] == "completed"
    assert [item["speaker"] for item in payload["final_transcript"]] == ["caller", "ai"]
    assert [item["text"] for item in payload["partial_transcript"]] == ["Здрав"]
    assert payload["incomplete_transcript"] is True
    assert payload["event_type"] == "finalize"
    assert payload["event_seq"] == 1
    assert payload["started_at"]
    assert payload["ended_at"]


@pytest.mark.asyncio
async def test_finalize_drains_background_transcript_before_final_flush(state):
    async def add_late_transcript():
        await asyncio.sleep(0)
        await state.add_transcript("ai", "До свидания", final=True)

    state.spawn(add_late_transcript())

    assert await state.finalize(status="completed", reason="runtime_closed")

    payload = state.client.finalizations[0][1]["payload"]
    assert [item["text"] for item in payload["final_transcript"]] == ["До свидания"]


@pytest.mark.asyncio
async def test_duplicate_tool_call_is_fenced_in_process(state):
    first, second = await asyncio.gather(
        state.execute_tool("create_note", {"content": "note"}, "tool-1", timeout_ms=800),
        state.execute_tool("create_note", {"content": "note"}, "tool-1", timeout_ms=800),
    )

    assert first == second == {"message_id": 99}
    assert len(state.client.tools) == 1
    await state.drain_background()
    actions = [item[1]["action"] for item in state.client.controls]
    assert actions == ["tool_started", "tool_completed"]


@pytest.mark.asyncio
async def test_duplicate_tool_call_rejects_different_arguments_in_process(state):
    first = await state.execute_tool(
        "create_note", {"content": "original"}, "tool-conflict", timeout_ms=800
    )
    conflict = await state.execute_tool(
        "create_note", {"content": "forged"}, "tool-conflict", timeout_ms=800
    )

    assert first == {"message_id": 99}
    assert conflict == {
        "error": "tool_execution_failed",
        "code": "TOOL_IDEMPOTENCY_CONFLICT",
    }
    assert len(state.client.tools) == 1


@pytest.mark.asyncio
async def test_failed_transfer_continue_fallback_is_returned_as_non_terminal_result():
    client = TransferToolClient()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(call_ref="call-transfer", runtime_session_id="runtime-transfer"),
    )

    async def continue_after_failed_transfer(_result):
        return {
            "status": "failed",
            "continue_call": True,
            "error": {"code": "transfer_timeout"},
        }

    state.bind_tool_action_handler(continue_after_failed_transfer)

    result = await state.execute_tool(
        "request_transfer",
        {"reason": "customer requested a manager"},
        "tool-transfer",
        timeout_ms=800,
    )

    assert result["action"] == "continue"
    assert result["error"] == "transfer_failed"
    assert "operator_agent_aor" not in result
    assert "destination" not in result
    assert result["runtime_control"]["continue_call"] is True
    assert result["runtime_control"]["error"] == {"code": "transfer_timeout"}


@pytest.mark.asyncio
async def test_end_call_uses_runtime_control_when_rails_tool_callback_fails():
    client = FailingToolClient()
    runtime_actions = []
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(call_ref="call-end", runtime_session_id="runtime-end"),
    )

    async def end_runtime_call(result):
        runtime_actions.append(result)
        return {"status": "accepted"}

    state.bind_tool_action_handler(end_runtime_call)

    result = await state.execute_tool(
        "end_call",
        {"reason": "caller requested hangup", "ended_by": "ai_agent"},
        "tool-end",
        timeout_ms=5_000,
    )

    assert result == {
        "action": "end_call",
        "status": "accepted",
        "reason": "caller requested hangup",
        "callback_error": "transport_error",
        "runtime_control": {"status": "accepted"},
    }
    assert runtime_actions == [
        {
            "action": "end_call",
            "status": "accepted",
            "reason": "caller requested hangup",
            "callback_error": "transport_error",
        }
    ]
    await state.drain_background()
    assert [item[1]["action"] for item in client.controls] == [
        "tool_started",
        "tool_completed",
    ]


@pytest.mark.asyncio
async def test_terminal_runtime_control_and_telemetry_survive_provider_task_cancellation():
    client = FailingToolClient()
    runtime_started = asyncio.Event()
    release_runtime = asyncio.Event()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(call_ref="call-cancel", runtime_session_id="runtime-cancel"),
    )

    async def end_runtime_call(_result):
        runtime_started.set()
        await release_runtime.wait()
        return {"status": "accepted"}

    state.bind_tool_action_handler(end_runtime_call)
    execution = asyncio.create_task(
        state.execute_tool(
            "end_call",
            {"reason": "caller requested hangup"},
            "tool-cancel",
            timeout_ms=5_000,
        )
    )

    await asyncio.wait_for(runtime_started.wait(), timeout=0.1)
    execution.cancel()
    release_runtime.set()
    with pytest.raises(asyncio.CancelledError):
        await execution

    await state.drain_background()
    assert [item[1]["action"] for item in client.controls] == [
        "tool_started",
        "tool_completed",
    ]
    completed = client.controls[-1][1]["metadata"]
    assert {"action", "runtime_control"}.issubset(completed["keys"])
    assert len(completed["fingerprint"]) == 64
    assert "result" not in completed


@pytest.mark.asyncio
async def test_slow_terminal_telemetry_does_not_delay_runtime_end_call():
    client = SlowFailingToolClient()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(call_ref="call-fast-end", runtime_session_id="runtime-fast-end"),
    )

    async def end_runtime_call(_result):
        return {"status": "accepted"}

    state.bind_tool_action_handler(end_runtime_call)
    result = await asyncio.wait_for(
        state.execute_tool(
            "end_call",
            {"reason": "caller requested hangup"},
            "tool-fast-end",
            timeout_ms=5_000,
        ),
        timeout=0.1,
    )

    assert result["action"] == "end_call"
    assert result["runtime_control"] == {"status": "accepted"}
    assert client.controls == []

    client.control_gate.set()
    await state.drain_background()
    assert [item[1]["action"] for item in client.controls] == [
        "tool_started",
        "tool_completed",
    ]


@pytest.mark.asyncio
async def test_slow_control_plane_does_not_delay_tool_execution():
    client = SlowControlClient()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(call_ref="call-fast-tool", runtime_session_id="runtime-fast-tool"),
    )

    execution = asyncio.create_task(
        state.execute_tool("faq_lookup", {"query": "тариф"}, "tool-fast", timeout_ms=5_000)
    )
    await asyncio.wait_for(client.tool_called.wait(), timeout=0.1)
    result = await execution

    assert result == {"message_id": 99}
    assert client.controls == []

    client.control_gate.set()
    await state.drain_background()
    assert [item[1]["action"] for item in client.controls] == ["tool_started", "tool_completed"]


@pytest.mark.asyncio
async def test_tool_progress_fence_covers_duplicate_waiters_until_result():
    client = GatedToolClient()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(
            call_ref="call-tool-fence", runtime_session_id="runtime-tool-fence"
        ),
    )

    first = asyncio.create_task(
        state.execute_tool("faq_lookup", {"query": "тариф"}, "tool-fence", timeout_ms=5_000)
    )
    await asyncio.wait_for(client.tool_called.wait(), timeout=0.1)
    duplicate = asyncio.create_task(
        state.execute_tool("faq_lookup", {"query": "тариф"}, "tool-fence", timeout_ms=5_000)
    )

    assert state.tool_in_progress is True
    client.tool_gate.set()
    first_result, duplicate_result = await asyncio.gather(first, duplicate)

    assert first_result == duplicate_result == {"message_id": 99}
    assert state.tool_in_progress is False
    assert len(client.tools) == 1


@pytest.mark.asyncio
async def test_recording_callback_precedes_finalize(state):
    recording = {
        "storage_key": "voice-recordings/7/call-1/recording.wav",
        "sha256": "a" * 64,
        "size_bytes": 100,
        "duration_sec": 1,
        "recorded_by": "pipecat",
        "layout": "dual_channel",
        "mode": "ai_voice",
    }

    assert await state.finalize(status="failed", reason="provider_error", recording=recording)

    assert len(state.client.recordings) == 1
    assert state.client.finalizations[0][1]["payload"]["recording_ref"] == recording["storage_key"]


@pytest.mark.asyncio
async def test_durable_finalize_retry_reuses_the_first_terminal_payload(tmp_path):
    fake_client = FailFinalizeOnceClient()
    outbox = CallbackOutbox(tmp_path / "outbox")
    state = SessionState(
        client=cast(OnelinkClient, fake_client),
        correlation=Correlation(call_ref="call-retry", runtime_session_id="runtime-retry"),
        callback_outbox=outbox,
    )

    with pytest.raises(OnelinkApiError):
        await state.finalize(status="completed", reason="runtime_closed")
    first_payload = fake_client.finalizations[0][1]["payload"]

    assert await state.finalize(status="failed", reason="retry_should_not_replace_terminal_state")
    assert fake_client.finalizations[1][1]["payload"] == first_payload
    assert fake_client.finalizations[1][1]["payload"]["status"] == "completed"
    assert list((tmp_path / "outbox").glob("*.json")) == []
