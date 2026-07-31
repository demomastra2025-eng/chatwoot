from unittest.mock import AsyncMock, patch

import pytest
from google.genai.types import Content, LiveServerContent, LiveServerMessage, Part
from pipecat.services.google.gemini_live.llm import GeminiLiveLLMService

from app.services.gemini_live import OneLinkGeminiLiveLLMService


def _model_turn_message(*texts: str) -> LiveServerMessage:
    return LiveServerMessage(
        server_content=LiveServerContent(
            model_turn=Content(
                role="model",
                parts=[Part(text=text) for text in texts],
            )
        )
    )


@pytest.mark.asyncio
async def test_processes_every_part_in_a_gemini_model_turn():
    service = object.__new__(OneLinkGeminiLiveLLMService)
    message = _model_turn_message("first", "second", "third")

    with patch.object(
        GeminiLiveLLMService,
        "_handle_msg_model_turn",
        new_callable=AsyncMock,
    ) as upstream_handler:
        await service._handle_msg_model_turn(message)

    handled_parts = [
        call.args[0].server_content.model_turn.parts[0].text
        for call in upstream_handler.await_args_list
    ]
    assert handled_parts == ["first", "second", "third"]
    assert [part.text for part in message.server_content.model_turn.parts] == [
        "first",
        "second",
        "third",
    ]


@pytest.mark.asyncio
async def test_preserves_upstream_path_for_a_single_model_turn_part():
    service = object.__new__(OneLinkGeminiLiveLLMService)
    message = _model_turn_message("only")

    with patch.object(
        GeminiLiveLLMService,
        "_handle_msg_model_turn",
        new_callable=AsyncMock,
    ) as upstream_handler:
        await service._handle_msg_model_turn(message)

    upstream_handler.assert_awaited_once_with(message)
