"""Pipecat serializer for the existing OneLink JSON/base64 media protocol."""

from __future__ import annotations

import base64
import binascii
import json
from typing import Any

from pipecat.frames.frames import (
    Frame,
    InputAudioRawFrame,
    InterruptionFrame,
    OutputAudioRawFrame,
)
from pipecat.serializers.base_serializer import FrameSerializer

INPUT_SAMPLE_RATE = 16_000
OUTPUT_SAMPLE_RATE = 8_000
INPUT_FRAME_BYTES = 640
OUTPUT_FRAME_BYTES = 320
MAX_MESSAGE_BYTES = 64 * 1024
INPUT_MIME_TYPE = "audio/pcm;rate=16000"
OUTPUT_MIME_TYPE = "audio/pcm;rate=8000"


class OneLinkMediaSerializer(FrameSerializer):
    """Translate OneLink AUDIO_IN/AUDIO_OUT frames without owning the WebSocket loop."""

    def __init__(
        self,
        params: FrameSerializer.InputParams | None = None,
        *,
        clear_audio_on_interrupt: bool = True,
        **kwargs: Any,
    ) -> None:
        super().__init__(params=params, **kwargs)
        self._clear_audio_on_interrupt = clear_audio_on_interrupt

    async def serialize(self, frame: Frame) -> str | bytes | None:
        if isinstance(frame, InterruptionFrame):
            if not self._clear_audio_on_interrupt:
                return None
            return json.dumps({"type": "CLEAR_AUDIO"}, separators=(",", ":"))
        if not isinstance(frame, OutputAudioRawFrame):
            return None
        if (
            frame.sample_rate != OUTPUT_SAMPLE_RATE
            or frame.num_channels != 1
            or len(frame.audio) != OUTPUT_FRAME_BYTES
        ):
            return None
        return json.dumps(
            {
                "type": "AUDIO_OUT",
                "data": base64.b64encode(frame.audio).decode("ascii"),
                "mime_type": OUTPUT_MIME_TYPE,
            },
            separators=(",", ":"),
        )

    async def deserialize(self, data: str | bytes) -> Frame | None:
        if len(data) > MAX_MESSAGE_BYTES:
            return None
        try:
            payload = json.loads(data)
            if not isinstance(payload, dict) or payload.get("type") != "AUDIO_IN":
                return None
            if payload.get("mime_type") != INPUT_MIME_TYPE:
                return None
            encoded = payload.get("data")
            if not isinstance(encoded, str) or not encoded:
                return None
            audio = base64.b64decode(encoded, validate=True)
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError, binascii.Error):
            return None
        if len(audio) != INPUT_FRAME_BYTES:
            return None
        return InputAudioRawFrame(
            audio=audio,
            sample_rate=INPUT_SAMPLE_RATE,
            num_channels=1,
        )
