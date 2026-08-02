from typing import cast
from unittest.mock import AsyncMock

import pytest
from pipecat.frames.frames import (
    LLMFullResponseEndFrame,
    LLMFullResponseStartFrame,
    LLMTextFrame,
    TranscriptionFrame,
    UserStartedSpeakingFrame,
    UserStoppedSpeakingFrame,
)
from pipecat.processors.frame_processor import FrameDirection

from app.pipeline.processors import (
    AssistantLifecycleProcessor,
    ConversationActivity,
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
async def test_assistant_lifecycle_tracks_model_generation_and_output():
    activity = ConversationActivity()
    processor = AssistantLifecycleProcessor(
        cast(SessionState, ActivityState()), activity, recorder=None
    )
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
async def test_assistant_lifecycle_tracks_silent_gemini_tool_result_generation():
    activity = ConversationActivity()
    processor = AssistantLifecycleProcessor(
        cast(SessionState, ActivityState()), activity, recorder=None
    )
    processor.push_frame = AsyncMock()

    await processor.process_frame(
        OneLinkToolResultGenerationStartFrame(), FrameDirection.DOWNSTREAM
    )
    assert activity.model_generation_active is True

    await processor.process_frame(
        OneLinkToolResultGenerationEndFrame(), FrameDirection.DOWNSTREAM
    )
    assert activity.model_generation_active is False
