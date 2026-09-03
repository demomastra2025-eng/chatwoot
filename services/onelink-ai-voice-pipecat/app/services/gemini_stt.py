"""OneLink compatibility wrapper for Gemini 3.5 live transcription."""

from __future__ import annotations

from typing import Any

from google.genai.types import AudioTranscriptionConfig, LiveConnectConfig, Modality
from pipecat.services.google.gemini_live.stt import GeminiSTTService
from pipecat.utils.types import is_given


class OneLinkGeminiSTTService(GeminiSTTService):
    """Build the live transcription payload supported by Gemini's public API."""

    def _build_live_config(self) -> LiveConnectConfig:
        transcription_kwargs: dict[str, Any] = {
            "language_codes": self._get_language_codes(),
        }
        adaptation_phrases = self._settings.adaptation_phrases
        if is_given(adaptation_phrases) and adaptation_phrases:
            transcription_kwargs["adaptation_phrases"] = list(adaptation_phrases)

        return LiveConnectConfig(
            response_modalities=[Modality.TEXT],
            input_audio_transcription=AudioTranscriptionConfig(**transcription_kwargs),
        )
