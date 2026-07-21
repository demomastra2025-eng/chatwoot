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
        "event_id": "event-1",
        "event_key": "event-1",
        "event_seq": 3,
        "event_type": "media_stream_opened",
        "payload": {"stream_ref": "stream-1"},
    }


@pytest.mark.asyncio
async def test_mutating_tool_is_not_retried(correlation):
    attempts = 0

    def handler(_request):
        nonlocal attempts
        attempts += 1
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
