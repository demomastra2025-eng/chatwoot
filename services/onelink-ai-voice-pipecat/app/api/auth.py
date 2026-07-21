"""Fail-closed bearer authentication for internal attach endpoints."""

from __future__ import annotations

import hmac

from fastapi.responses import JSONResponse

from app.config import Settings


def auth_error(settings: Settings, authorization: str | None) -> JSONResponse | None:
    """Return a legacy-compatible auth error, or None for an authorized request."""
    expected = settings.internal_token_value
    if not expected:
        return JSONResponse(status_code=503, content={"error": "internal_token_required"})

    scheme, separator, candidate = (authorization or "").partition(" ")
    valid_scheme = bool(separator) and scheme.lower() == "bearer"
    valid_token = hmac.compare_digest(candidate, expected)
    if not (valid_scheme and valid_token):
        return JSONResponse(status_code=401, content={"error": "unauthorized"})
    return None
