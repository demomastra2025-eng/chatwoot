"""Authenticated browser preview sessions for Captain AI Voice settings."""

from __future__ import annotations

import asyncio
import hashlib
import json
import secrets
import time
from collections.abc import Coroutine
from typing import Any, cast
from urllib.parse import urlparse

from fastapi import APIRouter, Header, Request, WebSocket
from fastapi.responses import JSONResponse
from pipecat.frames.frames import LLMRunFrame
from pipecat.pipeline.runner import PipelineRunner
from pipecat.transports.websocket.fastapi import (
    FastAPIWebsocketParams,
    FastAPIWebsocketTransport,
)
from pydantic import BaseModel

from app.api.auth import auth_error
from app.config import Settings
from app.media.serializer import OneLinkMediaSerializer
from app.pipeline.context import VoiceContext
from app.pipeline.factory import build_pipeline
from app.sessions.manager import ReservationKind, SessionManager
from app.sessions.state import SessionState

PREVIEW_TOKEN_TTL_SECONDS = 60
PREVIEW_SESSION_MAX_SECONDS = 120
PREVIEW_AUTH_MESSAGE_MAX_BYTES = 4096

router = APIRouter()


class PreviewReservationRequest(BaseModel):
    context: dict[str, Any]


class PreviewReservation(BaseModel):
    token: str
    expires_in: int = PREVIEW_TOKEN_TTL_SECONDS
    websocket_path: str = "/voice-preview/ws"


class PreviewReservationStore:
    """Process-local, single-use preview capabilities."""

    def __init__(self, max_pending: int) -> None:
        self._max_pending = max_pending
        self._items: dict[str, tuple[float, VoiceContext]] = {}
        self._lock = asyncio.Lock()

    async def reserve(self, context: VoiceContext) -> str | None:
        token = secrets.token_urlsafe(32)
        digest = self._digest(token)
        async with self._lock:
            self._purge_expired()
            if len(self._items) >= self._max_pending:
                return None
            self._items[digest] = (time.monotonic() + PREVIEW_TOKEN_TTL_SECONDS, context)
        return token

    async def consume(self, token: str) -> VoiceContext | None:
        digest = self._digest(token)
        async with self._lock:
            self._purge_expired()
            item = self._items.pop(digest, None)
        return item[1] if item else None

    def _purge_expired(self) -> None:
        now = time.monotonic()
        expired = [digest for digest, (deadline, _) in self._items.items() if deadline <= now]
        for digest in expired:
            self._items.pop(digest, None)

    @staticmethod
    def _digest(token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()


class PreviewSessionState:
    """No-op lifecycle state: preview never calls Rails tools/control/transcript APIs."""

    def __init__(self) -> None:
        self.last_activity_monotonic = time.monotonic()
        self.user_turn = 0
        self._tasks: set[asyncio.Task[Any]] = set()

    @property
    def tool_in_progress(self) -> bool:
        return False

    def touch(self) -> None:
        self.last_activity_monotonic = time.monotonic()

    def touch_user(self) -> None:
        self.user_turn += 1
        self.touch()

    def spawn(self, work: Coroutine[Any, Any, Any]) -> None:
        task = asyncio.create_task(work)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def safe_control(self, *_args: Any, **_kwargs: Any) -> bool:
        return True

    async def add_transcript(self, *_args: Any, **_kwargs: Any) -> None:
        self.touch()

    async def flush_transcript(self, *_args: Any, **_kwargs: Any) -> bool:
        return False

    async def close(self) -> None:
        if not self._tasks:
            return
        for task in self._tasks:
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)


