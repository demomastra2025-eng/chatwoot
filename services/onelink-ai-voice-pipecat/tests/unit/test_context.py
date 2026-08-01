import pytest
from pydantic import ValidationError

from app.pipeline.context import VoiceContext


def payload():
    return {
        "call_ref": "call-1",
        "account_id": 7,
        "conversation_id": 11,
        "contact_id": 12,
        "inbox_id": 13,
        "assistant_id": 17,
        "provider": "janus_sip",
        "direction": "inbound",
        "ai": {
            "provider": "gemini-live",
            "model": "gemini-3.1-flash-live-preview",
            "voice": "sulafat",
            "language": "ru-KZ",
            "system_prompt": "Коротко отвечай.",
            "first_message": "Здравствуйте!",
            "manager_handoff_mode": "callback",
            "callback_message": "Наш менеджер вам перезвонит.",
            "transfer_failure_mode": "end_call",
            "transfer_failure_message": "Соединить не удалось.",
            "silence_prompt_after_ms": 6000,
            "second_silence_prompt_after_ms": 14000,
            "max_silence_ms": 30000,
            "max_duration_sec": 600,
            "max_silence_sec": 30,
        },
        "recording": {"enabled": True, "source": "onelink_runtime"},
        "tools": [
            {
                "name": "create_note",
                "description": "Create note",
                "timeout_ms": 800,
                "enabled": True,
                "parameters": {
                    "type": "object",
                    "properties": {"content": {"type": "string"}},
                    "required": ["content"],
                },
            }
        ],
    }


def test_normalizes_context_without_calling_pipecat_a_provider():
    context = VoiceContext.model_validate(payload())

    assert context.ai.provider == "gemini-live"
    assert context.runtime_engine == "pipecat"
    assert context.ai.model == "gemini-3.1-flash-live-preview"
    assert context.ai.language == "ru-KZ"
    assert context.ai.api_version == "v1beta"
    assert context.ai.affective_dialog_enabled is False
    assert context.ai.proactive_audio_enabled is False
    assert context.ai.thinking_level == "minimal"
    assert context.ai.context_window_compression_enabled is True
    assert context.ai.voice_activity_profile == "balanced"
    assert context.ai.speech_start_sensitivity == "START_SENSITIVITY_LOW"
    assert context.ai.speech_end_sensitivity == "END_SENSITIVITY_HIGH"
    assert context.ai.vad_confidence == 0.75
    assert context.ai.vad_min_volume == 0.6
    assert context.ai.manager_handoff_mode == "callback"
    assert context.ai.callback_message == "Наш менеджер вам перезвонит."
    assert context.ai.transfer_failure_mode == "end_call"
    assert context.ai.silence_prompt_after_ms == 6000
    assert context.ai.second_silence_prompt_after_ms == 14000
    assert context.ai.max_silence_ms == 30000
    assert context.tools[0].name == "create_note"
    assert context.correlation.runtime_session_id
    assert context.correlation.payload()["assistant_id"] == 17


def test_context_accepts_native_gemini_affective_dialog_setting():
    raw = payload()
    raw["ai"]["affective_dialog_enabled"] = True

    context = VoiceContext.model_validate(raw)

    assert context.ai.affective_dialog_enabled is True


def test_context_accepts_native_gemini_proactive_audio_setting():
    raw = payload()
    raw["ai"]["proactive_audio_enabled"] = True

    context = VoiceContext.model_validate(raw)

    assert context.ai.proactive_audio_enabled is True


def test_context_accepts_gemini_auto_language_and_thinking_level():
    raw = payload()
    raw["ai"].update(language="auto", thinking_level="high")

    context = VoiceContext.model_validate(raw)

    assert context.ai.language == "auto"
    assert context.ai.thinking_level == "high"


def test_context_preserves_unknown_forward_compatible_keys():
    raw = payload()
    raw["captain"] = {"assistant_id": 99, "new_contract_key": "kept"}

    context = VoiceContext.model_validate(raw)

    assert context.raw["captain"]["new_contract_key"] == "kept"


def test_context_rejects_framework_name_as_provider():
    raw = payload()
    raw["ai"]["provider"] = "pipecat"

    with pytest.raises(ValidationError):
        VoiceContext.model_validate(raw)


def test_context_accepts_cartesia_cascade_provider():
    raw = payload()
    raw["ai"].update(
        provider="cartesia",
        model="openai/gpt-5.4-mini",
        voice="71a7ad14-091c-4e8e-a314-022ece01c121",
    )

    context = VoiceContext.model_validate(raw)

    assert context.ai.provider == "cartesia"


def test_context_accepts_zero_foreground_wait_from_rails_contract():
    raw = payload()
    raw["ai"]["tool_foreground_wait_ms"] = 0

    context = VoiceContext.model_validate(raw)

    assert context.ai.tool_foreground_wait_ms == 0


def test_context_accepts_explicit_zero_silence_thresholds_from_rails_contract():
    raw = payload()
    raw["ai"].update(
        silence_prompt_after_ms=0,
        second_silence_prompt_after_ms=0,
        max_silence_ms=0,
    )

    context = VoiceContext.model_validate(raw)

    assert context.ai.silence_prompt_after_ms == 0
    assert context.ai.second_silence_prompt_after_ms == 0
    assert context.ai.max_silence_ms == 0


def test_context_rejects_disabled_tool_and_invalid_duration():
    raw = payload()
    raw["tools"][0]["enabled"] = False
    raw["ai"]["max_duration_sec"] = 0

    with pytest.raises(ValidationError):
        VoiceContext.model_validate(raw)
