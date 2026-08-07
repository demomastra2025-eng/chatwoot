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
        self.callback_order = []

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
        self.callback_order.append("finalize")
        self.finalizations.append((correlation, kwargs))
        await asyncio.sleep(0)
        return {"status": "ok"}

    async def call_tool(self, correlation, name, arguments, **kwargs) -> dict[str, Any]:
        self.tools.append((correlation, name, arguments, kwargs))
        await asyncio.sleep(0)
        return {"message_id": 99}

    async def recording_stored(self, correlation, **kwargs):
        self.callback_order.append("recording")
        self.recordings.append((correlation, kwargs))
        return {"status": "ok"}


class FailFinalizeOnceClient(FakeClient):
    async def finalize_call(self, correlation, **kwargs):
        self.callback_order.append("finalize")
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


class SlowTranscriptClient(FakeClient):
    def __init__(self):
        super().__init__()
        self.transcript_called = asyncio.Event()
        self.transcript_gate = asyncio.Event()

    async def send_transcript(self, correlation, **kwargs):
        self.transcript_called.set()
        await self.transcript_gate.wait()
        return await super().send_transcript(correlation, **kwargs)


class FailingControlClient(FakeClient):
    async def send_control(self, correlation, **kwargs):
        self.controls.append((correlation, kwargs))
        raise OnelinkApiError("response lost", code="transport_error")


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


class DefinitiveFailingToolClient(FakeClient):
    async def call_tool(self, correlation, name, arguments, **kwargs):
        self.tools.append((correlation, name, arguments, kwargs))
        raise OnelinkApiError(
            "invalid tool arguments",
            status=422,
            code="invalid_arguments",
        )


class BusinessFailingToolClient(FakeClient):
    async def call_tool(self, correlation, name, arguments, **kwargs):
        self.tools.append((correlation, name, arguments, kwargs))
        return {
            "action": "captain_tool",
            "status": "failed",
            "error": "captain_tool_business_failed",
            "code": "CAPTAIN_TOOL_BUSINESS_FAILED",
            "retryable": False,
        }


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
async def test_control_fallback_reuses_the_control_idempotency_key():
    client = FailingControlClient()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(call_ref="call-control", runtime_session_id="runtime-control"),
    )

    assert (
        await state.safe_control(
            "tool_completed",
            {"result": "ok"},
            tool_call_id="tool-1",
            tool_name="faq_lookup",
        )
        is False
    )

    control_metadata = client.controls[0][1]
    fallback_event = client.events[0][1]
    assert control_metadata["event_key"] == fallback_event["event_id"]
    assert fallback_event["payload"]["tool_call_id"] == "tool-1"


@pytest.mark.asyncio
async def test_speaking_callbacks_coalesce_to_the_latest_state_while_rails_is_slow():
    client = SlowControlClient()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(call_ref="call-speaking", runtime_session_id="runtime-speaking"),
    )

    state.publish_ai_speaking("started")
    await asyncio.sleep(0)
    state.publish_ai_speaking("stopped")
    state.publish_ai_speaking("started")
    client.control_gate.set()
    assert state._ai_speaking_task is not None
    await state._ai_speaking_task

    assert [item[1]["metadata"]["state"] for item in client.controls] == ["started"]
    assert client.events == []

    state.publish_ai_speaking("stopped")
    assert state._ai_speaking_task is not None
    await state._ai_speaking_task
    assert [item[1]["metadata"]["state"] for item in client.controls] == [
        "started",
        "stopped",
    ]


@pytest.mark.asyncio
async def test_pending_speaking_observability_does_not_delay_finalize():
    client = SlowControlClient()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(
            call_ref="call-speaking-finalize",
            runtime_session_id="runtime-speaking-finalize",
        ),
    )

    state.publish_ai_speaking("started")
    await asyncio.sleep(0)

    assert await asyncio.wait_for(
        state.finalize(status="completed", reason="caller_hangup"),
        timeout=0.1,
    )
    assert state.finalized is True
    assert client.controls == []


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
async def test_slow_transcript_http_does_not_block_realtime_transcript_updates():
    client = SlowTranscriptClient()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(
            call_ref="call-slow-transcript",
            runtime_session_id="runtime-slow-transcript",
        ),
    )
    await state.add_transcript("caller", "Первый вопрос", final=True)
    flush_task = asyncio.create_task(state.flush_transcript())
    await client.transcript_called.wait()

    await asyncio.wait_for(
        state.add_transcript("ai", "Быстрый ответ", final=True),
        timeout=0.1,
    )

    client.transcript_gate.set()
    assert await flush_task is True
    assert await state.flush_transcript() is True
    assert [[item["text"] for item in batch[1]["items"]] for batch in client.transcripts] == [
        ["Первый вопрос"],
        ["Быстрый ответ"],
    ]


