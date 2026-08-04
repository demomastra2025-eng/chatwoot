"""OneLink extensions for ElevenLabs realtime speech recognition."""

from __future__ import annotations

import asyncio
import time
from collections.abc import AsyncGenerator
from urllib.parse import urlencode

from loguru import logger
from pipecat.frames.frames import Frame, VADUserStoppedSpeakingFrame
from pipecat.processors.frame_processor import FrameDirection
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

    PROVIDER_MIN_CHUNK_DURATION_SECONDS = 0.1
    PROVIDER_MAX_CHUNK_DURATION_SECONDS = 1.0

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
        # The media bridge emits low-latency 20 ms PCM frames, while ElevenLabs
        # recommends 100 ms to 1 s chunks for realtime STT. ffmpeg can also
        # release several 20 ms frames in one stdout read, which previously
        # made those frames hit the provider as a burst and terminate the
        # session with "audio data is being sent too frequently". Keep the
        # transport contract unchanged and smooth only the provider boundary.
        self._provider_audio_buffer = bytearray()
        self._provider_audio_send_lock = asyncio.Lock()
        self._last_manual_commit_at: float | None = None

    @property
    def _provider_sample_rate(self) -> int:
        # StartFrame sets sample_rate before media arrives. Keep the configured
        # constructor value as a defensive fallback for startup ordering.
        return max(1, self.sample_rate or self._init_sample_rate)

    @property
    def _provider_min_chunk_bytes(self) -> int:
        return max(
            2,
            round(
                self._provider_sample_rate
                * 2
                * self.PROVIDER_MIN_CHUNK_DURATION_SECONDS
            ),
        )

    @property
    def _provider_max_chunk_bytes(self) -> int:
        return max(
            self._provider_min_chunk_bytes,
            round(
                self._provider_sample_rate
                * 2
                * self.PROVIDER_MAX_CHUNK_DURATION_SECONDS
            ),
        )

    async def run_stt(self, audio: bytes) -> AsyncGenerator[Frame | None, None]:
        """Coalesce small frames while allowing the stream to catch up after jitter.

        The provider accepts 100ms-1s chunks. Explicitly sleeping for each 100ms
        chunk limits throughput to exactly realtime, so any scheduler/network
        pause becomes permanent recognition lag. Sending one bounded aggregate
        immediately preserves the provider contract and lets queued audio catch
        up after transient DEV load.
        """
        self._provider_audio_buffer.extend(audio)
        sent = False
        min_chunk_bytes = self._provider_min_chunk_bytes
        max_chunk_bytes = self._provider_max_chunk_bytes
        while len(self._provider_audio_buffer) >= min_chunk_bytes:
            chunk_bytes = min(len(self._provider_audio_buffer), max_chunk_bytes)
            chunk = bytes(self._provider_audio_buffer[:chunk_bytes])
            del self._provider_audio_buffer[:chunk_bytes]
            async for frame in self._send_provider_audio(chunk):
                sent = True
                yield frame
        if not sent:
            yield None

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        if isinstance(frame, VADUserStoppedSpeakingFrame):
            # Never let a partial tail overtake the manual commit. Padding the
            # final provider chunk with silence keeps it within ElevenLabs' 100
            # ms minimum with at most one bounded provider pacing interval.
            tail_bytes = len(self._provider_audio_buffer)
            flush_started_at = time.monotonic()
            await self._flush_provider_audio_buffer()
            async with self._provider_audio_send_lock:
                self._last_manual_commit_at = time.monotonic()
                await super().process_frame(frame, direction)
            logger.info(
                "ElevenLabs manual commit sent tail_bytes={} flush_ms={}",
                tail_bytes,
                round((time.monotonic() - flush_started_at) * 1_000),
            )
            return
        await super().process_frame(frame, direction)

    async def _flush_provider_audio_buffer(self) -> None:
        if not self._provider_audio_buffer:
            return
        min_chunk_bytes = self._provider_min_chunk_bytes
        max_chunk_bytes = self._provider_max_chunk_bytes
        while self._provider_audio_buffer:
            chunk_bytes = min(len(self._provider_audio_buffer), max_chunk_bytes)
            chunk = bytes(self._provider_audio_buffer[:chunk_bytes])
            del self._provider_audio_buffer[:chunk_bytes]
            if len(chunk) < min_chunk_bytes:
                chunk += bytes(min_chunk_bytes - len(chunk))
            async for frame in self._send_provider_audio(chunk):
                if frame is not None:
                    await self.push_frame(frame)

    async def _send_provider_audio(
        self, audio: bytes
    ) -> AsyncGenerator[Frame | None, None]:
        async with self._provider_audio_send_lock:
            async for frame in super().run_stt(audio):
                yield frame

    async def _send_keepalive(self, silence: bytes):
        # Keepalive is already a 100 ms provider-native chunk. Serialize it
        # with normal audio so a timer cannot create a second simultaneous
        # websocket write.
        async with self._provider_audio_send_lock:
            await super()._send_keepalive(silence)

    async def _on_committed_transcript(self, data: dict):
        commit_latency_ms = None
        if self._last_manual_commit_at is not None:
            commit_latency_ms = round(
                (time.monotonic() - self._last_manual_commit_at) * 1_000
            )
            self._last_manual_commit_at = None
        logger.info(
            "ElevenLabs committed transcript chars={} commit_latency_ms={}",
            len(str(data.get("text") or "").strip()),
            commit_latency_ms,
        )
        await super()._on_committed_transcript(data)

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
