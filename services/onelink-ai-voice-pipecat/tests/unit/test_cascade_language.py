from unittest.mock import AsyncMock, MagicMock

import pytest
from pipecat.frames.frames import (
    InterimTranscriptionFrame,
    LLMUpdateSettingsFrame,
    TranscriptionFrame,
    TTSUpdateSettingsFrame,
)
from pipecat.processors.frame_processor import FrameDirection
from pipecat.transcriptions.language import Language

from app.pipeline.language import CascadeLanguageState, CascadeLanguageStateProcessor


def _auto_state() -> CascadeLanguageState:
    return CascadeLanguageState.from_settings(
        "auto",
        ["kk-KZ", "ru-KZ", "en-US"],
    )


def _transcript(
    text: str,
    language: Language | str | None,
) -> TranscriptionFrame:
    return TranscriptionFrame(
        text=text,
        user_id="caller",
        timestamp="2026-09-05T00:00:00Z",
        language=language,
        finalized=True,
    )


def test_auto_language_starts_with_primary_priority_and_concrete_lock():
    state = _auto_state()

    instruction = state.system_instruction("Базовая инструкция.")

    assert state.active_code == "kk-KZ"
    assert state.tts_language is Language.KK
    assert "Активный язык ответа: казахском языке (kk-KZ)" in instruction
    assert "Не используй кыргызский язык" in instruction


def test_fixed_language_never_switches_from_stt_metadata():
    state = CascadeLanguageState.from_settings(
        "ru-KZ",
        ["kk-KZ", "ru-KZ", "en-US"],
    )

    assert state.observe(Language.KK, "Қазақ тілінде ұзақ жауап беріңізші") is None
    assert state.active_code == "ru-KZ"


def test_unlisted_or_ambiguous_language_does_not_replace_primary():
    state = _auto_state()

    assert state.observe("ky-KG", "Алло, саламатсыз ба?") is None
    assert state.observe(Language.RU, "Алло") is None
    assert state.active_code == "kk-KZ"


def test_two_matching_short_turns_confirm_language_switch():
    state = _auto_state()

    assert state.observe(Language.RU, "Алло") is None
    assert state.observe(Language.RU, "Слышно?") == "ru-KZ"
    assert state.active_code == "ru-KZ"


def test_substantive_turn_switches_to_allowed_detected_language_immediately():
    state = _auto_state()

    switched = state.observe(Language.EN, "Please answer this question in detail")

    assert switched == "en-US"
    assert state.active_code == "en-US"


def test_explicit_language_request_switches_immediately_even_when_stt_label_differs():
    state = _auto_state()

    switched = state.observe(Language.KK, "Пожалуйста, говори по-русски")

    assert switched == "ru-KZ"
    assert state.active_code == "ru-KZ"


@pytest.mark.asyncio
async def test_processor_updates_llm_and_tts_before_forwarding_switching_transcript():
    state = _auto_state()
    llm = MagicMock()
    tts = MagicMock()
    processor = CascadeLanguageStateProcessor(
        state=state,
        base_system_instruction="Базовая инструкция.",
        llm=llm,
        tts=tts,
    )
    processor.push_frame = AsyncMock()
    transcript = _transcript("Расскажите подробнее о вашей компании", Language.RU)

    await processor.process_frame(transcript, FrameDirection.DOWNSTREAM)

    frames = [call.args[0] for call in processor.push_frame.await_args_list]
    assert [type(frame) for frame in frames] == [
        LLMUpdateSettingsFrame,
        TTSUpdateSettingsFrame,
        TranscriptionFrame,
    ]
    assert frames[0].service is llm
    assert "Активный язык ответа: русском языке (ru-KZ)" in str(frames[0].delta.system_instruction)
    assert frames[1].service is tts
    assert frames[1].delta.language is Language.RU
    assert frames[2] is transcript


@pytest.mark.asyncio
async def test_processor_ignores_interim_and_non_switching_final_transcripts():
    state = _auto_state()
    processor = CascadeLanguageStateProcessor(
        state=state,
        base_system_instruction="Базовая инструкция.",
        llm=MagicMock(),
        tts=MagicMock(),
    )
    processor.push_frame = AsyncMock()
    interim = InterimTranscriptionFrame(
        text="Алло",
        user_id="caller",
        timestamp="2026-09-05T00:00:00Z",
        language=Language.RU,
    )
    final = _transcript("Алло, саламатсыз ба?", Language.KK)

    await processor.process_frame(interim, FrameDirection.DOWNSTREAM)
    await processor.process_frame(final, FrameDirection.DOWNSTREAM)

    frames = [call.args[0] for call in processor.push_frame.await_args_list]
    assert frames == [interim, final]
    assert state.active_code == "kk-KZ"
