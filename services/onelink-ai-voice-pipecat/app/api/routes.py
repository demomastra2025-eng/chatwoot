"""Legacy-compatible Janus and WhatsApp attach endpoints."""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
from collections.abc import Awaitable, Callable
from typing import TypeVar

from fastapi import APIRouter, Header, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ValidationError

from app.api.auth import auth_error
from app.api.models import JanusAttachRequest, JanusPreflightRequest, WhatsappAttachRequest
from app.sessions.manager import ReservationKind, SessionRecord

MAX_BODY_BYTES = 1024 * 1024
AI_ACTIONS = frozenset({"ai", "ai_accept"})
PayloadModel = TypeVar("PayloadModel", bound=BaseModel)
SessionRunner = Callable[[dict], Awaitable[None]]
logger = logging.getLogger(__name__)

router = APIRouter()


@router.post("/internal/janus-sip/preflight")
async def preflight_janus(
    request: Request,
    authorization: str | None = Header(default=None),
) -> JSONResponse:
    if error := auth_error(request.app.state.settings, authorization):
        return error
    parsed = await _parse_payload(request, JanusPreflightRequest)
    if isinstance(parsed, JSONResponse):
        return parsed
    if not parsed.call_ref:
        return _error(422, "call_ref_required")
    if parsed.routing.action not in AI_ACTIONS:
        return _error(422, "ai_route_required")
    if parsed.sip_profile.profile_kind != "voice_agent" or not parsed.sip_profile.voice_agent:
        return _error(422, "voice_agent_sip_profile_required")

    preflight = request.app.state.session_preflight
    if preflight is None:
        return _error(503, "provider_preflight_unavailable")
    try:
        await preflight(parsed.model_dump(mode="json", exclude_none=True))
    except Exception as error:
        logger.warning(
            "Pipecat preflight failed call_ref=%s error_class=%s",
            parsed.call_ref,
            type(error).__name__,
        )
        return _error(503, "provider_preflight_failed")
    return JSONResponse(
        status_code=200,
        content={"status": "ready", "runtime_engine": "pipecat"},
    )


@router.post("/internal/janus-sip/calls")
async def attach_janus(
    request: Request,
    authorization: str | None = Header(default=None),
) -> JSONResponse:
    if error := auth_error(request.app.state.settings, authorization):
        return error
    parsed = await _parse_payload(request, JanusAttachRequest)
    if isinstance(parsed, JSONResponse):
        return parsed
    if not parsed.call_ref:
        return _error(422, "call_ref_required")
    if parsed.routing.action not in AI_ACTIONS:
        return _error(422, "ai_route_required")
    if parsed.sip_profile.profile_kind != "voice_agent" or not parsed.sip_profile.voice_agent:
        return _error(422, "voice_agent_sip_profile_required")

    accepted = {
        "status": "accepted",
        "mode": "accepted",
        "call_ref": parsed.call_ref,
        "transport": parsed.transport,
    }
    return await _reserve_and_start(request, parsed, accepted)


@router.post("/internal/whatsapp-cloud/preflight")
async def preflight_whatsapp(
    request: Request,
    authorization: str | None = Header(default=None),
) -> JSONResponse:
    if error := auth_error(request.app.state.settings, authorization):
        return error
    parsed = await _parse_payload(request, WhatsappAttachRequest)
    if isinstance(parsed, JSONResponse):
        return parsed
    if not parsed.call_ref:
        return _error(422, "call_ref_required")
    if parsed.routing.action not in AI_ACTIONS:
        return _error(422, "ai_route_required")

    preflight = request.app.state.session_preflight
    if preflight is None:
        return _error(503, "provider_preflight_unavailable")
    try:
        await preflight(_runner_payload(parsed, _reservation_payload(parsed)))
    except Exception as error:
        logger.warning(
            "Pipecat WhatsApp preflight failed call_ref=%s error_class=%s",
            parsed.call_ref,
            type(error).__name__,
        )
        return _error(503, "provider_preflight_failed")
    return JSONResponse(
        status_code=200,
        content={"status": "ready", "runtime_engine": "pipecat"},
    )


