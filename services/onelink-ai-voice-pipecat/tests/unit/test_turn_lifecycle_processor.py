from typing import cast
from unittest.mock import AsyncMock

import pytest
from pipecat.frames.frames import (
    InterruptionFrame,
    LLMFullResponseEndFrame,
    LLMFullResponseStartFrame,
    LLMTextFrame,
    TranscriptionFrame,
    UserStartedSpeakingFrame,
    UserStoppedSpeakingFrame,
)
from pipecat.processors.frame_processor import FrameDirection

import app.pipeline.processors as processors_module
from app.pipeline.processors import (
    ConversationActivity,
    ModelLifecycleProcessor,
    TurnLifecycleProcessor,
)
from app.services.gemini_live import (
    OneLinkToolResultGenerationEndFrame,
    OneLinkToolResultGenerationStartFrame,
)
from app.sessions.state import SessionState


class ActivityState:
    def __init__(self):
        self.touches = 0

    def touch(self) -> None:
        self.touches += 1

    def touch_user(self) -> None:
        self.touches += 1


def test_activity_reports_each_voice_latency_stage(monkeypatch):
    activity = ConversationActivity()
    activity._last_user_stopped_at = 10.0
    activity._last_model_generation_started_at = 10.2
    activity._last_model_output_at = 10.5
    monkeypatch.setattr(processors_module.time, "monotonic", lambda: 10.8)

    assert activity.response_latency_ms() == {
        "turn_end_to_audio_ms": 800,
        "llm_start_to_audio_ms": 600,
        "llm_first_output_to_audio_ms": 300,
    }


@pytest.mark.asyncio
async def test_turn_lifecycle_refreshes_idle_clock_when_caller_finishes_speaking():
    state = ActivityState()
    activity = ConversationActivity()
    processor = TurnLifecycleProcessor(cast(SessionState, state), activity)
    processor.push_frame = AsyncMock()

    await processor.process_frame(UserStartedSpeakingFrame(), FrameDirection.DOWNSTREAM)
    assert activity.user_speaking is True

    await processor.process_frame(UserStoppedSpeakingFrame(), FrameDirection.DOWNSTREAM)
    assert activity.user_speaking is False
    await processor.process_frame(
        TranscriptionFrame(
            text="Реплика завершена",
            user_id="caller",
            timestamp="2026-08-02T00:00:00Z",
            finalized=True,
        ),
        FrameDirection.UPSTREAM,
    )

    assert state.touches == 3


@pytest.mark.asyncio
async def test_model_lifecycle_tracks_generation_and_output_before_tts():
    activity = ConversationActivity()
    processor = ModelLifecycleProcessor(activity)
    processor.push_frame = AsyncMock()

    await processor.process_frame(LLMFullResponseStartFrame(), FrameDirection.DOWNSTREAM)
    assert activity.model_generation_active is True
    assert activity.model_generations_started == 1

    await processor.process_frame(LLMTextFrame("Готово"), FrameDirection.DOWNSTREAM)
    assert activity.model_outputs_generated == 1

    await processor.process_frame(LLMFullResponseEndFrame(), FrameDirection.DOWNSTREAM)
    assert activity.model_generation_active is False
    assert activity.model_generations_completed == 1


@pytest.mark.asyncio
async def test_model_lifecycle_marks_interrupted_generation_idle():
    activity = ConversationActivity()
    processor = ModelLifecycleProcessor(activity)
    processor.push_frame = AsyncMock()

    await processor.process_frame(LLMFullResponseStartFrame(), FrameDirection.DOWNSTREAM)
    await processor.process_frame(InterruptionFrame(), FrameDirection.DOWNSTREAM)

    assert activity.model_generation_active is False
    assert activity.model_generations_completed == activity.model_generations_started

    # A late end frame from the cancelled stream must not make completed exceed started.
    await processor.process_frame(LLMFullResponseEndFrame(), FrameDirection.DOWNSTREAM)
    await processor.process_frame(LLMFullResponseStartFrame(), FrameDirection.DOWNSTREAM)

    assert activity.model_generation_active is True


@pytest.mark.asyncio
async def test_model_lifecycle_tracks_silent_gemini_tool_result_generation():
    activity = ConversationActivity()
    processor = ModelLifecycleProcessor(activity)
    processor.push_frame = AsyncMock()

    await processor.process_frame(
        OneLinkToolResultGenerationStartFrame(), FrameDirection.DOWNSTREAM
    )
    assert activity.model_generation_active is True

    await processor.process_frame(OneLinkToolResultGenerationEndFrame(), FrameDirection.DOWNSTREAM)
    assert activity.model_generation_active is False


@pytest.mark.asyncio
async def test_model_lifecycle_ignores_upstream_mirror_frames():
    activity = ConversationActivity()
    processor = ModelLifecycleProcessor(activity)
    processor.push_frame = AsyncMock()

    await processor.process_frame(LLMFullResponseStartFrame(), FrameDirection.UPSTREAM)
    await processor.process_frame(LLMTextFrame("Не модельный поток"), FrameDirection.UPSTREAM)

    assert activity.model_generations_started == 0
    assert activity.model_outputs_generated == 0
