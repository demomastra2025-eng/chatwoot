"""OneLink compatibility fixes for Pipecat's Gemini Live adapter."""

from __future__ import annotations

from copy import deepcopy

from google.genai.types import (
    AudioTranscriptionConfig,
    LanguageHints,
    LiveConnectConfig,
    LiveServerMessage,
)
from pipecat.frames.frames import Frame, InputTextRawFrame
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.google.gemini_live.llm import GeminiLiveLLMService


class OneLinkInternalTextFrame(InputTextRawFrame):
    """Text sent to Gemini for speech control but hidden from assistant output."""


class OneLinkGeminiLiveLLMService(GeminiLiveLLMService):
    """Process every model-turn part until upstream Pipecat does so natively."""

    def __init__(self, *args, input_language_priorities: list[str] | None = None, **kwargs):
        self._input_language_priorities = list(dict.fromkeys(input_language_priorities or []))
        super().__init__(*args, **kwargs)

    async def _connection_task_handler(self, config: LiveConnectConfig):
        if self._input_language_priorities:
            config.input_audio_transcription = AudioTranscriptionConfig(
                language_hints=LanguageHints(
                    language_codes=self._input_language_priorities,
                )
            )
        await super()._connection_task_handler(config)

    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        if isinstance(frame, OneLinkInternalTextFrame):
            await self._send_user_text(frame.text)
            return
        await super().process_frame(frame, direction)

    async def _handle_msg_model_turn(self, message: LiveServerMessage) -> None:
        model_turn = message.server_content and message.server_content.model_turn
        parts = model_turn and model_turn.parts
        if not parts or len(parts) == 1:
            await super()._handle_msg_model_turn(message)
            return

        for index in range(len(parts)):
            part_message = (
                message.model_copy(deep=True)
                if hasattr(message, "model_copy")
                else deepcopy(message)
            )
            part_message.server_content.model_turn.parts = [
                part_message.server_content.model_turn.parts[index]
            ]
            await super()._handle_msg_model_turn(part_message)
