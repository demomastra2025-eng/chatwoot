import asyncio
import time

import pytest
from fastapi.testclient import TestClient

from app.api.models import JanusAttachRequest
from app.api.routes import _reservation_payload, _runner_payload
from app.config import Settings
from app.main import create_app


def settings(token: str = "voice-secret", max_sessions: int = 4) -> Settings:
    return Settings(
        internal_token=token,
        callback_base_url="http://rails.internal",
        max_concurrent_sessions=max_sessions,
    )


def auth(token: str = "voice-secret") -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


async def holding_runner(_payload):
    await asyncio.Event().wait()


def test_runner_payload_restores_capabilities_without_exposing_them_in_reservation(
    fixture_json,
):
    payload = fixture_json("janus_attach.json")
    payload["runtime_stream"] = {
        "runtime_session_id": "runtime-secret-test",
        "stream_url": "ws://media.internal/runtime-stream",
        "stream_token": "stream-token-secret-1234567890",
    }
    payload["runtime_control"] = {
        "control_url": "http://voice.internal/runtime-control/capability",
        "token": "control-token-secret-1234567890",
    }
    parsed = JanusAttachRequest.model_validate(payload)
    reservation = _reservation_payload(parsed)
    runner = _runner_payload(parsed, reservation)

    assert reservation["runtime_stream"]["stream_token"].startswith("sha256:")
    assert reservation["runtime_control"]["token"].startswith("sha256:")
    assert "secret" not in reservation["runtime_stream"]["stream_token"]
    assert "secret" not in reservation["runtime_control"]["token"]
    assert runner["runtime_stream"]["stream_token"] == "stream-token-secret-1234567890"
    assert runner["runtime_control"]["token"] == "control-token-secret-1234567890"


@pytest.fixture
def client():
    with TestClient(create_app(settings=settings(), session_runner=holding_runner)) as value:
        yield value


def test_janus_attach_matches_legacy_202_body(client, fixture_json):
    response = client.post(
        "/internal/janus-sip/calls",
        headers=auth(),
        json=fixture_json("janus_attach.json"),
    )

    assert response.status_code == 202
    assert response.json() == {
        "status": "accepted",
        "mode": "accepted",
        "call_ref": "sipuni:janus-ai:call-1",
        "transport": "janus_sip",
    }


def test_janus_preflight_validates_provider_before_answer(fixture_json):
    observed = []

    async def successful_preflight(payload):
        observed.append(payload)

    app = create_app(settings=settings(), session_runner=holding_runner)
    app.state.session_preflight = successful_preflight
    payload = fixture_json("janus_attach.json")
    payload.pop("runtime_stream")
    payload.pop("runtime_control", None)
    with TestClient(app) as client:
        response = client.post(
            "/internal/janus-sip/preflight",
            headers=auth(),
            json=payload,
        )

    assert response.status_code == 200
    assert response.json() == {"status": "ready", "runtime_engine": "pipecat"}
    assert observed[0]["call_ref"] == "sipuni:janus-ai:call-1"


def test_janus_attach_rejects_failed_provider_preflight_before_202(fixture_json):
    async def failing_preflight(_payload):
        raise RuntimeError("synthetic provider failure")

    app = create_app(settings=settings(), session_runner=holding_runner)
    app.state.session_preflight = failing_preflight
    with TestClient(app) as client:
        response = client.post(
            "/internal/janus-sip/calls",
            headers=auth(),
            json=fixture_json("janus_attach.json"),
        )

    assert response.status_code == 503
    assert response.json() == {"error": "provider_preflight_failed"}
    assert app.state.session_manager.active_count == 0


def test_duplicate_attach_requires_its_own_successful_preflight(fixture_json):
    attempts = 0

    async def changing_preflight(_payload):
        nonlocal attempts
        attempts += 1
        if attempts == 2:
            raise RuntimeError("synthetic duplicate preflight failure")
        return {"account_id": 42}

    app = create_app(settings=settings(), session_runner=holding_runner)
    app.state.session_preflight = changing_preflight
    payload = fixture_json("janus_attach.json")
    with TestClient(app) as client:
        first = client.post("/internal/janus-sip/calls", headers=auth(), json=payload)
        duplicate = client.post("/internal/janus-sip/calls", headers=auth(), json=payload)

        assert first.status_code == 202
        assert duplicate.status_code == 503
        assert duplicate.json() == {"error": "provider_preflight_failed"}
        assert app.state.session_manager.active_count == 1

    assert attempts == 2


