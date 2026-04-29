from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
from typing import Any, Mapping


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def jwt_hs256(payload: Mapping[str, Any], secret: str) -> str:
    """Return a compact HS256 JWT compatible with Rails JWT.decode(..., 'HS256')."""
    if not secret:
        raise ValueError("webhook secret must be present")

    header = {"alg": "HS256", "typ": "JWT"}
    enriched_payload = {"iat": int(time.time()), **dict(payload)}
    encoded_header = _b64url(json.dumps(header, separators=(",", ":")).encode("utf-8"))
    encoded_payload = _b64url(json.dumps(enriched_payload, separators=(",", ":")).encode("utf-8"))
    signing_input = f"{encoded_header}.{encoded_payload}".encode("ascii")
    signature = hmac.new(secret.encode("utf-8"), signing_input, hashlib.sha256).digest()
    return f"{encoded_header}.{encoded_payload}.{_b64url(signature)}"


def constant_time_equal(left: str, right: str) -> bool:
    return hmac.compare_digest(left.encode("utf-8"), right.encode("utf-8"))
