from typing import cast
from unittest.mock import AsyncMock, MagicMock

import pytest
from pipecat.frames.frames import InputTextRawFrame, TTSSpeakFrame
from pipecat.services.cartesia.stt import CartesiaSTTService
from pipecat.services.cartesia.tts import CartesiaTTSService
from pipecat.services.elevenlabs.stt import CommitStrategy, ElevenLabsRealtimeSTTService
from pipecat.services.elevenlabs.tts import ElevenLabsTTSService
from pipecat.services.google.gemini_live.llm import GeminiLiveLLMService
from pipecat.services.openai.realtime.events import ResponseCreateEvent
from pipecat.services.openai.realtime.llm import OpenAIRealtimeLLMService
from pipecat.services.openrouter.llm import OpenRouterLLMService
from pipecat.transcriptions.language import Language

from app.api.models import RuntimeStream
from app.config import Settings
from app.pipeline.context import ToolDefinition, VoiceContext
from app.pipeline.factory import (
    GEMINI_TOOL_ANNOUNCEMENT_INSTRUCTION,
    _user_turn_strategies,
    build_pipeline,
)


def _settings(**overrides) -> Settings:
    values = {
        "internal_token": "internal-secret",
        "callback_token": "callback-secret",
        "callback_base_url": "http://rails.internal",
        "gemini_api_key": "gemini-secret",
        "openai_api_key": "openai-secret",
        "elevenlabs_api_key": "elevenlabs-secret",
        "cartesia_api_key": "cartesia-secret",
        "openrouter_api_key": "openrouter-secret",
    }
    values.update(overrides)
    return Settings.model_validate(values)


def _context(provider: str, *, model: str, voice: str) -> VoiceContext:
    return VoiceContext.model_validate(
        {
            "call_ref": f"test:{provider}",
            "account_id": 42,
            "ai": {
                "provider": provider,
                "model": model,
                "voice": voice,
                "language": "ru-KZ",
                "system_prompt": "Говори коротко.",
                "first_message": "Здравствуйте!",
            },
            "tools": [],
        }
    )


def _runtime_stream() -> RuntimeStream:
    return RuntimeStream.model_validate(
        {
            "runtime_session_id": "runtime-provider-test",
            "stream_url": "ws://media.internal/runtime-stream",
            "stream_token": "runtime-stream-secret",
        }
    )


