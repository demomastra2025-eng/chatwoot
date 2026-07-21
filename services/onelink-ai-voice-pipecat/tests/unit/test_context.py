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
        "provider": "janus_sip",
        "direction": "inbound",
        "ai": {
            "provider": "gemini-live",
            "model": "gemini-3.1-flash-live-preview",
            "voice": "sulafat",
            "language": "ru-KZ",
            "system_prompt": "Коротко отвечай.",
            "first_message": "Здравствуйте!",
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
    assert context.tools[0].name == "create_note"
    assert context.correlation.runtime_session_id


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


def test_context_rejects_disabled_tool_and_invalid_duration():
    raw = payload()
    raw["tools"][0]["enabled"] = False
    raw["ai"]["max_duration_sec"] = 0

    with pytest.raises(ValidationError):
        VoiceContext.model_validate(raw)
