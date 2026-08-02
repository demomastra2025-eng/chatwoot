"""Fish Audio batch speech-to-text adapter for Pipecat voice turns."""

from __future__ import annotations

import io
import wave
from collections.abc import AsyncGenerator
from dataclasses import dataclass

import httpx
import ormsgpack
from loguru import logger
from pipecat.frames.frames import ErrorFrame, Frame, TranscriptionFrame
from pipecat.services.settings import STTSettings
from pipecat.services.stt_service import SegmentedSTTService
from pipecat.transcriptions.language import Language
from pipecat.utils.time import time_now_iso8601


@dataclass
class FishAudioASRSettings(STTSettings):
    """Runtime-updatable Fish ASR request settings."""

    ignore_timestamps: bool = True


class FishAudioASRService(SegmentedSTTService):
    """Transcribe complete VAD-owned WAV segments through Fish ``POST /v1/asr``."""

    Settings = FishAudioASRSettings
    _settings: Settings

    def __init__(
        self,
        *,
        api_key: str,
        sample_rate: int = 16_000,
        base_url: str = "https://api.fish.audio",
        request_timeout_seconds: float = 15.0,
        max_segment_seconds: float = 60.0,
        http_client: httpx.AsyncClient | None = None,
        settings: Settings | None = None,
        **kwargs,
    ):
        if not api_key.strip():
            raise ValueError("Fish Audio API key is required")

        super().__init__(
            sample_rate=sample_rate,
            settings=settings or self.Settings(language=None, ignore_timestamps=True),
            **kwargs,
        )
        self._api_key = api_key.strip()
        self._endpoint = f"{base_url.rstrip('/')}/v1/asr"
        self._request_timeout_seconds = request_timeout_seconds
        self._max_segment_seconds = max_segment_seconds
        self._client = http_client or httpx.AsyncClient()
        self._owns_client = http_client is None

    def can_generate_metrics(self) -> bool:
        return True

    def language_to_service_language(self, language: Language | str) -> str | None:
        value = str(getattr(language, "value", language))
        return value.split("-", 1)[0].lower()

    async def cleanup(self):
        if self._owns_client:
            await self._client.aclose()
        await super().cleanup()

    async def run_stt(self, audio: bytes) -> AsyncGenerator[Frame, None]:
        """Send one Pipecat-generated WAV segment and yield a final transcript frame."""
        duration_seconds = self._wav_duration_seconds(audio)
        if duration_seconds < 1.0:
            logger.debug("Skipping Fish ASR segment shorter than provider minimum")
            return
        if duration_seconds > self._max_segment_seconds:
            yield ErrorFrame(error="Fish ASR segment exceeds configured duration limit")
            return

        payload: dict[str, object] = {
            "audio": audio,
            "ignore_timestamps": self._settings.ignore_timestamps,
        }
        request_language = self._settings.language
        if request_language is not None:
            payload["language"] = self.language_to_service_language(request_language)

        await self.start_processing_metrics()
        try:
            response = await self._client.post(
                self._endpoint,
                content=ormsgpack.packb(payload),
                headers={
                    "Authorization": f"Bearer {self._api_key}",
                    "Content-Type": "application/msgpack",
                },
                timeout=self._request_timeout_seconds,
            )
            if response.status_code != 200:
                yield ErrorFrame(error=f"Fish ASR API error ({response.status_code})")
                return

            result = self._decode_response(response)
            text = result.get("text")
            if not isinstance(text, str) or not text.strip():
                return

            language = self._language_from_service(result.get("language"), request_language)
            logger.debug(
                "Fish ASR transcript received: chars={}, language={}",
                len(text.strip()),
                getattr(language, "value", language),
            )
            yield TranscriptionFrame(
                text.strip(),
                self._user_id,
                time_now_iso8601(),
                language,
            )
        except httpx.TimeoutException:
            yield ErrorFrame(error="Fish ASR request timed out")
        except (httpx.HTTPError, ValueError, TypeError, ormsgpack.MsgpackDecodeError) as exc:
            yield ErrorFrame(error=f"Fish ASR request failed: {type(exc).__name__}")
        finally:
            await self.stop_processing_metrics()

    @staticmethod
    def _wav_duration_seconds(audio: bytes) -> float:
        try:
            with wave.open(io.BytesIO(audio), "rb") as wav_file:
                frame_rate = wav_file.getframerate()
                return wav_file.getnframes() / frame_rate if frame_rate else 0.0
        except (EOFError, wave.Error) as exc:
            raise ValueError("invalid WAV segment") from exc

    @staticmethod
    def _decode_response(response: httpx.Response) -> dict[str, object]:
        content_type = response.headers.get("content-type", "").lower()
        if "json" in content_type:
            result = response.json()
        else:
            result = ormsgpack.unpackb(response.content)
        if not isinstance(result, dict):
            raise ValueError("invalid Fish ASR response")
        return result

    @staticmethod
    def _language_from_service(
        value: object, fallback: Language | str | None
    ) -> Language | str | None:
        if not isinstance(value, str) or not value.strip():
            return fallback
        try:
            return Language(value.strip().lower())
        except ValueError:
            return fallback
