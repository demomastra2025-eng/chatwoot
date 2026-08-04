import asyncio
from typing import Literal, cast
from unittest.mock import AsyncMock, MagicMock

import pytest
from pipecat.frames.frames import (
    InputTextRawFrame,
    InterruptionWorkerFrame,
    LLMRunFrame,
    TTSSpeakFrame,
)
from pipecat.services.cartesia.stt import CartesiaSTTService
from pipecat.services.cartesia.tts import CartesiaTTSService
from pipecat.services.elevenlabs.stt import CommitStrategy
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
    VOICE_LANGUAGE_INSTRUCTION,
    VOICE_LIST_RESULT_INSTRUCTION,
    _build_tools,
    _provider_system_prompt,
    _user_turn_strategies,
    build_pipeline,
)
from app.pipeline.processors import ModelLifecycleProcessor
from app.services.elevenlabs_realtime_stt import OneLinkElevenLabsRealtimeSTTService
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
    expected_greeting = "Здравствуйте!" if provider in {"elevenlabs", "cartesia", "fish"} else None
    assert assembly.initial_greeting == expected_greeting
    if provider in {"elevenlabs", "cartesia", "fish"}:
        stt = assembly.stt
        tts = assembly.tts
        expected_stt_class = (
            CartesiaSTTService if provider == "cartesia" else OneLinkElevenLabsRealtimeSTTService
        )
        expected_tts_class = {
            "cartesia": CartesiaTTSService,
            "elevenlabs": ElevenLabsTTSService,
            "fish": OneLinkFishAudioTTSService,
        }[provider]
        assert isinstance(stt, expected_stt_class)
        assert isinstance(tts, expected_tts_class)
        if provider == "fish":
            assert tts._stop_frame_timeout_s == 1.5
        if provider in {"elevenlabs", "fish"}:
            assert stt._commit_strategy is CommitStrategy.VAD
            assert stt._settings.vad_silence_threshold_secs == 0.3
            assert stt._settings.vad_threshold == 0.4
            assert stt._settings.min_speech_duration_ms == 100
            assert stt._settings.min_silence_duration_ms == 100
            assert stt._filter_background_audio is True
        else:
            assert stt._settings.model == "ink-whisper"
        assert stt._settings.language is Language.RU
        assert tts._settings.language == "ru"
        llm = cast(OpenRouterLLMService, assembly.llm)
        assert llm._settings.extra == {
            "extra_body": {
                "reasoning": {"effort": "none", "exclude": True},
                "provider": {
                    "sort": "latency",
                    "allow_fallbacks": True,
                    "require_parameters": True,
                    "data_collection": "deny",
                    "preferred_max_latency": {"p90": 1.0, "p99": 2.5},
                },
            }
        }
        request_params = llm.build_chat_completion_params({"messages": []})
        assert llm._run_in_parallel is True
        assert request_params["extra_body"]["provider"]["data_collection"] == "deny"
        assert request_params["extra_body"]["reasoning"] == {
            "effort": "none",
            "exclude": True,
        }
        assert "parallel_tool_calls" not in request_params["extra_body"]
        if model.startswith("openai/gpt-5"):
            assert str(llm._settings.temperature) == "NOT_GIVEN"
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


def test_non_gpt_openrouter_model_does_not_receive_gpt_reasoning_contract():
    context = _context(
        "fish",
        model="anthropic/claude-sonnet-4.5",
        voice="fish-voice-ref",
    )
    context.ai.temperature = 0.3

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    llm = cast(OpenRouterLLMService, assembly.llm)
    assert "reasoning" not in llm._settings.extra["extra_body"]
    assert llm._settings.temperature == 0.3
    assert "parallel_tool_calls" not in llm._settings.extra["extra_body"]


