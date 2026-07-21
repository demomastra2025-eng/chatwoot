"""OneLink media/lifecycle processors for the Pipecat frame graph."""

from __future__ import annotations

import asyncio
from dataclasses import replace
from typing import TypeVar

from pipecat.audio.utils import create_stream_resampler
from pipecat.frames.frames import (
    AudioRawFrame,
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    Frame,
    InputAudioRawFrame,
    InterimTranscriptionFrame,
    TranscriptionFrame,
    TTSAudioRawFrame,
    UserStartedSpeakingFrame,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from app.recordings.writer import DualChannelRecorder
from app.sessions.state import SessionState

AudioFrameT = TypeVar("AudioFrameT", bound=AudioRawFrame)


class AudioResampleProcessor(FrameProcessor):
    """Resample one audio frame family without changing the media contract around it."""

    def __init__(self, frame_type: type[AudioFrameT], target_sample_rate: int):
        super().__init__()
        self._frame_type = frame_type
        self._target_sample_rate = target_sample_rate
        self._resampler = create_stream_resampler(quality="QQ", clear_after_secs=None)

    @property
    def target_sample_rate(self) -> int:
        return self._target_sample_rate

    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        await super().process_frame(frame, direction)
        if direction == FrameDirection.DOWNSTREAM and isinstance(frame, self._frame_type):
            if frame.sample_rate != self._target_sample_rate:
                audio = await self._resampler.resample(
                    frame.audio,
                    frame.sample_rate,
                    self._target_sample_rate,
                )
                if not audio:
                    return
                frame = replace(frame, audio=audio, sample_rate=self._target_sample_rate)
        await self.push_frame(frame, direction)


class InputRecordingProcessor(FrameProcessor):
    def __init__(self, recorder: DualChannelRecorder | None):
        super().__init__()
        self._recorder = recorder

    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        await super().process_frame(frame, direction)
        if (
            self._recorder is not None
            and direction == FrameDirection.DOWNSTREAM
            and isinstance(frame, InputAudioRawFrame)
        ):
            await self._recorder.write_inbound(frame.audio, sample_rate=frame.sample_rate)
        await self.push_frame(frame, direction)


class TurnLifecycleProcessor(FrameProcessor):
    def __init__(self, state: SessionState, activity: ConversationActivity):
        super().__init__()
        self._state = state
        self._activity = activity

    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        await super().process_frame(frame, direction)
        if isinstance(frame, UserStartedSpeakingFrame):
            self._state.touch_user()
            if self._activity.bot_speaking:
                self._state.spawn(
                    self._state.safe_control(
                        "caller_interrupted",
                        {"runtime_engine": "pipecat"},
                    )
                )
        elif isinstance(frame, InterimTranscriptionFrame):
            await self._record_caller(frame, final=False)
        await self.push_frame(frame, direction)

    async def _record_caller(self, frame: TranscriptionFrame, *, final: bool) -> None:
        await self._state.add_transcript(
            "caller",
            frame.text,
            final=final,
            timestamp=frame.timestamp,
        )
        if final:
            self._state.spawn(self._state.flush_transcript())


class AssistantLifecycleProcessor(FrameProcessor):
    def __init__(
        self,
        state: SessionState,
        activity: ConversationActivity,
        recorder: DualChannelRecorder | None,
    ):
        super().__init__()
        self._state = state
        self._activity = activity
        self._recorder = recorder

    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        await super().process_frame(frame, direction)
        if isinstance(frame, BotStartedSpeakingFrame):
            await self._activity.bot_started()
            self._state.touch()
            self._state.spawn(self._state.safe_control("ai_speaking", {"state": "started"}))
        elif isinstance(frame, BotStoppedSpeakingFrame):
            await self._activity.bot_stopped()
            self._state.touch()
            self._state.spawn(self._state.safe_control("ai_speaking", {"state": "stopped"}))
        elif self._recorder is not None and isinstance(frame, TTSAudioRawFrame):
            await self._recorder.write_outbound(frame.audio, sample_rate=frame.sample_rate)
        await self.push_frame(frame, direction)


class ConversationActivity:
    def __init__(self) -> None:
        self.bot_speaking = False
        self.turns_started = 0
        self.turns_completed = 0
        self.speech_lock = asyncio.Lock()
        self._changed = asyncio.Condition()

    async def bot_started(self) -> None:
        async with self._changed:
            self.bot_speaking = True
            self.turns_started += 1
            self._changed.notify_all()

    async def bot_stopped(self) -> None:
        async with self._changed:
            self.bot_speaking = False
            self.turns_completed += 1
            self._changed.notify_all()

    async def wait_for_turn_started_after(self, sequence: int, timeout: float) -> bool:
        return await self._wait_for(lambda: self.turns_started > sequence, timeout)

    async def wait_for_turn_completed_after(self, sequence: int, timeout: float) -> bool:
        return await self._wait_for(lambda: self.turns_completed > sequence, timeout)

    async def _wait_for(self, predicate, timeout: float) -> bool:
        try:
            async with asyncio.timeout(timeout):
                async with self._changed:
                    await self._changed.wait_for(predicate)
            return True
        except TimeoutError:
            return False
