"""FastAPI process boundary for the parallel Pipecat runtime."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from app.api.routes import SessionRunner, router
from app.config import Settings
from app.preview import PreviewReservationStore
from app.preview import router as preview_router
from app.sessions.manager import SessionManager
from app.sessions.runner import PipecatSessionRunner

_DEFAULT_RUNNER = object()


def create_app(
    *,
    settings: Settings | None = None,
    session_runner: SessionRunner | None | object = _DEFAULT_RUNNER,
) -> FastAPI:
    """Create the process boundary with a real Pipecat runner by default."""
    runtime_settings = settings or Settings.from_env()
    configured_runner = (
        PipecatSessionRunner(runtime_settings)
        if session_runner is _DEFAULT_RUNNER
        else session_runner
    )
    manager = SessionManager(runtime_settings.max_concurrent_sessions)

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        start = getattr(configured_runner, "start", None)
        if start is not None:
            await start()
        try:
            yield
        finally:
            await manager.shutdown()
            stop = getattr(configured_runner, "stop", None)
            if stop is not None:
                await stop()

    application = FastAPI(title="OneLink AI Voice Pipecat", lifespan=lifespan)
    application.state.settings = runtime_settings
    application.state.session_manager = manager
    application.state.session_runner = configured_runner
    application.state.session_preflight = getattr(configured_runner, "preflight", None)
    application.state.preview_store = PreviewReservationStore(
        max_pending=runtime_settings.max_concurrent_sessions * 2
    )
    application.include_router(router)
    application.include_router(preview_router)

    def health_payload() -> dict:
        checks = list(runtime_settings.readiness_errors)
        if configured_runner is None:
            checks.append("session_runner_unavailable")
        return {
            "status": "ok",
            "ready": not checks,
            "active_sessions": manager.active_count,
            "runtime_engine": "pipecat",
            "realtime_provider": runtime_settings.realtime_provider,
            "supported_providers": [
                "gemini-live",
                "openai-live",
                "openai-realtime",
                "elevenlabs",
                "cartesia",
                "fish",
            ],
            "checks": checks,
        }

    @application.get("/health")
    async def health() -> dict:
        return health_payload()

    @application.get("/ready")
    async def ready() -> JSONResponse:
        payload = health_payload()
        return JSONResponse(status_code=200 if payload["ready"] else 503, content=payload)

    return application


app = create_app()