@router.post(
    "/internal/voice-previews",
    response_model=None,
)
async def create_preview_reservation(
    body: PreviewReservationRequest,
    request: Request,
    authorization: str | None = Header(default=None),
) -> PreviewReservation | JSONResponse:
    if error := auth_error(request.app.state.settings, authorization):
        return error
    raw = dict(body.context)
    raw["call_ref"] = f"preview:{secrets.token_hex(12)}"
    raw["runtime_engine"] = "pipecat"
    raw["tools"] = []
    raw["recording"] = {"enabled": False, "source": "preview"}
    context = VoiceContext.model_validate(raw)
    context.ai.max_duration_sec = min(context.ai.max_duration_sec, PREVIEW_SESSION_MAX_SECONDS)
    try:
        request.app.state.settings.provider_credentials(context.ai.provider)
    except ValueError as error:
        return JSONResponse(
            status_code=503,
            content={"error": "preview_provider_unavailable", "detail": str(error)},
        )
    store: PreviewReservationStore = request.app.state.preview_store
    token = await store.reserve(context)
    if token is None:
        return JSONResponse(
            status_code=429,
            content={"error": "preview_capacity_exhausted"},
        )
    return PreviewReservation(token=token)


@router.websocket("/voice-preview/ws")
async def voice_preview_socket(websocket: WebSocket) -> None:
    await websocket.accept()
    origin = websocket.headers.get("origin")
    host = websocket.headers.get("host")
    if not origin or not host or urlparse(origin).netloc != host:
        await websocket.close(code=4403, reason="preview_origin_forbidden")
        return
    try:
        raw_auth = await asyncio.wait_for(websocket.receive_text(), timeout=3)
        if len(raw_auth) > PREVIEW_AUTH_MESSAGE_MAX_BYTES:
            raise ValueError("preview_auth_message_too_large")
        auth = json.loads(raw_auth)
    except (TimeoutError, TypeError, KeyError, ValueError, json.JSONDecodeError):
        await websocket.close(code=4401, reason="preview_auth_required")
        return
    token = auth.get("token") if isinstance(auth, dict) and auth.get("type") == "AUTH" else None
    if not isinstance(token, str):
        await websocket.close(code=4401, reason="preview_auth_required")
        return
    store: PreviewReservationStore = websocket.app.state.preview_store
    context = await store.consume(token)
    if context is None:
        await websocket.close(code=4401, reason="preview_token_invalid")
        return

    settings: Settings = websocket.app.state.settings
    manager: SessionManager = websocket.app.state.session_manager
    reservation = await manager.reserve(context.call_ref, context.model_dump(mode="json"))
    if reservation.kind is not ReservationKind.CREATED or reservation.record is None:
        await websocket.close(code=4429, reason="preview_capacity_exhausted")
        return

    try:
        await _run_preview(websocket, context, settings)
    finally:
        await manager.release(context.call_ref, reservation.record)


async def _run_preview(
    websocket: WebSocket,
    context: VoiceContext,
    settings: Settings,
) -> None:
    transport = FastAPIWebsocketTransport(
        websocket=websocket,
        params=FastAPIWebsocketParams(
            audio_in_enabled=True,
            audio_in_sample_rate=16_000,
            audio_in_channels=1,
            audio_out_enabled=True,
            audio_out_sample_rate=8_000,
            audio_out_channels=1,
            audio_out_10ms_chunks=2,
            audio_out_end_silence_secs=0,
            audio_out_auto_silence=False,
            fixed_audio_packet_size=320,
            serializer=OneLinkMediaSerializer(),
            session_timeout=PREVIEW_SESSION_MAX_SECONDS,
        ),
    )
    state = PreviewSessionState()
    assembly = build_pipeline(
        context=context,
        state=cast(SessionState, state),
        recorder=None,
        runtime_stream=None,
        settings=settings,
        transport_override=transport,
    )

    @transport.event_handler("on_client_connected")
    async def on_connected(_transport: object, _socket: object) -> None:
        await websocket.send_json(
            {"type": "READY", "provider": assembly.provider, "sample_rate": 8_000}
        )
        if assembly.start_on_connect:
            await assembly.worker.queue_frame(LLMRunFrame())

    @transport.event_handler("on_client_disconnected")
    async def on_disconnected(_transport: object, _socket: object) -> None:
        if not assembly.worker.has_finished():
            await assembly.worker.cancel(reason="preview_disconnected")

    try:
        runner = PipelineRunner(handle_sigint=False, handle_sigterm=False)
        async with asyncio.timeout(PREVIEW_SESSION_MAX_SECONDS + 5):
            await runner.run(assembly.worker)
    except TimeoutError:
        if not assembly.worker.has_finished():
            await assembly.worker.cancel(reason="preview_timeout")
    finally:
        await state.close()
