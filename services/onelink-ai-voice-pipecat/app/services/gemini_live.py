"""OneLink compatibility fixes for Pipecat's Gemini Live adapter."""

from __future__ import annotations

from copy import deepcopy

from google.genai.types import LiveServerMessage
from pipecat.services.google.gemini_live.llm import GeminiLiveLLMService


class OneLinkGeminiLiveLLMService(GeminiLiveLLMService):
    """Process every model-turn part until upstream Pipecat does so natively."""

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
