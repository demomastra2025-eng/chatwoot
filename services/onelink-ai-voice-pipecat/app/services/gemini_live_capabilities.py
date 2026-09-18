"""Model-specific Gemini Live capabilities used by the OneLink runtime."""

from __future__ import annotations

DEFAULT_GEMINI_LIVE_MODEL = "gemini-3.8-live"

GEMINI_AFFECTIVE_DIALOG_MODELS = frozenset({"gemini-2.5-flash-native-audio-preview-12-2025"})
GEMINI_AUTO_LANGUAGE_MODELS = frozenset(
    {
        DEFAULT_GEMINI_LIVE_MODEL,
        "gemini-3.1-flash-live-preview",
        "gemini-2.5-flash-native-audio-preview-12-2025",
    }
)
GEMINI_BLOCKING_TOOL_MODELS = frozenset({"gemini-3.1-flash-live-preview"})
GEMINI_PROACTIVE_AUDIO_CONFIG_MODELS = GEMINI_AFFECTIVE_DIALOG_MODELS
GEMINI_THINKING_LEVEL_MODELS = frozenset({"gemini-3.1-flash-live-preview"})


def supports_native_async_tools(model: str) -> bool:
    """Return whether Gemini accepts NON_BLOCKING function declarations."""

    return model.strip().lower() not in GEMINI_BLOCKING_TOOL_MODELS


def requires_clear_audio_on_interrupt(model: str) -> bool:
    """Gemini 3.8 requires queued audio to be cleared after an interruption."""

    return model.strip().lower() == DEFAULT_GEMINI_LIVE_MODEL
