import asyncio
import base64

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.config import Settings
from app.main import create_app
from app.pipeline.context import VoiceContext
from app.preview import PreviewReservationStore


def settings(**overrides) -> Settings:
    values = {
        "internal_token": "internal-secret",
        "callback_token": "callback-secret",
        "callback_base_url": "http://rails.internal",
        "gemini_api_key": "gemini-secret",
        "openai_api_key": "openai-secret",
        "elevenlabs_api_key": "elevenlabs-secret",
        "cartesia_api_key": "cartesia-secret",
        "openrouter_api_key": "openrouter-secret",
    }
    values.update(overrides)
    return Settings.model_validate(values)


def preview_context(provider: str = "cartesia") -> dict:
    return {
        "call_ref": "ignored",
        "account_id": 42,
        "ai": {
            "provider": provider,
            "model": "openai/gpt-5.4-mini",
            "voice": "71a7ad14-091c-4e8e-a314-022ece01c121",
            "language": "ru-KZ",
            "system_prompt": "Говори коротко.",
            "first_message": "Здравствуйте!",
            "max_duration_sec": 900,
        },
        "tools": [{"name": "create_note", "enabled": True}],
        "recording": {"enabled": True},
    }


def test_preview_reservation_requires_internal_auth():
    client = TestClient(create_app(settings=settings(), session_runner=None))

    response = client.post("/internal/voice-previews", json={"context": preview_context()})

    assert response.status_code == 401


def test_preview_websocket_rejects_cross_origin_clients():
    client = TestClient(create_app(settings=settings(), session_runner=None))

    with pytest.raises(WebSocketDisconnect) as error:
        with client.websocket_connect(
            "/voice-preview/ws",
            headers={"origin": "https://evil.example"},
        ) as websocket:
            websocket.receive_json()

    assert error.value.code == 4403


def test_preview_websocket_rejects_oversized_auth_before_parsing():
    client = TestClient(create_app(settings=settings(), session_runner=None))

    with pytest.raises(WebSocketDisconnect) as error:
        with client.websocket_connect(
            "/voice-preview/ws",
            headers={"origin": "http://testserver"},
        ) as websocket:
            websocket.send_text("x" * 4097)
            websocket.receive_json()

    assert error.value.code == 4401


def test_preview_reservation_is_single_use_and_strips_side_effects():
    app = create_app(settings=settings(), session_runner=None)
    client = TestClient(app)

    response = client.post(
        "/internal/voice-previews",
        headers={"Authorization": "Bearer internal-secret"},
        json={"context": preview_context()},
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["websocket_path"] == "/voice-preview/ws"
    assert "token" in payload

    stored = asyncio.run(app.state.preview_store.consume(payload["token"]))
    assert stored is not None
    assert stored.tools == []
    assert stored.recording.enabled is False
    assert stored.ai.max_duration_sec == 120


def test_preview_capability_authenticates_websocket_and_bridges_audio(monkeypatch):
    async def fake_run_preview(websocket, context, _settings):
        assert context.tools == []
        assert context.recording.enabled is False
        await websocket.send_json(
            {"type": "READY", "provider": context.ai.provider, "sample_rate": 8000}
        )
        audio_in = await websocket.receive_json()
        assert audio_in == {
            "type": "AUDIO_IN",
            "data": base64.b64encode(bytes(640)).decode("ascii"),
            "mime_type": "audio/pcm;rate=16000",
        }
        await websocket.send_json(
            {
                "type": "AUDIO_OUT",
                "data": base64.b64encode(bytes(320)).decode("ascii"),
                "mime_type": "audio/pcm;rate=8000",
            }
        )

    monkeypatch.setattr("app.preview._run_preview", fake_run_preview)
    client = TestClient(create_app(settings=settings(), session_runner=None))
    response = client.post(
        "/internal/voice-previews",
        headers={"Authorization": "Bearer internal-secret"},
        json={"context": preview_context()},
    )
    capability = response.json()

    with client.websocket_connect(
        capability["websocket_path"],
        headers={"origin": "http://testserver"},
    ) as websocket:
        websocket.send_json({"type": "AUTH", "token": capability["token"]})
        assert websocket.receive_json() == {
            "type": "READY",
            "provider": "cartesia",
            "sample_rate": 8000,
        }
        websocket.send_json(
            {
                "type": "AUDIO_IN",
                "data": base64.b64encode(bytes(640)).decode("ascii"),
                "mime_type": "audio/pcm;rate=16000",
            }
        )
        assert websocket.receive_json() == {
            "type": "AUDIO_OUT",
            "data": base64.b64encode(bytes(320)).decode("ascii"),
            "mime_type": "audio/pcm;rate=8000",
        }


def test_preview_reservation_rejects_provider_without_credentials():
    client = TestClient(
        create_app(
            settings=settings(cartesia_api_key=""),
            session_runner=None,
        )
    )

    response = client.post(
        "/internal/voice-previews",
        headers={"Authorization": "Bearer internal-secret"},
        json={"context": preview_context()},
    )

    assert response.status_code == 503
    assert response.json()["error"] == "preview_provider_unavailable"


@pytest.mark.asyncio
async def test_preview_store_consumes_token_once_and_never_stores_raw_token():
    store = PreviewReservationStore(max_pending=2)
    context = VoiceContext.model_validate(preview_context())

    token = await store.reserve(context)

    assert token not in store._items
    assert await store.consume(token) is context
    assert await store.consume(token) is None


@pytest.mark.asyncio
async def test_preview_store_rejects_unbounded_pending_reservations():
    store = PreviewReservationStore(max_pending=1)
    context = VoiceContext.model_validate(preview_context())

    assert await store.reserve(context) is not None
    assert await store.reserve(context) is None
