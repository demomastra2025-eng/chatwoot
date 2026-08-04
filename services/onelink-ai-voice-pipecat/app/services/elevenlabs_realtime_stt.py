"""OneLink extensions for ElevenLabs realtime speech recognition."""

from __future__ import annotations

from urllib.parse import urlencode

from loguru import logger
from pipecat.services.elevenlabs.stt import CommitStrategy, ElevenLabsRealtimeSTTService
from pipecat.services.settings import is_given
from websockets.asyncio.client import connect as websocket_connect
from websockets.protocol import State


class OneLinkElevenLabsRealtimeSTTService(ElevenLabsRealtimeSTTService):
    """Add ElevenLabs' native multilingual hints missing from Pipecat 1.5.0.

    The provider accepts one primary ``language_code`` and repeated
    ``secondary_languages`` query parameters. Without these hints, short G.711
    telephone turns can be assigned to a phonetically similar language before
    transcription.
    """

    def __init__(self, *, secondary_languages: list[str] | None = None, **kwargs):
        super().__init__(**kwargs)
        primary_value = getattr(self._settings.language, "value", self._settings.language)
        primary = str(primary_value or "").strip().lower()
        self._secondary_languages = list(
            dict.fromkeys(
                language.strip().lower()
                for language in (secondary_languages or [])
                if language.strip() and language.strip().lower() != primary
            )
        )

    def _connection_query_params(self) -> list[tuple[str, object]]:
        params: list[tuple[str, object]] = [("model_id", self._settings.model)]

        if self._settings.language:
            params.append(("language_code", self._settings.language))
        params.extend(
            ("secondary_languages", language)
            for language in self._secondary_languages
        )
        params.extend(
            (
                ("audio_format", self._audio_format),
                ("commit_strategy", self._commit_strategy.value),
            )
        )

        keyterms = self._settings.keyterms
        if is_given(keyterms) and keyterms is not None:
            params.extend(("keyterms", keyterm) for keyterm in keyterms)

        if self._include_timestamps:
            params.append(("include_timestamps", "true"))
        if self._enable_logging:
            params.append(("enable_logging", "true"))
        if self._include_language_detection:
            params.append(("include_language_detection", "true"))

        filter_background_audio = getattr(
            self._settings, "filter_background_audio", None
        )
        if filter_background_audio is not None and is_given(filter_background_audio):
            params.append(
                ("filter_background_audio", str(filter_background_audio).lower())
            )

        if self._commit_strategy == CommitStrategy.VAD:
            optional_vad_params = {
                "vad_silence_threshold_secs": self._settings.vad_silence_threshold_secs,
                "vad_threshold": self._settings.vad_threshold,
                "min_speech_duration_ms": self._settings.min_speech_duration_ms,
                "min_silence_duration_ms": self._settings.min_silence_duration_ms,
            }
            params.extend(
                (name, value)
                for name, value in optional_vad_params.items()
                if value is not None
            )

        return params

    async def _connect_websocket(self):
        try:
            if self._websocket and self._websocket.state is State.OPEN:
                return

            logger.debug("Connecting to ElevenLabs Realtime STT")
            ws_url = (
                f"wss://{self._base_url}/v1/speech-to-text/realtime?"
                f"{urlencode(self._connection_query_params())}"
            )
            self._websocket = await websocket_connect(
                ws_url,
                additional_headers={"xi-api-key": self._api_key},
            )
            await self._call_event_handler("on_connected")
            logger.debug("Connected to ElevenLabs Realtime STT")
        except Exception as error:
            self._websocket = None
            await self.push_error(
                error_msg=f"Unable to connect to ElevenLabs Realtime STT: {error}",
                exception=error,
            )
