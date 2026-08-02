import time

import pytest
from pipecat.frames.frames import (
    BotStartedSpeakingFrame,
    InterimTranscriptionFrame,
    VADUserStartedSpeakingFrame,
    VADUserStoppedSpeakingFrame,
)
from pipecat.turns.types import ProcessFrameResult

from app.pipeline.turn_strategies import ConfirmedUserTurnStartStrategy


def transcription(text: str = "да, слушаю") -> InterimTranscriptionFrame:
    return InterimTranscriptionFrame(text=text, user_id="caller", timestamp="now")


def capture_starts(strategy: ConfirmedUserTurnStartStrategy):
    starts = []

    @strategy.event_handler("on_user_turn_started")
    async def on_user_turn_started(_strategy, params):
        starts.append(params)

    return starts


@pytest.mark.asyncio
async def test_delayed_transcript_without_vad_cannot_interrupt_bot():
    strategy = ConfirmedUserTurnStartStrategy(mode="transcript_confirmed")
    starts = capture_starts(strategy)

    await strategy.process_frame(BotStartedSpeakingFrame())
    result = await strategy.process_frame(transcription())

    assert result is ProcessFrameResult.CONTINUE
    assert starts == []


@pytest.mark.asyncio
async def test_bot_interruption_requires_vad_and_transcript_confirmation():
    strategy = ConfirmedUserTurnStartStrategy(mode="transcript_confirmed", min_words=2)
    starts = capture_starts(strategy)

    await strategy.process_frame(BotStartedSpeakingFrame())
    assert (
        await strategy.process_frame(VADUserStartedSpeakingFrame())
        is ProcessFrameResult.CONTINUE
    )
    assert await strategy.process_frame(transcription("да")) is ProcessFrameResult.CONTINUE
    assert await strategy.process_frame(transcription()) is ProcessFrameResult.STOP

    assert len(starts) == 1
    assert starts[0].enable_interruptions is True


@pytest.mark.asyncio
async def test_recent_vad_stop_allows_slightly_late_stt_confirmation():
    strategy = ConfirmedUserTurnStartStrategy(
        mode="transcript_confirmed", confirmation_window_seconds=0.8
    )
    starts = capture_starts(strategy)

    await strategy.process_frame(BotStartedSpeakingFrame())
    await strategy.process_frame(VADUserStartedSpeakingFrame())
    await strategy.process_frame(VADUserStoppedSpeakingFrame())

    assert await strategy.process_frame(transcription()) is ProcessFrameResult.STOP
    assert len(starts) == 1


@pytest.mark.asyncio
async def test_stale_transcript_after_confirmation_window_is_ignored():
    strategy = ConfirmedUserTurnStartStrategy(
        mode="transcript_confirmed", confirmation_window_seconds=0.2
    )
    starts = capture_starts(strategy)

    await strategy.process_frame(BotStartedSpeakingFrame())
    strategy._last_vad_stop = time.monotonic() - 0.3

    assert await strategy.process_frame(transcription()) is ProcessFrameResult.CONTINUE
    assert starts == []


@pytest.mark.asyncio
async def test_idle_bot_starts_user_turn_immediately_on_vad():
    strategy = ConfirmedUserTurnStartStrategy(mode="transcript_confirmed")
    starts = capture_starts(strategy)

    assert (
        await strategy.process_frame(VADUserStartedSpeakingFrame())
        is ProcessFrameResult.STOP
    )
    assert len(starts) == 1


@pytest.mark.asyncio
async def test_vad_confirmed_mode_interrupts_without_waiting_for_stt():
    strategy = ConfirmedUserTurnStartStrategy(mode="vad_confirmed")
    starts = capture_starts(strategy)

    await strategy.process_frame(BotStartedSpeakingFrame())

    assert (
        await strategy.process_frame(VADUserStartedSpeakingFrame())
        is ProcessFrameResult.STOP
    )
    assert len(starts) == 1