def test_luna_openrouter_request_keeps_strict_routing_without_parallel_filter():
    assembly = build_pipeline(
        context=_context(
            "fish",
            model="openai/gpt-5.6-luna",
            voice="fish-voice-ref",
        ),
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    llm = cast(OpenRouterLLMService, assembly.llm)
    request_params = llm.build_chat_completion_params({"messages": []})
    extra_body = request_params["extra_body"]

    assert extra_body["provider"]["require_parameters"] is True
    assert extra_body["reasoning"] == {"effort": "none", "exclude": True}
    assert "parallel_tool_calls" not in extra_body


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
    context = _context("gemini-live", model="gemini-3.1-flash-live-preview", voice="sulafat")
    context.ai.interruptions_enabled = enabled
    strategies = _user_turn_strategies(context.ai)

    assert strategies.start
    assert all(strategy._enable_interruptions is enabled for strategy in strategies.start)
    assert len(strategies.stop) == 1


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
        ("gemini-2.5-flash-native-audio-preview-12-2025", True, "v1beta", True, "v1beta"),
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


@pytest.mark.parametrize("provider", ["elevenlabs", "fish"])
def test_cascade_auto_language_uses_configured_primary_and_secondary_hints(provider):
    context = _context(provider, model="openai/gpt-5.4-mini", voice="voice-ref")
    context.ai.language = "auto"
    context.ai.input_language_priorities = ["ru-KZ", "kk-KZ", "en-US"]

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    stt = cast(OneLinkElevenLabsRealtimeSTTService, assembly.stt)
    assert stt._settings.language is Language.RU
    assert stt._secondary_languages == ["kk", "en"]


@pytest.mark.parametrize(
    ("model", "requested_enabled", "expected_enabled", "expected_api_version"),
    [
        ("gemini-3.1-flash-live-preview", True, False, "v1beta"),
        ("gemini-2.5-flash-native-audio-preview-12-2025", True, True, "v1beta"),
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
        f"Говори коротко.\n\n{VOICE_LANGUAGE_INSTRUCTION}\n\n"
        f"{GEMINI_TOOL_ANNOUNCEMENT_INSTRUCTION}\n\n{VOICE_LIST_RESULT_INSTRUCTION}"
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
    assert "вызови инструмент в этом же ходе" in prompt
    assert "выбор необязательного названия" in prompt
    assert "Фактический источник: телефонный звонок" in prompt
    assert GEMINI_TOOL_ANNOUNCEMENT_INSTRUCTION in prompt
    assert VOICE_LIST_RESULT_INSTRUCTION in prompt


def test_voice_crm_source_preserves_whatsapp_call_context():
    context = _context("openai-realtime", model="gpt-realtime-2", voice="alloy")
    context.provider = "whatsapp_cloud"
    context.call_ref = "whatsapp:test-call"
    context.tools.append(ToolDefinition(name="create_deal"))

    prompt = _provider_system_prompt(context)

    assert "Фактический источник: голосовой звонок WhatsApp" in prompt
    assert GEMINI_TOOL_ANNOUNCEMENT_INSTRUCTION in prompt


@pytest.mark.parametrize(
    ("provider", "model", "voice"),
    [
        ("gemini-live", "gemini-3.1-flash-live-preview", "sulafat"),
        ("openai-realtime", "gpt-realtime-2", "alloy"),
        ("fish", "openai/gpt-5.4-mini", "fish-voice-ref"),
    ],
)
def test_caller_end_call_command_is_wired_for_every_pipeline(provider, model, voice):
    context = _context(provider, model=model, voice=voice)
    context.tools.append(ToolDefinition(name="end_call", timeout_ms=1_000))

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    assert assembly.caller_command is not None


def test_cascaded_caller_command_observes_transcript_before_user_aggregator():
    context = _context("fish", model="openai/gpt-5.4-mini", voice="fish-voice-ref")
    context.tools.append(ToolDefinition(name="end_call", timeout_ms=1_000))

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    processors = assembly.worker._pipeline._processors[1]._processors
    caller_index = processors.index(assembly.caller_command)
    user_aggregator_index = next(
        index
        for index, processor in enumerate(processors)
        if type(processor).__name__ == "LLMUserAggregator"
    )

    assert processors.index(assembly.stt) < caller_index < user_aggregator_index


def test_cascaded_model_lifecycle_is_between_llm_and_tts():
    assembly = build_pipeline(
        context=_context(
            "fish",
            model="openai/gpt-5.4-mini",
            voice="fish-voice-ref",
        ),
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    processors = assembly.worker._pipeline._processors[1]._processors
    lifecycle_index = next(
        index
        for index, processor in enumerate(processors)
        if isinstance(processor, ModelLifecycleProcessor)
    )

    assert processors.index(assembly.llm) < lifecycle_index < processors.index(assembly.tts)


def test_openrouter_receives_native_same_turn_tool_instruction():
    context = _context("fish", model="openai/gpt-5.4-mini", voice="fish-voice-ref")
    context.tools.append(ToolDefinition(name="faq_lookup"))

    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )

    llm = cast(OpenRouterLLMService, assembly.llm)
    assert GEMINI_TOOL_ANNOUNCEMENT_INSTRUCTION in llm._settings.system_instruction
    assert VOICE_LANGUAGE_INSTRUCTION in llm._settings.system_instruction


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


def test_cascaded_tool_survives_interruption_and_has_bounded_runtime():
    context = _context("fish", model="openai/gpt-5.4-mini", voice="voice-ref")
    context.tools.append(ToolDefinition(name="faq_lookup", timeout_ms=5_000))

    tool = _build_tools(context, MagicMock()).standard_tools[0]

    assert tool.handler is not None
    assert tool.handler._pipecat_cancel_on_interruption is False
    assert tool.handler._pipecat_timeout_secs == 6.0


def test_terminal_tool_timeout_covers_farewell_and_backend_callback():
    context = _context("fish", model="openai/gpt-5.4-mini", voice="voice-ref")
    context.tools.append(ToolDefinition(name="end_call", timeout_ms=1_000))

    tool = _build_tools(context, MagicMock()).standard_tools[0]

    assert tool.handler is not None
    assert tool.handler._pipecat_timeout_secs == 7.0


def test_gemini_3_tool_keeps_supported_blocking_contract():
    context = _context("gemini-live", model="gemini-3.1-flash-live-preview", voice="sulafat")
    context.tools.append(ToolDefinition(name="faq_lookup", timeout_ms=5_000))

    tool = _build_tools(context, MagicMock()).standard_tools[0]

    assert tool.handler is not None
    assert tool.handler._pipecat_cancel_on_interruption is True
    assert tool.handler._pipecat_timeout_secs == 6.0


def test_gemini_25_tool_uses_native_non_blocking_contract():
    context = _context(
        "gemini-live",
        model="gemini-2.5-flash-native-audio-preview-12-2025",
        voice="sulafat",
    )
    context.tools.append(ToolDefinition(name="faq_lookup", timeout_ms=5_000))

    tool = _build_tools(context, MagicMock()).standard_tools[0]

    assert tool.handler is not None
    assert tool.handler._pipecat_cancel_on_interruption is False
    assert tool.handler._pipecat_timeout_secs == 6.0


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
    assembly.activity.wait_for_turn_completed_after = AsyncMock(return_value=False)

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
    assert isinstance(assembly.tts, ElevenLabsTTSService)
    assembly.worker.queue_frame = AsyncMock()
    assembly.activity.wait_for_turn_completed_after = AsyncMock(return_value=False)

    await assembly.speak_exact("Ещё смотрю.")

    frame = assembly.worker.queue_frame.await_args.args[0]
    assert isinstance(frame, TTSSpeakFrame)
    assert frame.text == "Ещё смотрю."
    assert frame.append_to_context is False


@pytest.mark.asyncio
async def test_completed_cascaded_direct_speech_is_persisted_without_blocking_tts():
    state = MagicMock()
    state.add_transcript = AsyncMock()
    state.flush_transcript = AsyncMock(return_value=True)
    background_tasks = []

    def spawn(work):
        task = asyncio.create_task(work)
        background_tasks.append(task)
        return task

    state.spawn.side_effect = spawn
    assembly = build_pipeline(
        context=_context(
            "fish",
            model="openai/gpt-5.4-mini",
            voice="fish-voice-ref",
        ),
        state=state,
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )
    assembly.worker.queue_frame = AsyncMock()

    async def complete_direct_turn(*_args, **_kwargs):
        assembly.activity.turns_started += 1
        assembly.activity.turns_completed += 1
        return True

    assembly.activity.wait_for_turn_completed_after = AsyncMock(
        side_effect=complete_direct_turn
    )

    assert await assembly.speak_result("Акуна матата") is True
    await asyncio.gather(*background_tasks)

    state.add_transcript.assert_awaited_once_with(
        "ai",
        "Акуна матата",
        final=True,
        deduplicate_recent=True,
    )
    state.flush_transcript.assert_awaited_once()


@pytest.mark.asyncio
async def test_interrupted_cascaded_direct_speech_is_not_persisted():
    state = MagicMock()
    state.add_transcript = AsyncMock()
    assembly = build_pipeline(
        context=_context(
            "fish",
            model="openai/gpt-5.4-mini",
            voice="fish-voice-ref",
        ),
        state=state,
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )
    assembly.worker.queue_frame = AsyncMock()

    async def complete_after_interruption(*_args, **_kwargs):
        assembly.activity.turns_started += 1
        assembly.activity.turns_completed += 1
        assembly.activity.interruptions += 1
        return True

    assembly.activity.wait_for_turn_completed_after = AsyncMock(
        side_effect=complete_after_interruption
    )

    assert await assembly.speak_exact("Секунду, проверю") is False
    state.add_transcript.assert_not_awaited()


@pytest.mark.asyncio
async def test_external_interruption_uses_worker_broadcast_frame():
    assembly = build_pipeline(
        context=_context(
            "fish",
            model="openai/gpt-5.4-mini",
            voice="fish-voice-ref",
        ),
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )
    assembly.worker.queue_frame = AsyncMock()

    await assembly.interrupt_generation()

    frame = assembly.worker.queue_frame.await_args.args[0]
    assert isinstance(frame, InterruptionWorkerFrame)


@pytest.mark.asyncio
async def test_cascaded_provider_starts_with_exact_tts_greeting_without_llm():
    state = MagicMock()
    state.add_transcript = AsyncMock()
    state.flush_transcript = AsyncMock(return_value=True)
    background_tasks = []

    def spawn(work):
        task = asyncio.create_task(work)
        background_tasks.append(task)
        return task

    state.spawn.side_effect = spawn
    assembly = build_pipeline(
        context=_context(
            "fish",
            model="openai/gpt-5.4-mini",
            voice="fish-voice-ref",
        ),
        state=state,
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )
    assert isinstance(assembly.tts, OneLinkFishAudioTTSService)
    assembly.worker.queue_frame = AsyncMock()

    async def complete_greeting_turn(*_args, **_kwargs):
        assembly.activity.turns_started += 1
        assembly.activity.turns_completed += 1
        return True

    assembly.activity.wait_for_turn_completed_after = AsyncMock(
        side_effect=complete_greeting_turn
    )

    await assembly.start_conversation()
    while any(not task.done() for task in background_tasks):
        await asyncio.gather(*list(background_tasks))

    frame = assembly.worker.queue_frame.await_args.args[0]
    assert isinstance(frame, TTSSpeakFrame)
    assert frame.text == "Здравствуйте!"
    assert frame.append_to_context is False
    assembly.worker.queue_frame.assert_awaited_once()
    state.add_transcript.assert_awaited_once_with(
        "ai",
        "Здравствуйте!",
        final=True,
        deduplicate_recent=True,
    )
    state.flush_transcript.assert_awaited_once()


@pytest.mark.asyncio
async def test_cascaded_provider_without_greeting_starts_llm_normally():
    context = _context(
        "fish",
        model="openai/gpt-5.4-mini",
        voice="fish-voice-ref",
    )
    context.ai.first_message = ""
    assembly = build_pipeline(
        context=context,
        state=MagicMock(),
        recorder=None,
        runtime_stream=_runtime_stream(),
        settings=_settings(),
    )
    assembly.worker.queue_frame = AsyncMock()

    await assembly.start_conversation()

    frame = assembly.worker.queue_frame.await_args.args[0]
    assert isinstance(frame, LLMRunFrame)


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
    assembly.activity.wait_for_turn_completed_after = AsyncMock(return_value=False)

    await assembly.speak_exact("Вы ещё на линии?")

    frame = assembly.worker.queue_frame.await_args.args[0]
    assert isinstance(frame, InputTextRawFrame)
    assert "Вы ещё на линии?" in frame.text
