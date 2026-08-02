from typing import cast
from unittest.mock import AsyncMock

import pytest
from pipecat.frames.frames import (
    TranscriptionFrame,
    UserStartedSpeakingFrame,
    UserStoppedSpeakingFrame,
)
from pipecat.processors.frame_processor import FrameDirection

from app.pipeline.processors import ConversationActivity, TurnLifecycleProcessor
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