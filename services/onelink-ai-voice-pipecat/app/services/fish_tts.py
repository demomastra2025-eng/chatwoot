"""OneLink compatibility fixes for Pipecat's Fish Audio TTS adapter."""

from __future__ import annotations

import asyncio
import time
from collections.abc import AsyncGenerator

import ormsgpack
from loguru import logger
from pipecat.frames.frames import (
    ErrorFrame,
    Frame,
    InterruptionFrame,
    TTSAudioRawFrame,
    TTSStoppedFrame,
)
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.fish.tts import FishAudioTTSService
from pipecat.utils.text.simple_text_aggregator import SimpleTextAggregator
from pipecat.utils.tracing.service_decorators import traced_tts
from websockets.protocol import State


class FishTurnTextAggregator(SimpleTextAggregator):
    """Keep one short LLM turn in one Fish synthesis request.

    Pipecat's sentence aggregator normally emits every completed sentence.
    Fish flushes each emitted item as a separate synthesis unit, which creates
    an audible seam between sentences. We retain Pipecat's native end-of-turn
    flush but suppress intermediate sentence boundaries.
    """

    async def _check_sentence_with_lookahead(self, char: str):
        return None


class OneLinkFishAudioTTSService(FishAudioTTSService):
    """Keep Fish's native streaming lifecycle and preserve every audio chunk.

    Fish ``flush`` forces buffered text to be synthesized but does not end that
    synthesis with a per-request ``finish`` event. Pipecat therefore associates
    incoming audio with its active turn context and closes the context after an
    idle interval. Keeping that protocol-native lifecycle avoids serializing all
    later utterances behind an event that Fish never sends.
    """

    AUDIO_CONTEXT_IDLE_TIMEOUT_SECONDS = 1.5
    FIRST_AUDIO_TIMEOUT_SECONDS = 1.25
    SYNTHESIS_ATTEMPTS = 2

    def __init__(self, *args, **kwargs) -> None:
        # Pipecat defaults to three seconds. Fish balanced streaming normally
        # emits chunks well below this interval; 1.5s retains network jitter
        # margin while removing an avoidable tail from every spoken turn.
        kwargs.setdefault("stop_frame_timeout_s", self.AUDIO_CONTEXT_IDLE_TIMEOUT_SECONDS)
        super().__init__(*args, **kwargs)
        self._text_aggregator = FishTurnTextAggregator(aggregation_type=self._text_aggregation_mode)
        self._synthesis_lock = asyncio.Lock()
        self._interruption_epoch = 0
        self._pending_context_id: str | None = None
        self._pending_first_audio: asyncio.Event | None = None

    @traced_tts
    async def run_tts(
        self,
        text: str,
        context_id: str,
    ) -> AsyncGenerator[Frame | None, None]:
        """Send one utterance and replay it once only when Fish returns no audio.

        Fish does not emit a reliable per-flush completion event, so completion
        remains owned by Pipecat's audio-context idle timeout. Waiting only for
        the first audio chunk gives us a bounded health signal without ever
        serializing later utterances behind a nonexistent ``finish`` message.
        """
        async with self._synthesis_lock:
            interruption_epoch = self._interruption_epoch
            usage_started = False
            last_error: Exception | None = None

            for attempt in range(1, self.SYNTHESIS_ATTEMPTS + 1):
                if interruption_epoch != self._interruption_epoch:
                    return

                first_audio = asyncio.Event()
                self._pending_context_id = context_id
                self._pending_first_audio = first_audio
                requested_at = time.monotonic()
                try:
                    if not self._websocket or self._websocket.state is State.CLOSED:
                        await self._connect()
                    await self._get_websocket().send(
                        ormsgpack.packb({"event": "text", "text": text})
                    )
                    if not usage_started:
                        await self.start_tts_usage_metrics(text)
                        usage_started = True
                    await self._get_websocket().send(ormsgpack.packb({"event": "flush"}))
                    await asyncio.wait_for(
                        first_audio.wait(),
                        timeout=self.FIRST_AUDIO_TIMEOUT_SECONDS,
                    )
                except Exception as exc:
                    last_error = exc
                else:
                    if interruption_epoch != self._interruption_epoch:
                        return
                    logger.info(
                        "Fish Audio first chunk context_id={} attempt={} ttfb_ms={}",
                        context_id,
                        attempt,
                        round((time.monotonic() - requested_at) * 1_000),
                    )
                    yield None
                    return
                finally:
                    if self._pending_first_audio is first_audio:
                        self._pending_first_audio = None
                        self._pending_context_id = None

                if interruption_epoch != self._interruption_epoch:
                    return
                if attempt >= self.SYNTHESIS_ATTEMPTS:
                    break

                # Keep the Pipecat audio context alive while the socket is
                # replaced, otherwise its 1.5s idle timer can remove the target
                # queue just before replay audio arrives.
                self._refresh_audio_context(context_id)
                logger.warning(
                    "Fish Audio returned no first chunk; reconnecting context_id={} attempt={}",
                    context_id,
                    attempt,
                )
                if not await self._restart_connection():
                    last_error = ConnectionError("Fish Audio reconnect failed")
                    break

            logger.error(
                "Fish Audio synthesis produced no audio context_id={} attempts={} error={}",
                context_id,
                self.SYNTHESIS_ATTEMPTS,
                type(last_error).__name__ if last_error else "unknown",
            )
            yield ErrorFrame(
                error="Fish Audio TTS produced no audio after one replay",
                fatal=False,
                exception=last_error,
            )
            yield TTSStoppedFrame(context_id=context_id)

    async def _handle_interruption(
        self,
        frame: InterruptionFrame,
        direction: FrameDirection,
    ) -> None:
        # Pipecat reconnects Fish when audio is already playing. Also reconnect
        # when synthesis is pending but the first chunk has not arrived yet, so
        # late audio from the cancelled turn cannot leak into the next context.
        self._interruption_epoch += 1
        if self._pending_first_audio is not None:
            self._pending_first_audio.set()
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
                        context_id = self._pending_context_id or self.get_active_audio_context_id()
                        frame = TTSAudioRawFrame(
                            audio_data,
                            self.sample_rate,
                            1,
                            context_id=context_id,
                        )
                        await self.append_to_audio_context(context_id, frame)
                        if self._pending_first_audio is not None:
                            self._pending_first_audio.set()
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
