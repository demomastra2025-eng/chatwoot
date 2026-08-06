import asyncio
from types import SimpleNamespace
from typing import cast
from unittest.mock import AsyncMock, Mock

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
    DomainTranscriptNormalizationProcessor,
    ModelLifecycleProcessor,
    PreAggregatorSTTEvidenceProcessor,
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
@pytest.mark.parametrize(
    "source",
    ["Какое у вас слово?", "Какой у вас слово", "Скобин какой у вас?", "Слободан какой у вас?"],
)
async def test_domain_transcript_normalizer_corrects_observed_slogan_confusions(source):
    processor = DomainTranscriptNormalizationProcessor()
    processor.push_frame = AsyncMock()
    frame = TranscriptionFrame(
        text=source,
        user_id="caller",
        timestamp="2026-08-04T00:00:00Z",
        finalized=True,
    )

    await processor.process_frame(frame, FrameDirection.DOWNSTREAM)

    normalized = processor.push_frame.await_args.args[0]
    assert normalized.text == "Какой у вас слоган?"
    assert normalized.user_id == frame.user_id
    assert normalized.timestamp == frame.timestamp


@pytest.mark.asyncio
async def test_domain_transcript_normalizer_preserves_unrelated_speech():
    processor = DomainTranscriptNormalizationProcessor()
    processor.push_frame = AsyncMock()
    frame = TranscriptionFrame(
        text="Какое кодовое слово вы используете?",
        user_id="caller",
        timestamp="2026-08-04T00:00:00Z",
        finalized=True,
    )

    await processor.process_frame(frame, FrameDirection.DOWNSTREAM)

    assert processor.push_frame.await_args.args[0] is frame


@pytest.mark.asyncio
async def test_pre_aggregator_stt_evidence_is_sanitized(monkeypatch):
    info = Mock()
    monkeypatch.setattr(processors_module, "logger", SimpleNamespace(info=info))
    monkeypatch.setattr(processors_module.time, "monotonic", lambda: 12.345)
    processor = PreAggregatorSTTEvidenceProcessor()
    processor.push_frame = AsyncMock()
    frame = TranscriptionFrame(
        text="секретный текст клиента",
        user_id="caller",
        timestamp="2026-08-05T00:00:00Z",
        finalized=True,
    )

    await processor.process_frame(frame, FrameDirection.DOWNSTREAM)

    assert info.call_args.args[1:] == (1, "final", 3, 23, 12_345)
    assert "секретный текст клиента" not in repr(info.call_args)
    processor.push_frame.assert_awaited_once_with(frame, FrameDirection.DOWNSTREAM)


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
async def test_activity_detects_one_silent_ordinary_answer_after_deadline(monkeypatch):
    activity = ConversationActivity()
    now = 10.0
    monkeypatch.setattr(processors_module.time, "monotonic", lambda: now)
    await activity.user_message_added("Расскажите о своих услугах")

    now = 12.4
    assert activity.ordinary_answer_stall(timeout_ms=2_500, recovered_sequence=0) is None

    now = 12.6
    stalled = activity.ordinary_answer_stall(timeout_ms=2_500, recovered_sequence=0)
    assert stalled == {
        "sequence": 1,
        "caller_transcript": "Расскажите о своих услугах",
        "elapsed_ms": 2_600,
    }
    assert activity.ordinary_answer_stall(timeout_ms=2_500, recovered_sequence=1) is None


@pytest.mark.asyncio
@pytest.mark.parametrize("completed_by", ["model_output", "assistant_turn", "tool"])
async def test_activity_does_not_recover_a_turn_already_owned_by_pipeline(
    monkeypatch, completed_by
):
    activity = ConversationActivity()
    now = 20.0
    monkeypatch.setattr(processors_module.time, "monotonic", lambda: now)
    await activity.user_message_added("Какие услуги у вас есть?")
    if completed_by == "model_output":
        await activity.model_output_generated()
    elif completed_by == "assistant_turn":
        await activity.bot_started()
    else:
        await activity.tool_started()

    now = 30.0
    assert activity.ordinary_answer_stall(timeout_ms=2_500, recovered_sequence=0) is None


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
    processor._start_interruption = AsyncMock()

    await processor.process_frame(LLMFullResponseStartFrame(), FrameDirection.DOWNSTREAM)
    await processor.process_frame(InterruptionFrame(), FrameDirection.DOWNSTREAM)

    assert activity.model_generation_active is False
    assert activity.model_generations_completed == activity.model_generations_started

    # A late end frame from the cancelled stream must not make completed exceed started.
    await processor.process_frame(LLMFullResponseEndFrame(), FrameDirection.DOWNSTREAM)
    await processor.process_frame(LLMFullResponseStartFrame(), FrameDirection.DOWNSTREAM)

    assert activity.model_generation_active is True
    processor._start_interruption.assert_awaited_once()


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


@pytest.mark.asyncio
async def test_causal_admission_linearizes_enqueue_before_user_turn_invalidation():
    activity = ConversationActivity()
    enqueue_started = asyncio.Event()
    release_enqueue = asyncio.Event()
    enqueued = []

    async def enqueue():
        enqueue_started.set()
        await release_enqueue.wait()
        enqueued.append("tool speech")

    admission = asyncio.create_task(
        activity.admit_causal_side_effect(activity.user_turns_started, enqueue)
    )
    await enqueue_started.wait()
    user_started = asyncio.create_task(activity.user_started())
    await asyncio.sleep(0)

    assert not user_started.done()
    release_enqueue.set()
    assert await admission is True
    await user_started
    assert enqueued == ["tool speech"]
    assert activity.user_turns_started == 1

    stale_enqueue_called = False

    async def stale_enqueue():
        nonlocal stale_enqueue_called
        stale_enqueue_called = True

    assert await activity.admit_causal_side_effect(0, stale_enqueue) is False
    assert stale_enqueue_called is False


@pytest.mark.asyncio
async def test_causal_admission_bounds_enqueue_before_user_turn_invalidation(monkeypatch):
    monkeypatch.setattr("app.pipeline.processors.CAUSAL_SIDE_EFFECT_TIMEOUT_SECONDS", 0.01)
    activity = ConversationActivity()

    async def stalled_enqueue():
        await asyncio.Event().wait()

    admission = asyncio.create_task(
        activity.admit_causal_side_effect(activity.user_turns_started, stalled_enqueue)
    )
    await asyncio.sleep(0)
    user_started = asyncio.create_task(activity.user_started())

    assert await admission is False
    await asyncio.wait_for(user_started, timeout=0.05)

    assert activity.user_turns_started == 1