def test_whatsapp_attach_matches_legacy_202_body(client, fixture_json):
    response = client.post(
        "/internal/whatsapp-cloud/calls",
        headers=auth(),
        json=fixture_json("whatsapp_attach.json"),
    )

    assert response.status_code == 202
    assert response.json() == {
        "status": "accepted",
        "mode": "accepted",
        "call_ref": "whatsapp:wa-call-1",
    }


def test_whatsapp_preflight_validates_provider_without_reserving(fixture_json):
    observed = []

    async def successful_preflight(payload):
        observed.append(payload)

    app = create_app(settings=settings(), session_runner=holding_runner)
    app.state.session_preflight = successful_preflight
    with TestClient(app) as client:
        response = client.post(
            "/internal/whatsapp-cloud/preflight",
            headers=auth(),
            json=fixture_json("whatsapp_attach.json"),
        )

    assert response.status_code == 200
    assert response.json() == {"status": "ready", "runtime_engine": "pipecat"}
    assert observed[0]["call_ref"] == "whatsapp:wa-call-1"
    assert observed[0]["runtime_stream"]["stream_token"] == "fake-token"
    assert app.state.session_manager.active_count == 0


def test_whatsapp_preflight_fails_closed_before_attach(fixture_json):
    async def failing_preflight(_payload):
        raise RuntimeError("synthetic provider failure")

    app = create_app(settings=settings(), session_runner=holding_runner)
    app.state.session_preflight = failing_preflight
    with TestClient(app) as client:
        response = client.post(
            "/internal/whatsapp-cloud/preflight",
            headers=auth(),
            json=fixture_json("whatsapp_attach.json"),
        )

    assert response.status_code == 503
    assert response.json() == {"error": "provider_preflight_failed"}
    assert app.state.session_manager.active_count == 0


def test_response_does_not_wait_for_worker_completion(client, fixture_json):
    response = client.post(
        "/internal/whatsapp-cloud/calls",
        headers=auth(),
        json=fixture_json("whatsapp_attach.json"),
    )

    assert response.status_code == 202


@pytest.mark.parametrize("path", ["/internal/janus-sip/calls", "/internal/whatsapp-cloud/calls"])
def test_wrong_bearer_token_fails_closed(path, client, fixture_json):
    fixture = "janus_attach.json" if "janus" in path else "whatsapp_attach.json"

    response = client.post(path, headers=auth("wrong"), json=fixture_json(fixture))

    assert response.status_code == 401
    assert response.json() == {"error": "unauthorized"}


def test_blank_internal_token_disables_attach(fixture_json):
    app = create_app(settings=settings(token=""), session_runner=holding_runner)
    with TestClient(app) as client:
        response = client.post(
            "/internal/janus-sip/calls",
            headers=auth(),
            json=fixture_json("janus_attach.json"),
        )

    assert response.status_code == 503
    assert response.json() == {"error": "internal_token_required"}


def test_missing_call_ref_matches_legacy_error(client, fixture_json):
    payload = fixture_json("janus_attach.json")
    payload.pop("call_ref")

    response = client.post("/internal/janus-sip/calls", headers=auth(), json=payload)

    assert response.status_code == 422
    assert response.json() == {"error": "call_ref_required"}


def test_human_operator_never_reaches_pipecat(client, fixture_json):
    payload = fixture_json("janus_attach.json")
    payload["sip_profile"] = {
        "id": "13",
        "profile_kind": "human_operator",
        "voice_agent": False,
    }

    response = client.post("/internal/janus-sip/calls", headers=auth(), json=payload)

    assert response.status_code == 422
    assert response.json() == {"error": "voice_agent_sip_profile_required"}


def test_non_ai_janus_route_never_reaches_pipecat(client, fixture_json):
    payload = fixture_json("janus_attach.json")
    payload["routing"] = {"action": "operator", "reason": "operator_route"}

    response = client.post("/internal/janus-sip/calls", headers=auth(), json=payload)

    assert response.status_code == 422
    assert response.json() == {"error": "ai_route_required"}


def test_non_ai_whatsapp_route_never_reaches_pipecat(client, fixture_json):
    payload = fixture_json("whatsapp_attach.json")
    payload["routing"] = {"action": "reject", "reason": "policy"}

    response = client.post("/internal/whatsapp-cloud/calls", headers=auth(), json=payload)

    assert response.status_code == 422
    assert response.json() == {"error": "ai_route_required"}


