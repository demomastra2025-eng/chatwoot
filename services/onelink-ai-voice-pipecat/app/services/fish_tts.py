"""OneLink hardening for the Pipecat Fish Audio TTS adapter."""

from __future__ import annotations

import ormsgpack
from loguru import logger
from pipecat.frames.frames import TTSAudioRawFrame
from pipecat.services.fish.tts import FishAudioTTSService


class OneLinkFishAudioTTSService(FishAudioTTSService):
    """Preserve every non-empty provider audio chunk, including short final chunks."""

    async def _receive_messages(self):
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