@router.post("/internal/whatsapp-cloud/calls")
async def attach_whatsapp(
    request: Request,
    authorization: str | None = Header(default=None),
) -> JSONResponse:
    if error := auth_error(request.app.state.settings, authorization):
        return error
    parsed = await _parse_payload(request, WhatsappAttachRequest)
    if isinstance(parsed, JSONResponse):
        return parsed
    if not parsed.call_ref:
        return _error(422, "call_ref_required")
    if parsed.routing.action not in AI_ACTIONS:
        return _error(422, "ai_route_required")

    accepted = {
        "status": "accepted",
        "mode": "accepted",
        "call_ref": parsed.call_ref,
    }
    return await _reserve_and_start(request, parsed, accepted)


async def _parse_payload(
    request: Request,
    model: type[PayloadModel],
) -> PayloadModel | JSONResponse:
    body = await request.body()
    if len(body) > MAX_BODY_BYTES:
        return _error(413, "request_body_too_large")
    try:
        raw = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return _error(400, "invalid_json")
    if not isinstance(raw, dict):
        return _error(422, "invalid_request")
    try:
        return model.model_validate(raw)
    except ValidationError:
        return _error(422, "invalid_request")


async def _reserve_and_start(
    request: Request,
    payload: BaseModel,
    accepted: dict,
) -> JSONResponse:
    runner: SessionRunner | None = request.app.state.session_runner
    if runner is None:
        return _error(503, "voice_app_unavailable")

    reservation_data = _reservation_payload(payload)
    runner_data = _runner_payload(payload, reservation_data)
    call_ref = reservation_data["call_ref"]
    preflight = request.app.state.session_preflight
    if preflight is not None:
        try:
            runner_data["_preflight_context"] = await preflight(runner_data)
        except Exception as error:
            logger.warning(
                "Pipecat attach preflight failed call_ref=%s error_class=%s",
                call_ref,
                type(error).__name__,
            )
            return _error(503, "provider_preflight_failed")
    reservation = await request.app.state.session_manager.reserve(call_ref, reservation_data)
    if reservation.kind is ReservationKind.CONFLICT:
        return _error(409, "call_ref_conflict")
    if reservation.kind is ReservationKind.CAPACITY_EXHAUSTED:
        return _error(503, "capacity_exhausted")
    if reservation.kind is ReservationKind.CREATED:
        record = reservation.record
        assert record is not None
        task = asyncio.create_task(
            _run_session(request, record, runner_data), name=f"voice:{call_ref}"
        )
        await request.app.state.session_manager.bind_task(record, task)

    return JSONResponse(status_code=202, content=accepted)


def _runner_payload(payload: BaseModel, reservation_data: dict) -> dict:
    data = json.loads(json.dumps(reservation_data))
    runtime_stream = getattr(payload, "runtime_stream", None)
    if runtime_stream is not None and runtime_stream.stream_token is not None:
        data["runtime_stream"]["stream_token"] = runtime_stream.stream_token.get_secret_value()
    runtime_control = getattr(payload, "runtime_control", None)
    if runtime_control is not None:
        data["runtime_control"]["token"] = runtime_control.token.get_secret_value()
    return data


def _reservation_payload(payload: BaseModel) -> dict:
    data = payload.model_dump(mode="json", exclude_none=True)
    runtime_stream = getattr(payload, "runtime_stream", None)
    if runtime_stream is not None and runtime_stream.stream_token is not None:
        data["runtime_stream"]["stream_token"] = _secret_digest(
            runtime_stream.stream_token.get_secret_value()
        )
    runtime_control = getattr(payload, "runtime_control", None)
    if runtime_control is not None:
        data["runtime_control"]["token"] = _secret_digest(runtime_control.token.get_secret_value())
    return data


def _secret_digest(value: str) -> str:
    return f"sha256:{hashlib.sha256(value.encode('utf-8')).hexdigest()}"


async def _run_session(request: Request, record: SessionRecord, payload: dict) -> None:
    try:
        await request.app.state.session_runner(payload)
    except asyncio.CancelledError:
        raise
    except Exception as error:  # Callback reporting is added with the real session runner.
        logger.error(
            "Pipecat session failed call_ref=%s error_class=%s",
            record.call_ref,
            type(error).__name__,
        )
    finally:
        await request.app.state.session_manager.release(record.call_ref, record)


def _error(status_code: int, code: str) -> JSONResponse:
    return JSONResponse(status_code=status_code, content={"error": code})
