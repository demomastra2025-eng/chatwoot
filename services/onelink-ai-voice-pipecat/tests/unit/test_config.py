import pytest
from pydantic import ValidationError

from app.config import Settings


def valid_settings(**overrides):
    values = {
        "internal_token": "voice-secret",
        "callback_token": "callback-secret",
        "gemini_api_key": "gemini-secret",
        "openai_api_key": "openai-secret",
        "elevenlabs_api_key": "elevenlabs-secret",
        "cartesia_api_key": "cartesia-secret",
        "openrouter_api_key": "openrouter-secret",
        "fish_api_key": "fish-secret",
        "callback_base_url": "http://rails.internal",
    }
    values.update(overrides)
    return Settings.model_validate(values)


def test_missing_internal_token_is_not_ready():
    settings = valid_settings(internal_token="")

    assert settings.ready is False
    assert settings.readiness_errors == ("internal_token_required",)


def test_missing_callback_url_is_not_ready():
    settings = valid_settings(callback_base_url=None)

    assert settings.ready is False
    assert settings.readiness_errors == ("callback_base_url_required",)


def test_invalid_callback_url_is_rejected():
    with pytest.raises(ValidationError):
        valid_settings(callback_base_url="not-a-url")


def test_unsupported_provider_is_rejected():
    with pytest.raises(ValidationError):
        valid_settings(realtime_provider="pipecat")


@pytest.mark.parametrize("value", [0, -1, 1001])
def test_invalid_session_limits_are_rejected(value):
    with pytest.raises(ValidationError):
        valid_settings(max_concurrent_sessions=value)


def test_settings_repr_does_not_expose_secrets():
    settings = valid_settings()

    serialized = repr(settings)
    assert "voice-secret" not in serialized
    assert "callback-secret" not in serialized
    assert "gemini-secret" not in serialized
    assert "openai-secret" not in serialized
    assert "elevenlabs-secret" not in serialized
    assert "cartesia-secret" not in serialized
    assert "openrouter-secret" not in serialized
    assert "fish-secret" not in serialized


def test_from_env_prefers_pipecat_provider_key_aliases(monkeypatch):
    aliases = {
        "ONELINK_AI_VOICE_PIPECAT_GOOGLE_API_KEY": "prefixed-google",
        "ONELINK_AI_VOICE_PIPECAT_OPENAI_API_KEY": "prefixed-openai",
        "ONELINK_AI_VOICE_PIPECAT_ELEVENLABS_API_KEY": "prefixed-elevenlabs",
        "ONELINK_AI_VOICE_PIPECAT_CARTESIA_API_KEY": "prefixed-cartesia",
        "ONELINK_AI_VOICE_PIPECAT_OPENROUTER_API_KEY": "prefixed-openrouter",
        "ONELINK_AI_VOICE_PIPECAT_FISH_API_KEY": "prefixed-fish",
    }
    for name, value in aliases.items():
        monkeypatch.setenv(name, value)

    settings = Settings.from_env()

    assert settings.gemini_api_key.get_secret_value() == "prefixed-google"
    assert settings.openai_api_key.get_secret_value() == "prefixed-openai"
    assert settings.elevenlabs_api_key.get_secret_value() == "prefixed-elevenlabs"
    assert settings.cartesia_api_key.get_secret_value() == "prefixed-cartesia"
    assert settings.openrouter_api_key.get_secret_value() == "prefixed-openrouter"
    assert settings.fish_api_key.get_secret_value() == "prefixed-fish"


def test_cartesia_provider_does_not_require_elevenlabs_credentials():
    credentials = valid_settings(elevenlabs_api_key="").provider_credentials("cartesia")

    assert credentials == {
        "cartesia_api_key": "cartesia-secret",
        "openrouter_api_key": "openrouter-secret",
    }


def test_fish_asr_provider_requires_only_fish_and_openrouter_credentials():
    credentials = valid_settings(elevenlabs_api_key="").provider_credentials(
        "fish", stt_provider="fish"
    )

    assert credentials == {
        "fish_api_key": "fish-secret",
        "openrouter_api_key": "openrouter-secret",
    }


def test_fish_elevenlabs_provider_requires_all_three_credentials():
    credentials = valid_settings().provider_credentials("fish", stt_provider="elevenlabs")

    assert credentials == {
        "fish_api_key": "fish-secret",
        "openrouter_api_key": "openrouter-secret",
        "elevenlabs_api_key": "elevenlabs-secret",
    }


def test_fish_provider_rejects_unsupported_stt_provider():
    with pytest.raises(ValueError, match="unsupported Fish STT provider"):
        valid_settings().provider_credentials("fish", stt_provider="unknown")