@pytest.mark.asyncio
async def test_cancelled_transcript_flush_restores_claimed_items(state):
    client = SlowTranscriptClient()
    state.client = cast(OnelinkClient, client)
    await state.add_transcript("ai", "Не потерять", final=True)
    flush_task = asyncio.create_task(state.flush_transcript())
    await client.transcript_called.wait()

    flush_task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await flush_task

    client.transcript_gate.set()
    assert await state.flush_transcript() is True
    assert [item["text"] for item in client.transcripts[0][1]["items"]] == ["Не потерять"]


@pytest.mark.asyncio
async def test_direct_and_aggregated_assistant_transcript_are_deduplicated(state):
    await state.add_transcript(
        "ai",
        "Акуна матата",
        final=True,
        deduplicate_recent=True,
    )
    await state.add_transcript(
        "ai",
        "Акуна матата",
        final=True,
        deduplicate_recent=True,
    )

    await state.flush_transcript()

    items = state.client.transcripts[0][1]["items"]
    assert [(item["speaker"], item["text"]) for item in items] == [("ai", "Акуна матата")]


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
async def test_identical_read_only_tool_is_coalesced_while_first_call_is_in_flight():
    client = GatedToolClient()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(
            call_ref="call-read-only-coalesce",
            runtime_session_id="runtime-read-only-coalesce",
        ),
    )
    arguments = {"contact_id": "2179", "limit": 10}

    first_task = asyncio.create_task(
        state.execute_tool("search_deals", arguments, "search-1", timeout_ms=15_000)
    )
    await client.tool_called.wait()
    state.touch_user()
    duplicate_task = asyncio.create_task(
        state.execute_tool("search_deals", arguments, "search-2", timeout_ms=15_000)
    )
    await asyncio.sleep(0)

    assert len(client.tools) == 0
    client.tool_gate.set()
    first, duplicate = await asyncio.gather(first_task, duplicate_task)
    await state.drain_background()

    assert first == duplicate == {"message_id": 99}
    assert len(client.tools) == 1
    suppressed = [item[1] for item in client.controls if item[1]["action"] == "tool_suppressed"]
    assert len(suppressed) == 1
    assert suppressed[0]["metadata"]["dedupe_scope"] == "in_flight"

    await state.execute_tool("search_deals", arguments, "search-3", timeout_ms=15_000)
    assert len(client.tools) == 2


@pytest.mark.asyncio
async def test_different_read_only_arguments_are_not_coalesced():
    client = GatedToolClient()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(
            call_ref="call-read-only-distinct",
            runtime_session_id="runtime-read-only-distinct",
        ),
    )

    first_task = asyncio.create_task(
        state.execute_tool("search_deals", {"contact_id": "2179"}, "search-a", timeout_ms=15_000)
    )
    await client.tool_called.wait()
    second_task = asyncio.create_task(
        state.execute_tool("search_deals", {"contact_id": "2180"}, "search-b", timeout_ms=15_000)
    )
    await asyncio.sleep(0)
    client.tool_gate.set()
    await asyncio.gather(first_task, second_task)

    assert len(client.tools) == 2


@pytest.mark.asyncio
async def test_create_deal_is_semantically_fenced_per_caller_turn(state):
    arguments = {"title": "Новая сделка", "pipeline_id": 2, "stage_id": 3}
    first = await state.execute_tool(
        "create_deal",
        arguments,
        "tool-deal-1",
        timeout_ms=800,
    )
    duplicate = await state.execute_tool(
        "create_deal",
        arguments,
        "tool-deal-2",
        timeout_ms=800,
    )
    independent = await state.execute_tool(
        "create_deal",
        {"title": "Другая сделка"},
        "tool-deal-independent",
        timeout_ms=800,
    )

    assert first == {"message_id": 99}
    assert duplicate == {"message_id": 99, "_runtime_suppressed": True}
    assert independent == {"message_id": 99}
    assert len(state.client.tools) == 2

    state.touch_user()
    next_turn = await state.execute_tool(
        "create_deal",
        {"title": "Другая сделка"},
        "tool-deal-3",
        timeout_ms=800,
    )
    await state.drain_background()

    assert next_turn == {"message_id": 99}
    assert len(state.client.tools) == 3
    duplicate_controls = [
        item[1] for item in state.client.controls if item[1]["action"] == "tool_suppressed"
    ]
    assert len(duplicate_controls) == 1
    assert duplicate_controls[0]["metadata"]["dedupe_scope"] == "caller_turn"


