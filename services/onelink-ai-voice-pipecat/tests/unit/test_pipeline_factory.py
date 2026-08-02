from typing import Literal, cast
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
    CRM_DATA_INTEGRITY_INSTRUCTION,
    GEMINI_TOOL_ANNOUNCEMENT_INSTRUCTION,
    _build_tools,
    _provider_system_prompt,
    _user_turn_strategies,
    build_pipeline,
)
from app.services.fish_asr import FishAudioASRService
from app.services.fish_tts import OneLinkFishAudioTTSService


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
        "fish_api_key": "fish-secret",
    }
    values.update(overrides)
    return Settings.model_validate(values)


def _context(
    provider: str, *, model: str, voice: str, stt_provider: str = "elevenlabs"
) -> VoiceContext:
    return VoiceContext.model_validate(
        {
            "call_ref": f"test:{provider}",
            "account_id": 42,
            "ai": {
                "provider": provider,
                "stt_provider": stt_provider,
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
        (
            "fish",
            "openai/gpt-5.4-mini",
            "fish-voice-ref",
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
    if provider in {"elevenlabs", "cartesia", "fish"}:
        stt = assembly.stt
        tts = assembly.tts
        expected_stt_class = (
            CartesiaSTTService if provider == "cartesia" else ElevenLabsRealtimeSTTService
        )
        expected_tts_class = {
            "cartesia": CartesiaTTSService,
            "elevenlabs": ElevenLabsTTSService,
            "fish": OneLinkFishAudioTTSService,
        }[provider]
        assert isinstance(stt, expected_stt_class)
        assert isinstance(tts, expected_tts_class)
        if provider in {"elevenlabs", "fish"}:
            expected_strategy = CommitStrategy.MANUAL if provider == "fish" else CommitStrategy.VAD
            assert stt._commit_strategy is expected_strategy
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
    if provider == "gemini-live":
        llm = cast(GeminiLiveLLMService, assembly.llm)
        assert llm._client._api_client._http_options.api_version == "v1beta"


def test_builds_fish_batch_asr_pipeline():
    assembly = build_pipeline(
        context=_context(
            "fish",
            model="openai/gpt-5.4-mini",
            voice="fish-voice-ref",
            stt_provider="fish",
        ),
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(elevenlabs_api_key=""),
    )

    assert isinstance(assembly.stt, FishAudioASRService)
    assert assembly.stt._init_sample_rate == 16_000
    assert isinstance(assembly.llm, OpenRouterLLMService)
    assert isinstance(assembly.tts, OneLinkFishAudioTTSService)
    assert assembly.tts._settings.model == "s2.1-pro-free"
    assert assembly.tts._settings.voice == "fish-voice-ref"


def test_core_pipeline_settings_are_transport_neutral_between_janus_and_preview():
    context = _context("gemini-live", model="gemini-3.1-flash-live-preview", voice="sulafat")
    context.ai.vad_confidence = 0.82
    context.ai.vad_min_volume = 0.68
    settings = _settings()

    janus = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=settings,
    )
    preview = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=None,
        settings=settings,
        transport_override=janus.transport,
    )

    assert preview.transport is janus.transport
    assert preview.provider == janus.provider == "gemini-live"
    assert type(preview.llm) is type(janus.llm)
    assert preview.start_on_connect is janus.start_on_connect
    assert preview.vad.params == janus.vad.params


@pytest.mark.parametrize("enabled", [True, False])
def test_user_turn_strategies_honor_interruption_setting(enabled):
    strategies = _user_turn_strategies(enabled)

    assert strategies.start
    assert all(strategy._enable_interruptions is enabled for strategy in strategies.start)


def test_gemini_uses_local_vad_as_single_turn_owner():
    context = _context("gemini-live", model="gemini-3.1-flash-live-preview", voice="sulafat")
    context.ai.prefix_padding_ms = 240
    context.ai.silence_duration_ms = 650
    context.ai.vad_confidence = 0.85
    context.ai.vad_min_volume = 0.7

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    llm = cast(GeminiLiveLLMService, assembly.llm)
    vad = llm._settings.vad
    assert vad.disabled is True
    assert vad.start_sensitivity is None
    assert vad.end_sensitivity is None
    assert vad.prefix_padding_ms is None
    assert vad.silence_duration_ms is None
    assert assembly.vad.params.confidence == 0.85
    assert assembly.vad.params.start_secs == 0.24
    assert assembly.vad.params.stop_secs == 0.65
    assert assembly.vad.params.min_volume == 0.7


def test_gemini_disables_native_vad_when_interruptions_are_disabled():
    context = _context("gemini-live", model="gemini-3.1-flash-live-preview", voice="sulafat")
    context.ai.interruptions_enabled = False

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    llm = cast(GeminiLiveLLMService, assembly.llm)
    vad = llm._settings.vad
    assert vad.disabled is True
    assert vad.start_sensitivity is None
    assert vad.end_sensitivity is None
    assert vad.prefix_padding_ms is None
    assert vad.silence_duration_ms is None


@pytest.mark.parametrize(
    ("model", "requested_enabled", "input_api_version", "expected_enabled", "expected_api_version"),
    [
        ("gemini-2.5-flash-native-audio-preview-12-2025", True, "v1beta", True, "v1alpha"),
        ("gemini-2.5-flash-native-audio-preview-12-2025", False, "v1alpha", False, "v1beta"),
        ("gemini-3.1-flash-live-preview", True, "v1beta", False, "v1beta"),
        ("gemini-3.1-flash-live-preview", True, "v1alpha", False, "v1beta"),
    ],
)
def test_gemini_gates_native_affective_dialog_by_model(
    model: str,
    requested_enabled: bool,
    input_api_version: Literal["v1alpha", "v1beta"],
    expected_enabled: bool,
    expected_api_version: str,
):
    context = _context("gemini-live", model=model, voice="sulafat")
    context.ai.affective_dialog_enabled = requested_enabled
    context.ai.api_version = input_api_version

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    llm = cast(GeminiLiveLLMService, assembly.llm)
    assert llm._settings.enable_affective_dialog is expected_enabled
    assert llm._client._api_client._http_options.api_version == expected_api_version


def test_gemini_auto_language_omits_the_google_language_code():
    context = _context("gemini-live", model="gemini-3.1-flash-live-preview", voice="sulafat")
    context.ai.language = "auto"

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    llm = cast(GeminiLiveLLMService, assembly.llm)
    assert llm._settings.language is None


def test_gemini_auto_language_falls_back_for_legacy_model():
    context = _context("gemini-live", model="gemini-2.0-flash-live-001", voice="puck")
    context.ai.language = "auto"

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    llm = cast(GeminiLiveLLMService, assembly.llm)
    assert llm._settings.language == "ru-KZ"


@pytest.mark.parametrize(
    ("model", "requested_enabled", "expected_enabled", "expected_api_version"),
    [
        ("gemini-3.1-flash-live-preview", True, True, "v1alpha"),
        ("gemini-2.5-flash-native-audio-preview-12-2025", True, True, "v1alpha"),
        ("gemini-2.0-flash-live-001", True, False, "v1beta"),
        ("gemini-3.1-flash-live-preview", False, False, "v1beta"),
    ],
)
def test_gemini_gates_proactive_audio_and_selects_required_api_version(
    model: str,
    requested_enabled: bool,
    expected_enabled: bool,
    expected_api_version: str,
):
    context = _context("gemini-live", model=model, voice="sulafat")
    context.ai.proactive_audio_enabled = requested_enabled

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    llm = cast(GeminiLiveLLMService, assembly.llm)
    assert bool(llm._settings.proactivity) is expected_enabled
    if expected_enabled:
        assert llm._settings.proactivity.proactive_audio is True
    assert llm._client._api_client._http_options.api_version == expected_api_version


def test_gemini_31_uses_thinking_and_context_compression_settings():
    context = _context("gemini-live", model="gemini-3.1-flash-live-preview", voice="sulafat")
    context.ai.thinking_level = "low"
    context.ai.context_window_compression_enabled = False

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    llm = cast(GeminiLiveLLMService, assembly.llm)
    assert llm._settings.thinking.thinking_level.value == "LOW"
    assert llm._settings.context_window_compression.enabled is False


def test_gemini_25_does_not_receive_unsupported_thinking_level():
    context = _context(
        "gemini-live",
        model="gemini-2.5-flash-native-audio-preview-12-2025",
        voice="sulafat",
    )
    context.ai.thinking_level = "high"

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    llm = cast(GeminiLiveLLMService, assembly.llm)
    assert llm._settings.thinking is None


def test_gemini_sensitivity_values_do_not_enable_server_vad():
    context = _context("gemini-live", model="gemini-3.1-flash-live-preview", voice="sulafat")
    context.ai.speech_start_sensitivity = "UNKNOWN_START"
    context.ai.speech_end_sensitivity = "UNKNOWN_END"

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    llm = cast(GeminiLiveLLMService, assembly.llm)
    vad = llm._settings.vad
    assert vad.disabled is True
    assert vad.start_sensitivity is None
    assert vad.end_sensitivity is None


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


def test_voice_crm_mutations_require_confirmed_phone_and_actual_call_source():
    context = _context("gemini-live", model="gemini-3.1-flash-live-preview", voice="sulafat")
    context.provider = "asterisk_analog"
    context.call_ref = "asterisk_analog:test-call"
    context.tools.extend(
        [ToolDefinition(name="create_deal"), ToolDefinition(name="add_contact_note")]
    )

    prompt = _provider_system_prompt(context)

    assert CRM_DATA_INTEGRITY_INSTRUCTION.format(source="телефонный звонок") in prompt
    assert "повтори весь номер клиенту" in prompt
    assert "Фактический источник: телефонный звонок" in prompt
    assert GEMINI_TOOL_ANNOUNCEMENT_INSTRUCTION in prompt


def test_voice_crm_source_preserves_whatsapp_call_context():
    context = _context("openai-realtime", model="gpt-realtime-2", voice="alloy")
    context.provider = "whatsapp_cloud"
    context.call_ref = "whatsapp:test-call"
    context.tools.append(ToolDefinition(name="create_deal"))

    prompt = _provider_system_prompt(context)

    assert "Фактический источник: голосовой звонок WhatsApp" in prompt
    assert GEMINI_TOOL_ANNOUNCEMENT_INSTRUCTION not in prompt


def test_invalid_tool_schema_is_dropped_before_provider_setup():
    context = _context("gemini-live", model="gemini-3.1-flash-live-preview", voice="sulafat")
    context.tools.extend(
        [
            ToolDefinition(
                name="broken_array_tool",
                parameters={
                    "type": "object",
                    "properties": {"reasons": {"type": "array"}},
                },
            ),
            ToolDefinition(name="faq_lookup"),
        ]
    )

    tools = _build_tools(context, MagicMock())

    assert [tool.name for tool in tools.standard_tools] == ["faq_lookup"]


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
