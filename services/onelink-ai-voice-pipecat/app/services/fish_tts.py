"""OneLink compatibility fixes for Pipecat's Fish Audio TTS adapter."""

from __future__ import annotations

import asyncio

import ormsgpack
from loguru import logger
from pipecat.frames.frames import ErrorFrame, InterruptionFrame, TTSAudioRawFrame
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.fish.tts import FishAudioTTSService


class OneLinkFishAudioTTSService(FishAudioTTSService):
    """Keep Fish's native streaming lifecycle and preserve every audio chunk.

    Fish ``flush`` forces buffered text to be synthesized but does not end that
    synthesis with a per-request ``finish`` event. Pipecat therefore associates
    incoming audio with its active turn context and closes the context after an
    idle interval. Keeping that protocol-native lifecycle avoids serializing all
    later utterances behind an event that Fish never sends.
    """

    AUDIO_CONTEXT_IDLE_TIMEOUT_SECONDS = 1.5

    def __init__(self, *args, **kwargs) -> None:
        # Pipecat defaults to three seconds. Fish balanced streaming normally
        # emits chunks well below this interval; 1.5s retains network jitter
        # margin while removing an avoidable tail from every spoken turn.
        kwargs.setdefault("stop_frame_timeout_s", self.AUDIO_CONTEXT_IDLE_TIMEOUT_SECONDS)
        super().__init__(*args, **kwargs)

    async def _handle_interruption(
        self,
        frame: InterruptionFrame,
        direction: FrameDirection,
    ) -> None:
        # Pipecat reconnects Fish when audio is already playing. Also reconnect
        # when synthesis is pending but the first chunk has not arrived yet, so
        # late audio from the cancelled turn cannot leak into the next context.
        had_audio_contexts = bool(self.get_audio_contexts())
        bot_was_speaking = self._bot_speaking
        await super()._handle_interruption(frame, direction)
        if had_audio_contexts and not bot_was_speaking:
            await self._restart_connection()

    async def _restart_connection(self) -> bool:
        last_error: Exception | None = None
        for attempt in range(1, 3):
            try:
                # A full service restart also replaces the receiver task. A
                # low-level socket swap could leave that task on the old socket.
                await self._disconnect()
                await self._connect()
                return True
            except Exception as exc:
                last_error = exc
                logger.warning(
                    "Fish Audio websocket restart attempt {} failed: {}",
                    attempt,
                    exc,
                )
                await asyncio.sleep(0.25 * attempt)

        await self.push_error(
            ErrorFrame(
                f"Fish Audio websocket restart failed: {last_error}",
                fatal=False,
            )
        )
        return False

    async def _receive_messages(self):
        """Route every non-empty Fish chunk to Pipecat's active context.

        Pipecat 1.5 filters chunks of 1024 bytes or less even though they contain
        valid PCM. Fish does not guarantee that minimum chunk size, so dropping
        them can clip the beginning or end of a phrase.
        """
        async for message in self._get_websocket():
            try:
                if not isinstance(message, bytes):
                    continue

                payload = ormsgpack.unpackb(message)
                if not isinstance(payload, dict):
                    continue

                event = payload.get("event")
                if event == "audio":
                    audio_data = payload.get("audio")
                    if isinstance(audio_data, bytes) and audio_data:
                        context_id = self.get_active_audio_context_id()
                        frame = TTSAudioRawFrame(
                            audio_data,
                            self.sample_rate,
                            1,
                            context_id=context_id,
                        )
                        await self.append_to_audio_context(context_id, frame)
                        await self.stop_ttfb_metrics()
                elif event == "finish":
                    reason = payload.get("reason", "unknown")
                    if reason == "error":
                        await self.push_error(error_msg="Fish Audio server error during synthesis")
                    else:
                        logger.debug("Fish Audio session finished: {}", reason)
            except Exception as exc:
                await self.push_error(
                    error_msg=f"Fish Audio message handling failed: {type(exc).__name__}",
                    exception=exc,
                )