@pytest.mark.asyncio
async def test_failed_create_deal_can_retry_in_same_caller_turn():
    client = DefinitiveFailingToolClient()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(
            call_ref="call-deal-retry",
            runtime_session_id="runtime-deal-retry",
        ),
    )

    first = await state.execute_tool(
        "create_deal",
        {"title": "Сделка"},
        "tool-deal-failed-1",
        timeout_ms=800,
    )
    retry = await state.execute_tool(
        "create_deal",
        {"title": "Сделка", "pipeline_id": 2},
        "tool-deal-failed-2",
        timeout_ms=800,
    )

    assert first["error"] == retry["error"] == "tool_execution_failed"
    assert len(client.tools) == 2


@pytest.mark.asyncio
async def test_non_retryable_business_failure_is_fenced_until_the_next_caller_turn():
    client = BusinessFailingToolClient()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(
            call_ref="call-deal-business-failure",
            runtime_session_id="runtime-deal-business-failure",
        ),
    )

    first = await state.execute_tool(
        "update_deal",
        {"deal_id": 42, "title": "Новый проект"},
        "tool-deal-business-1",
        timeout_ms=800,
    )
    duplicate = await state.execute_tool(
        "update_deal",
        {"deal_id": 42, "title": "Новый проект"},
        "tool-deal-business-2",
        timeout_ms=800,
    )

    assert duplicate == {**first, "_runtime_suppressed": True}
    assert first["retryable"] is False
    assert len(client.tools) == 1

    state.touch_user()
    await state.execute_tool(
        "update_deal",
        {"deal_id": 42, "title": "Уточнённый проект"},
        "tool-deal-business-3",
        timeout_ms=800,
    )
    assert len(client.tools) == 2


@pytest.mark.asyncio
async def test_update_deal_allows_distinct_changes_in_the_same_caller_turn(state):
    first = await state.execute_tool(
        "update_deal",
        {"deal_id": 42, "title": "Новый проект"},
        "tool-update-title",
        timeout_ms=800,
    )
    second = await state.execute_tool(
        "update_deal",
        {"deal_id": 42, "stage_id": 7},
        "tool-update-stage",
        timeout_ms=800,
    )

    assert first == {"message_id": 99}
    assert second == {"message_id": 99}
    assert len(state.client.tools) == 2


@pytest.mark.asyncio
async def test_unknown_create_deal_outcome_is_fenced_for_the_whole_call():
    client = FailingToolClient()
    state = SessionState(
        client=cast(OnelinkClient, client),
        correlation=Correlation(
            call_ref="call-deal-unknown",
            runtime_session_id="runtime-deal-unknown",
        ),
    )

    first = await state.execute_tool(
        "create_deal",
        {"title": "Сделка"},
        "tool-deal-unknown-1",
        timeout_ms=800,
    )
    state.touch_user()
    suppressed = await state.execute_tool(
        "create_deal",
        {"title": "Сделка"},
        "tool-deal-unknown-2",
        timeout_ms=800,
    )
    await state.drain_background()

    assert suppressed == {**first, "_runtime_suppressed": True}
    assert first == {
        "error": "tool_execution_outcome_unknown",
        "code": "transport_error",
        "status": "outcome_unknown",
        "retryable": False,
    }
    assert len(client.tools) == 1
    suppressed_controls = [
        item[1] for item in client.controls if item[1]["action"] == "tool_suppressed"
    ]
    assert len(suppressed_controls) == 1
    assert suppressed_controls[0]["metadata"]["dedupe_scope"] == "call"


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
async def test_finalize_callback_precedes_recording_callback(state):
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

    assert state.client.callback_order == ["finalize", "recording"]
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

    assert await state.finalize(status="completed", reason="runtime_closed")
    first_payload = fake_client.finalizations[0][1]["payload"]

    assert (
        await state.finalize(status="failed", reason="retry_should_not_replace_terminal_state")
        is False
    )
    assert len(list((tmp_path / "outbox").glob("*.json"))) == 1

    assert await outbox.replay(fake_client) == 1
    assert fake_client.finalizations[1][1]["payload"] == first_payload
    assert fake_client.finalizations[1][1]["payload"]["status"] == "completed"
    assert list((tmp_path / "outbox").glob("*.json")) == []
