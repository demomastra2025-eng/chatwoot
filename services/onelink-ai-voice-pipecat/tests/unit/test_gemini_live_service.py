from unittest.mock import AsyncMock, patch

import pytest
from google.genai.types import (
    Content,
    LiveConnectConfig,
    LiveServerContent,
    LiveServerMessage,
    Part,
)
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.google.gemini_live.llm import GeminiLiveLLMService

from app.services.gemini_live import (
    OneLinkGeminiLiveLLMService,
    OneLinkInternalTextFrame,
    OneLinkToolResultGenerationEndFrame,
    OneLinkToolResultGenerationStartFrame,
)


@pytest.mark.asyncio
async def test_applies_ordered_input_language_hints_to_the_native_connect_config():
    service = object.__new__(OneLinkGeminiLiveLLMService)
    service.__dict__["_input_language_priorities"] = ("ru-KZ", "kk-KZ", "en-US")
    config = LiveConnectConfig()

    with patch.object(
        GeminiLiveLLMService,
        "_connection_task_handler",
        new_callable=AsyncMock,
    ) as upstream_handler:
        await service._connection_task_handler(config)

    upstream_handler.assert_awaited_once_with(config)
    assert config.input_audio_transcription.language_hints.language_codes == [
        "ru-KZ",
        "kk-KZ",
        "en-US",
    ]


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


@pytest.mark.asyncio
async def test_internal_speech_text_is_sent_to_gemini_without_leaking_downstream():
    service = object.__new__(OneLinkGeminiLiveLLMService)
    service._send_user_text = AsyncMock()
    service.push_frame = AsyncMock()
    frame = OneLinkInternalTextFrame(text="Скажите короткую служебную фразу.")

    await service.process_frame(frame, FrameDirection.DOWNSTREAM)

    service._send_user_text.assert_awaited_once_with(frame.text)
    service.push_frame.assert_not_awaited()


@pytest.mark.asyncio
async def test_tool_result_generation_is_bounded_by_provider_turn_complete():
    service = object.__new__(OneLinkGeminiLiveLLMService)
    service._pending_tool_result_generations = 0
    service.push_frame = AsyncMock()
    message = LiveServerMessage(server_content=LiveServerContent(turn_complete=True))

    with (
        patch.object(GeminiLiveLLMService, "_tool_result", new_callable=AsyncMock) as tool_result,
        patch.object(
            GeminiLiveLLMService,
            "_handle_msg_turn_complete",
            new_callable=AsyncMock,
        ) as turn_complete,
    ):
        await service._tool_result("call-1", "lookup", {"status": "pending"})
        await service._handle_msg_turn_complete(message)

    tool_result.assert_awaited_once_with("call-1", "lookup", {"status": "pending"})
    turn_complete.assert_awaited_once_with(message)
    assert isinstance(
        service.push_frame.await_args_list[0].args[0], OneLinkToolResultGenerationStartFrame
    )
    assert isinstance(
        service.push_frame.await_args_list[1].args[0], OneLinkToolResultGenerationEndFrame
    )
    assert service._pending_tool_result_generations == 0
