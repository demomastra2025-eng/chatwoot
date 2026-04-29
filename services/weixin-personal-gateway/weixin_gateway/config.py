from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class GatewayConfig:
    host: str
    port: int
    gateway_token: str

    @classmethod
    def from_env(cls) -> "GatewayConfig":
        return cls(
            host=os.getenv("WEIXIN_GATEWAY_HOST", "127.0.0.1"),
            port=int(os.getenv("WEIXIN_GATEWAY_PORT", "8097")),
            gateway_token=os.getenv("WEIXIN_GATEWAY_TOKEN", ""),
        )
