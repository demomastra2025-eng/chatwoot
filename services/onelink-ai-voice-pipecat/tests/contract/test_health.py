from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


async def idle_runner(_payload):
    return None


def settings(**overrides):
    values = {
        "internal_token": "voice-secret",
        "callback_token": "callback-secret",
        "gemini_api_key": "gemini-secret",
        "callback_base_url": "http://rails.internal",
    }
    values.update(overrides)
    return Settings.model_validate(values)


def test_health_distinguishes_liveness_and_readiness():
    client = TestClient(
        create_app(settings=settings(internal_token=""), session_runner=idle_runner)
    )

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "ready": False,
        "active_sessions": 0,
        "runtime_engine": "pipecat",
        "realtime_provider": "gemini-live",
        "provider_readiness": {
            "gemini-live": True,
            "openai-live": False,
            "openai-realtime": False,
            "elevenlabs": False,
            "cartesia": False,
            "fish": False,
        },
        "supported_providers": [
            "gemini-live",
            "openai-live",
            "openai-realtime",
            "elevenlabs",
            "cartesia",
            "fish",
        ],
        "checks": ["internal_token_required"],
    }
    assert client.get("/ready").status_code == 503


def test_health_is_ready_only_with_valid_config_and_runner():
    client = TestClient(create_app(settings=settings(), session_runner=idle_runner))

    assert client.get("/health").json()["ready"] is True
    assert client.get("/ready").status_code == 200


def test_health_reports_unavailable_provider_without_failing_global_readiness():
    client = TestClient(
        create_app(
            settings=settings(realtime_provider="openai-live", openai_api_key=""),
            session_runner=idle_runner,
        )
    )

    health = client.get("/health").json()
    assert health["provider_readiness"]["openai-live"] is False
    assert health["ready"] is True
    assert client.get("/ready").status_code == 200


def test_health_is_unready_without_session_runner():
    client = TestClient(create_app(settings=settings(), session_runner=None))

    assert client.get("/health").json()["checks"] == ["session_runner_unavailable"]


def test_default_app_installs_real_session_runner():
    client = TestClient(create_app(settings=settings()))

    assert client.get("/health").json()["ready"] is True
