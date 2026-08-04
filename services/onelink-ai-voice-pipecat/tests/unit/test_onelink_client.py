import json

import httpx
import pytest

from app.clients.onelink import Correlation, OnelinkApiError, OnelinkClient, redact


@pytest.fixture
def correlation():
    return Correlation(
        call_ref="call-1",
        runtime_session_id="runtime-1",
        account_id=7,
        conversation_id=11,
        call_session_id=13,
        assistant_id=17,
        tool_capability="signed-per-call-capability",
    )


def make_client(handler, *, retries=2):
    return OnelinkClient(
        base_url="http://rails.internal",
        token="callback-secret",
        timeout_seconds=0.1,
        max_retries=retries,
        transport=httpx.MockTransport(handler),
    )


@pytest.mark.asyncio
async def test_context_uses_bearer_and_retries_transient_status():
    requests = []

    def handler(request):
        requests.append(request)
        if len(requests) == 1:
            return httpx.Response(503, json={"error": "busy"})
        return httpx.Response(200, json={"call_ref": "call-1", "account_id": 7, "ai": {}})

    async with make_client(handler) as client:
        result = await client.get_context({"call_ref": "call-1", "account_id": 7})

    assert result["call_ref"] == "call-1"
    assert len(requests) == 2
    assert requests[0].headers["authorization"] == "Bearer callback-secret"
    assert requests[0].headers["x-onelink-voice-capabilities"] == "callback_handoff_v1"


@pytest.mark.asyncio
async def test_event_is_scoped_and_sets_idempotency_headers(correlation):
    captured = []

    def handler(request):
        captured.append(request)
        if len(captured) == 1:
            return httpx.Response(503, json={"error": "busy"})
        return httpx.Response(200, json={"status": "ok"})

    async with make_client(handler) as client:
        await client.send_event(
            correlation,
            event_type="media_stream_opened",
            payload={"stream_ref": "stream-1"},
            event_id="event-1",
            sequence=3,
        )

    request = captured[-1]
    body = json.loads(request.content)
    assert [item.headers["x-event-attempt"] for item in captured] == ["1", "2"]
    assert request.headers["x-event-id"] == "event-1"
    assert request.headers["x-idempotency-key"] == "event-1"
    assert body == {
        "call_ref": "call-1",
        "runtime_session_id": "runtime-1",
        "runtime_engine": "pipecat",
        "account_id": 7,
        "conversation_id": 11,
        "call_session_id": 13,
        "assistant_id": 17,
        "event_id": "event-1",
        "event_key": "event-1",
        "event_seq": 3,
        "event_type": "media_stream_opened",
        "payload": {"stream_ref": "stream-1"},
    }


@pytest.mark.asyncio
async def test_control_retry_reuses_the_same_idempotency_key(correlation):
    captured = []

    def handler(request):
        captured.append(request)
        if len(captured) == 1:
            return httpx.Response(503, json={"error": "busy"})
        return httpx.Response(200, json={"status": "ok"})

    async with make_client(handler) as client:
        await client.send_control(
            correlation,
            action="ai_speaking",
            event_key="control-event-1",
            metadata={"state": "started"},
        )

    assert len(captured) == 2
    assert {item.headers["x-idempotency-key"] for item in captured} == {"control-event-1"}
    assert json.loads(captured[-1].content)["event_key"] == "control-event-1"


@pytest.mark.asyncio
async def test_mutating_tool_is_not_retried(correlation):
    attempts = 0
    bodies = []

    def handler(request):
        nonlocal attempts
        attempts += 1
        bodies.append(json.loads(request.content))
        return httpx.Response(503, json={"error": "busy"})

    async with make_client(handler, retries=4) as client:
        with pytest.raises(OnelinkApiError):
            await client.call_tool(
                correlation,
                "create_note",
                {"content": "private"},
                tool_call_id="tool-1",
                timeout_seconds=0.1,
            )

    assert attempts == 1
    assert bodies[0]["tool_capability"] == "signed-per-call-capability"
    assert bodies[0]["assistant_id"] == 17
    assert "tool_capability" not in correlation.payload()


@pytest.mark.asyncio
async def test_heartbeat_uses_the_dedicated_lease_endpoint(correlation):
    captured = []

    def handler(request):
        captured.append(request)
        return httpx.Response(200, json={"status": "ok", "terminal": False})

    async with make_client(handler) as client:
        result = await client.send_heartbeat(correlation)

    assert result == {"status": "ok", "terminal": False}
    assert captured[0].url.path == "/internal/voice/ai/heartbeat"
    assert json.loads(captured[0].content) == correlation.payload()


@pytest.mark.asyncio
async def test_default_client_timeout_is_not_disabled_by_normal_callbacks(correlation):
    captured = []

    def handler(request):
        captured.append(request)
        return httpx.Response(200, json={"status": "ok"})

    async with make_client(handler) as client:
        await client.send_heartbeat(correlation)
        await client.call_tool(
            correlation,
            "faq_lookup",
            {"query": "слоган"},
            tool_call_id="tool-timeout",
            timeout_seconds=0.025,
        )

    assert set(captured[0].extensions["timeout"].values()) == {0.1}
    assert set(captured[1].extensions["timeout"].values()) == {0.025}


def test_redaction_removes_tokens_capability_queries_and_secret_fields():
    value = {
        "authorization": "Bearer secret-token",
        "stream_url": "wss://media.internal/runtime?token=secret&call=1",
        "recording_url": "https://storage.internal/file.wav?signature=secret",
        "nested": {"sip_password": "secret-password", "safe": "value"},
    }

    redacted = redact(value)

    assert redacted["authorization"] == "[redacted]"
    assert redacted["stream_url"] == "wss://media.internal/runtime"
    assert redacted["recording_url"] == "https://storage.internal/file.wav"
    assert redacted["nested"]["sip_password"] == "[redacted]"
    assert redacted["nested"]["safe"] == "value"