def test_identical_duplicate_is_idempotently_accepted(client, fixture_json):
    payload = fixture_json("janus_attach.json")

    first = client.post("/internal/janus-sip/calls", headers=auth(), json=payload)
    duplicate = client.post("/internal/janus-sip/calls", headers=auth(), json=payload)

    assert first.status_code == 202
    assert duplicate.status_code == 202
    assert duplicate.json() == first.json()


@pytest.mark.parametrize("secret_field", ["stream_token", "runtime_control_token"])
def test_duplicate_with_changed_capability_secret_returns_409(secret_field, client, fixture_json):
    payload = fixture_json("janus_attach.json")
    payload["runtime_stream"] = {
        "runtime_session_id": "runtime-secret-conflict",
        "stream_url": "ws://media.internal/runtime-stream",
        "stream_token": "stream-token-first-1234567890",
    }
    payload["runtime_control"] = {
        "control_url": "http://voice.internal/runtime-control/capability",
        "token": "control-token-first-1234567890",
    }
    assert client.post("/internal/janus-sip/calls", headers=auth(), json=payload).status_code == 202

    if secret_field == "stream_token":
        payload["runtime_stream"]["stream_token"] = "stream-token-second-1234567890"
    else:
        payload["runtime_control"]["token"] = "control-token-second-1234567890"

    conflict = client.post("/internal/janus-sip/calls", headers=auth(), json=payload)

    assert conflict.status_code == 409
    assert conflict.json() == {"error": "call_ref_conflict"}


def test_conflicting_duplicate_returns_409(client, fixture_json):
    payload = fixture_json("janus_attach.json")
    assert client.post("/internal/janus-sip/calls", headers=auth(), json=payload).status_code == 202
    payload["janus"]["session_id"] = "different-session"

    response = client.post("/internal/janus-sip/calls", headers=auth(), json=payload)

    assert response.status_code == 409
    assert response.json() == {"error": "call_ref_conflict"}


def test_capacity_exhaustion_returns_503_before_worker_start(fixture_json):
    app = create_app(settings=settings(max_sessions=1), session_runner=holding_runner)
    with TestClient(app) as client:
        first = fixture_json("janus_attach.json")
        second = fixture_json("whatsapp_attach.json")
        first_response = client.post("/internal/janus-sip/calls", headers=auth(), json=first)
        assert first_response.status_code == 202

        response = client.post("/internal/whatsapp-cloud/calls", headers=auth(), json=second)

    assert response.status_code == 503
    assert response.json() == {"error": "capacity_exhausted"}


def test_attach_is_unavailable_without_session_runner(fixture_json):
    app = create_app(settings=settings(), session_runner=None)
    with TestClient(app) as client:
        response = client.post(
            "/internal/janus-sip/calls",
            headers=auth(),
            json=fixture_json("janus_attach.json"),
        )

    assert response.status_code == 503
    assert response.json() == {"error": "voice_app_unavailable"}


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("codec", "opus"),
        ("input_sample_rate", 8_000),
        ("output_sample_rate", 24_000),
        ("stream_url", "https://media.invalid/runtime-stream"),
        ("stream_url", "wss://media.invalid/runtime-stream?token=query-token"),
        ("stream_token", ""),
    ],
)
def test_unsupported_runtime_stream_contract_is_rejected(
    client,
    fixture_json,
    field,
    value,
):
    payload = fixture_json("whatsapp_attach.json")
    payload["runtime_stream"][field] = value

    response = client.post("/internal/whatsapp-cloud/calls", headers=auth(), json=payload)

    assert response.status_code == 422
    assert response.json() == {"error": "invalid_request"}


def test_failed_background_runner_releases_capacity(fixture_json):
    async def failing_runner(_payload):
        raise RuntimeError("synthetic failure")

    app = create_app(settings=settings(max_sessions=1), session_runner=failing_runner)
    with TestClient(app) as client:
        first = client.post(
            "/internal/janus-sip/calls",
            headers=auth(),
            json=fixture_json("janus_attach.json"),
        )
        deadline = time.monotonic() + 1
        while app.state.session_manager.active_count and time.monotonic() < deadline:
            time.sleep(0.01)
        second = client.post(
            "/internal/whatsapp-cloud/calls",
            headers=auth(),
            json=fixture_json("whatsapp_attach.json"),
        )

    assert first.status_code == 202
    assert second.status_code == 202