@pytest.mark.parametrize(
    ("provider", "model", "voice", "service_class", "start_on_connect"),
    [
        (
            "gemini-live",
            "gemini-3.1-flash-live-preview",
            "sulafat",
            GeminiLiveLLMService,
            True,
        ),
        ("openai-realtime", "gpt-realtime-2", "alloy", OpenAIRealtimeLLMService, True),
        (
            "elevenlabs",
            "openai/gpt-5.4-mini",
            "Xb7hH8MSUJpSbSDYk0k2",
            OpenRouterLLMService,
            True,
        ),
        (
            "cartesia",
            "openai/gpt-5.4-mini",
            "71a7ad14-091c-4e8e-a314-022ece01c121",
            OpenRouterLLMService,
            True,
        ),
    ],
)
def test_builds_supported_provider_pipeline(
    provider, model, voice, service_class, start_on_connect
):
    assembly = build_pipeline(
        context=_context(provider, model=model, voice=voice),
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    assert assembly.provider == provider
    assert isinstance(assembly.llm, service_class)
    assert assembly.start_on_connect is start_on_connect
    if provider in {"elevenlabs", "cartesia"}:
        stt = assembly.stt
        tts = assembly.tts
        expected_stt_class = (
            CartesiaSTTService if provider == "cartesia" else ElevenLabsRealtimeSTTService
        )
        expected_tts_class = CartesiaTTSService if provider == "cartesia" else ElevenLabsTTSService
        assert isinstance(stt, expected_stt_class)
        assert isinstance(tts, expected_tts_class)
        if provider == "elevenlabs":
            assert stt._commit_strategy is CommitStrategy.VAD
        else:
            assert stt._settings.model == "ink-whisper"
        assert stt._settings.language is Language.RU
        assert tts._settings.language == "ru"
    else:
        assert assembly.stt is None
        assert assembly.tts is None
    if provider == "openai-realtime":
        llm = assembly.llm
        assert isinstance(llm, OpenAIRealtimeLLMService)
        assert llm._settings.session_properties.output_modalities == ["audio"]
        assert llm._settings.session_properties.audio.input.transcription.language == "ru"
        assert assembly.input_resampler is not None
        assert assembly.input_resampler.target_sample_rate == 24_000
        assert assembly.output_resampler is not None
        assert assembly.output_resampler.target_sample_rate == 8_000
    else:
        assert assembly.input_resampler is None
        assert assembly.output_resampler is None


@pytest.mark.parametrize("enabled", [True, False])
def test_user_turn_strategies_honor_interruption_setting(enabled):
    strategies = _user_turn_strategies(enabled)

    assert strategies.start
    assert all(strategy._enable_interruptions is enabled for strategy in strategies.start)


def test_gemini_with_tools_announces_before_formal_function_call():
    context = _context("gemini-live", model="gemini-3.1-flash-live-preview", voice="sulafat")
    context.tools.append(ToolDefinition(name="faq_lookup", timeout_ms=10_000))

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    llm = cast(GeminiLiveLLMService, assembly.llm)
    assert llm._settings.system_instruction == (
        f"Говори коротко.\n\n{GEMINI_TOOL_ANNOUNCEMENT_INSTRUCTION}"
    )


@pytest.mark.parametrize(
    ("provider", "overrides", "missing_name"),
    [
        ("gemini-live", {"gemini_api_key": ""}, "gemini_api_key"),
        ("openai-realtime", {"openai_api_key": ""}, "openai_api_key"),
        ("elevenlabs", {"elevenlabs_api_key": ""}, "elevenlabs_api_key"),
        ("elevenlabs", {"openrouter_api_key": ""}, "openrouter_api_key"),
        ("cartesia", {"cartesia_api_key": ""}, "cartesia_api_key"),
        ("cartesia", {"openrouter_api_key": ""}, "openrouter_api_key"),
    ],
)
def test_selected_provider_requires_its_credentials(provider, overrides, missing_name):
    with pytest.raises(ValueError, match=missing_name):
        _settings(**overrides).provider_credentials(provider)


def test_global_readiness_does_not_require_unselected_provider_keys():
    settings = _settings(
        gemini_api_key="",
        openai_api_key="",
        elevenlabs_api_key="",
        openrouter_api_key="",
    )

    assert settings.ready is True


@pytest.mark.asyncio
async def test_openai_exact_speech_uses_one_shot_audio_response_without_tools():
    assembly = build_pipeline(
        context=_context("openai-realtime", model="gpt-realtime-2", voice="alloy"),
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )
    llm = assembly.llm
    assert isinstance(llm, OpenAIRealtimeLLMService)
    llm.send_client_event = AsyncMock()
    assembly.activity.wait_for_turn_started_after = AsyncMock(return_value=False)

    await assembly.speak_exact("Секунду, проверю.")

    event = llm.send_client_event.await_args.args[0]
    assert isinstance(event, ResponseCreateEvent)
    assert event.response.output_modalities == ["audio"]
    assert event.response.tools == []
    assert event.response.tool_choice == "none"
    assert "Секунду, проверю." in event.response.instructions


@pytest.mark.asyncio
async def test_elevenlabs_exact_speech_queues_tts_without_context_append():
    assembly = build_pipeline(
        context=_context(
            "elevenlabs",
            model="openai/gpt-5.4-mini",
            voice="Xb7hH8MSUJpSbSDYk0k2",
        ),
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )
    tts = assembly.tts
    assert isinstance(tts, ElevenLabsTTSService)
    tts.queue_frame = AsyncMock()
    assembly.activity.wait_for_turn_started_after = AsyncMock(return_value=False)

    await assembly.speak_exact("Ещё смотрю.")

    frame = tts.queue_frame.await_args.args[0]
    assert isinstance(frame, TTSSpeakFrame)
    assert frame.text == "Ещё смотрю."
    assert frame.append_to_context is False


@pytest.mark.asyncio
async def test_gemini_exact_speech_uses_supported_realtime_text_input():
    assembly = build_pipeline(
        context=_context(
            "gemini-live",
            model="gemini-3.1-flash-live-preview",
            voice="sulafat",
        ),
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )
    assembly.worker.queue_frame = AsyncMock()
    assembly.activity.wait_for_turn_started_after = AsyncMock(return_value=False)

    await assembly.speak_exact("Вы ещё на линии?")

    frame = assembly.worker.queue_frame.await_args.args[0]
    assert isinstance(frame, InputTextRawFrame)
    assert "Вы ещё на линии?" in frame.text
