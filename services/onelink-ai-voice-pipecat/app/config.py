"""Fail-closed runtime configuration."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Literal, cast

from pydantic import AnyHttpUrl, BaseModel, ConfigDict, Field, SecretStr


class Settings(BaseModel):
    """Immutable settings loaded from explicit Pipecat environment variables."""

    model_config = ConfigDict(frozen=True)

    internal_token: SecretStr = Field(default_factory=lambda: SecretStr(""))
    callback_token: SecretStr = Field(default_factory=lambda: SecretStr(""))
    gemini_api_key: SecretStr = Field(default_factory=lambda: SecretStr(""))
    openai_api_key: SecretStr = Field(default_factory=lambda: SecretStr(""))
    elevenlabs_api_key: SecretStr = Field(default_factory=lambda: SecretStr(""))
    cartesia_api_key: SecretStr = Field(default_factory=lambda: SecretStr(""))
    openrouter_api_key: SecretStr = Field(default_factory=lambda: SecretStr(""))
    fish_api_key: SecretStr = Field(default_factory=lambda: SecretStr(""))
    callback_base_url: AnyHttpUrl | None = None
    realtime_provider: Literal[
        "gemini-live", "openai-realtime", "elevenlabs", "cartesia", "fish"
    ] = "gemini-live"
    elevenlabs_stt_model: str = "scribe_v2_realtime"
    elevenlabs_tts_model: str = "eleven_flash_v2_5"
    cartesia_stt_model: str = "ink-whisper"
    cartesia_tts_model: str = "sonic-3.5"
    fish_tts_model: str = "s2.1-pro-free"
    fish_tts_latency: Literal["normal", "balanced"] = "balanced"
    fish_asr_timeout_seconds: float = Field(default=15.0, ge=1.0, le=60.0)
    fish_asr_max_segment_seconds: float = Field(default=60.0, ge=1.0, le=3_600.0)
    max_concurrent_sessions: int = Field(default=16, ge=1, le=1000)
    callback_timeout_seconds: float = Field(default=5.0, ge=0.1, le=30.0)
    callback_max_retries: int = Field(default=2, ge=0, le=5)
    recording_root: Path = Path("/app/storage")

    @classmethod
    def from_env(cls) -> Settings:
        """Build settings without silently inventing required values."""
        return cls(
            internal_token=SecretStr(
                _first_env(
                    "ONELINK_AI_VOICE_PIPECAT_INTERNAL_TOKEN",
                    "ONELINK_AI_VOICE_INTERNAL_TOKEN",
                    "AI_VOICE_INTERNAL_TOKEN",
                )
            ),
            callback_token=SecretStr(
                _first_env(
                    "ONELINK_AI_VOICE_PIPECAT_CALLBACK_TOKEN",
                    "VOICE_AGENT_ONELINK_AI_SHARED_SECRET",
                    "ONELINK_AI_VOICE_INTERNAL_TOKEN",
                    "AI_VOICE_INTERNAL_TOKEN",
                )
            ),
            gemini_api_key=SecretStr(
                _first_env(
                    "ONELINK_AI_VOICE_PIPECAT_GOOGLE_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"
                )
            ),
            openai_api_key=SecretStr(
                _first_env("ONELINK_AI_VOICE_PIPECAT_OPENAI_API_KEY", "OPENAI_API_KEY")
            ),
            elevenlabs_api_key=SecretStr(
                _first_env("ONELINK_AI_VOICE_PIPECAT_ELEVENLABS_API_KEY", "ELEVENLABS_API_KEY")
            ),
            cartesia_api_key=SecretStr(
                _first_env("ONELINK_AI_VOICE_PIPECAT_CARTESIA_API_KEY", "CARTESIA_API_KEY")
            ),
            openrouter_api_key=SecretStr(
                _first_env("ONELINK_AI_VOICE_PIPECAT_OPENROUTER_API_KEY", "OPENROUTER_API_KEY")
            ),
            fish_api_key=SecretStr(
                _first_env("ONELINK_AI_VOICE_PIPECAT_FISH_API_KEY", "FISH_AUDIO_API_KEY")
            ),
            callback_base_url=_first_env(
                "ONELINK_AI_VOICE_PIPECAT_CALLBACK_BASE_URL",
                "ONELINK_AI_VOICE_CALLBACK_BASE_URL",
            )
            or None,
            realtime_provider=cast(
                Literal["gemini-live", "openai-realtime", "elevenlabs", "cartesia", "fish"],
                os.getenv("ONELINK_AI_VOICE_PIPECAT_REALTIME_PROVIDER", "gemini-live"),
            ),
            elevenlabs_stt_model=os.getenv(
                "ONELINK_AI_VOICE_PIPECAT_ELEVENLABS_STT_MODEL", "scribe_v2_realtime"
            ),
            elevenlabs_tts_model=os.getenv(
                "ONELINK_AI_VOICE_PIPECAT_ELEVENLABS_TTS_MODEL", "eleven_flash_v2_5"
            ),
            cartesia_tts_model=os.getenv(
                "ONELINK_AI_VOICE_PIPECAT_CARTESIA_TTS_MODEL", "sonic-3.5"
            ),
            cartesia_stt_model=os.getenv(
                "ONELINK_AI_VOICE_PIPECAT_CARTESIA_STT_MODEL", "ink-whisper"
            ),
            fish_tts_model=os.getenv("ONELINK_AI_VOICE_PIPECAT_FISH_TTS_MODEL", "s2.1-pro-free"),
            fish_tts_latency=cast(
                Literal["normal", "balanced"],
                os.getenv("ONELINK_AI_VOICE_PIPECAT_FISH_TTS_LATENCY", "balanced"),
            ),
            fish_asr_timeout_seconds=float(
                os.getenv("ONELINK_AI_VOICE_PIPECAT_FISH_ASR_TIMEOUT_SECONDS", "15")
            ),
            fish_asr_max_segment_seconds=float(
                os.getenv("ONELINK_AI_VOICE_PIPECAT_FISH_ASR_MAX_SEGMENT_SECONDS", "60")
            ),
            max_concurrent_sessions=os.getenv(
                "ONELINK_AI_VOICE_PIPECAT_MAX_CONCURRENT_SESSIONS", "16"
            ),
            callback_timeout_seconds=float(
                os.getenv("ONELINK_AI_VOICE_PIPECAT_CALLBACK_TIMEOUT_SECONDS", "5")
            ),
            callback_max_retries=int(
                os.getenv("ONELINK_AI_VOICE_PIPECAT_CALLBACK_MAX_RETRIES", "2")
            ),
            recording_root=Path(
                os.getenv(
                    "ONELINK_AI_VOICE_PIPECAT_RECORDING_ROOT",
                    "/app/storage",
                )
            ),
        )

    @property
    def internal_token_value(self) -> str:
        """Return the secret only for constant-time request authentication."""
        return self.internal_token.get_secret_value().strip()

    @property
    def callback_token_value(self) -> str:
        """Return the callback bearer only at the HTTP boundary."""
        return self.callback_token.get_secret_value().strip()

    @property
    def gemini_api_key_value(self) -> str:
        """Return the provider key only when constructing the Gemini service."""
        return self.gemini_api_key.get_secret_value().strip()

    def provider_credentials(
        self, provider: str, *, stt_provider: str | None = None
    ) -> dict[str, str]:
        """Return only the credentials required by the selected session provider."""
        credentials = {
            "gemini-live": {"gemini_api_key": self.gemini_api_key.get_secret_value().strip()},
            "openai-realtime": {"openai_api_key": self.openai_api_key.get_secret_value().strip()},
            "elevenlabs": {
                "elevenlabs_api_key": self.elevenlabs_api_key.get_secret_value().strip(),
                "openrouter_api_key": self.openrouter_api_key.get_secret_value().strip(),
            },
            "cartesia": {
                "cartesia_api_key": self.cartesia_api_key.get_secret_value().strip(),
                "openrouter_api_key": self.openrouter_api_key.get_secret_value().strip(),
            },
        }.get(provider)
        if provider == "fish":
            if stt_provider not in {"elevenlabs", "fish"}:
                raise ValueError("unsupported Fish STT provider")
            credentials = {
                "fish_api_key": self.fish_api_key.get_secret_value().strip(),
                "openrouter_api_key": self.openrouter_api_key.get_secret_value().strip(),
            }
            if stt_provider == "elevenlabs":
                credentials["elevenlabs_api_key"] = (
                    self.elevenlabs_api_key.get_secret_value().strip()
                )
        if credentials is None:
            raise ValueError("unsupported Pipecat provider")
        missing = [name for name, value in credentials.items() if not value]
        if missing:
            raise ValueError(f"provider credentials required: {', '.join(missing)}")
        return credentials

    @property
    def readiness_errors(self) -> tuple[str, ...]:
        """List local configuration blockers without exposing their values."""
        errors: list[str] = []
        if not self.internal_token_value:
            errors.append("internal_token_required")
        if not self.callback_token_value:
            errors.append("callback_token_required")
        if self.callback_base_url is None:
            errors.append("callback_base_url_required")
        return tuple(errors)

    @property
    def ready(self) -> bool:
        """Return whether local configuration is sufficient to start sessions."""
        return not self.readiness_errors


def _first_env(*names: str) -> str:
    for name in names:
        value = os.getenv(name, "").strip()
        if value:
            return value
    return ""
