"""OneLink media/lifecycle processors for the Pipecat frame graph."""

from __future__ import annotations

import asyncio
import hashlib
import re
import time
from collections.abc import Awaitable, Callable
from dataclasses import replace
from typing import Any, TypeVar

from loguru import logger
from pipecat.audio.utils import create_stream_resampler
from pipecat.frames.frames import (
    AudioRawFrame,
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    Frame,
    InputAudioRawFrame,
    InterimTranscriptionFrame,
    InterruptionFrame,
    LLMFullResponseEndFrame,
    LLMFullResponseStartFrame,
    LLMTextFrame,
    TranscriptionFrame,
    TTSAudioRawFrame,
    UserStartedSpeakingFrame,
    UserStoppedSpeakingFrame,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from app.recordings.writer import DualChannelRecorder
from app.services.gemini_live import (
    OneLinkToolResultGenerationEndFrame,
    OneLinkToolResultGenerationStartFrame,
)
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
            await self._activity.user_started()
            if self._activity.bot_speaking:
                self._state.spawn(
                    self._state.safe_control(
                        "caller_interrupted",
                        {"runtime_engine": "pipecat"},
                    )
                )
        elif isinstance(frame, UserStoppedSpeakingFrame):
            self._state.touch()
            await self._activity.user_stopped()
        elif isinstance(frame, InterimTranscriptionFrame):
            self._state.touch()
            await self._record_caller(frame, final=False)
        elif isinstance(frame, TranscriptionFrame):
            self._state.touch()
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


class CallerCommandProcessor(FrameProcessor):
    """Execute terminal caller commands without relying on an LLM tool decision."""

    def __init__(self, state: SessionState, *, end_call_timeout_ms: int):
        super().__init__()
        self._state = state
        self._end_call_timeout_ms = end_call_timeout_ms
        self._end_call_requested = False
        self._end_call_executor: (
            Callable[[dict[str, str], str, int], Awaitable[dict[str, Any]]] | None
        ) = None
        runtime_id = state.correlation.runtime_session_id
        digest = hashlib.sha256(runtime_id.encode()).hexdigest()[:24]
        self._tool_call_id = f"caller-intent-end-call:{digest}"

    def bind_end_call(
        self,
        executor: Callable[[dict[str, str], str, int], Awaitable[dict[str, Any]]],
    ) -> None:
        self._end_call_executor = executor

    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        await super().process_frame(frame, direction)
        if (
            direction == FrameDirection.UPSTREAM
            and isinstance(frame, TranscriptionFrame)
            and not isinstance(frame, InterimTranscriptionFrame)
            and not self._end_call_requested
            and caller_requested_end_call(frame.text)
        ):
            self._end_call_requested = True
            self._state.spawn(self._execute_end_call())
        await self.push_frame(frame, direction)

    async def _execute_end_call(self) -> None:
        self._state.spawn(
            self._state.safe_control(
                "tool_requested_end_call",
                {"source": "caller_transcript"},
                tool_call_id=self._tool_call_id,
                tool_name="end_call",
            )
        )
        arguments = {"reason": "caller_requested_end_call", "ended_by": "caller"}
        if self._end_call_executor is not None:
            await self._end_call_executor(
                arguments,
                self._tool_call_id,
                self._end_call_timeout_ms,
            )
        else:
            await self._state.execute_tool(
                "end_call",
                arguments,
                self._tool_call_id,
                timeout_ms=self._end_call_timeout_ms,
            )


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
        if isinstance(frame, (LLMFullResponseStartFrame, OneLinkToolResultGenerationStartFrame)):
            await self._activity.model_generation_started()
        elif isinstance(frame, LLMTextFrame):
            await self._activity.model_output_generated()
        elif isinstance(frame, (LLMFullResponseEndFrame, OneLinkToolResultGenerationEndFrame)):
            await self._activity.model_generation_completed()
        elif isinstance(frame, InterruptionFrame):
            await self._activity.model_generation_interrupted()
        elif isinstance(frame, BotStartedSpeakingFrame):
            await self._activity.bot_started()
            latency = self._activity.response_latency_ms()
            if latency["turn_end_to_audio_ms"] is not None:
                logger.info(
                    "Voice response audio started turn_end_to_audio_ms={} "
                    "llm_start_to_audio_ms={} llm_first_output_to_audio_ms={}",
                    latency["turn_end_to_audio_ms"],
                    latency["llm_start_to_audio_ms"],
                    latency["llm_first_output_to_audio_ms"],
                )
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
        self.user_speaking = False
        self.turns_started = 0
        self.turns_completed = 0
        self.model_generations_started = 0
        self.model_generations_completed = 0
        self.model_outputs_generated = 0
        self.speech_lock = asyncio.Lock()
        self._changed = asyncio.Condition()
        self._last_user_stopped_at: float | None = None
        self._last_model_generation_started_at: float | None = None
        self._last_model_output_at: float | None = None

    @property
    def model_generation_active(self) -> bool:
        return self.model_generations_started > self.model_generations_completed

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

    async def user_started(self) -> None:
        async with self._changed:
            self.user_speaking = True
            self._changed.notify_all()

    async def user_stopped(self) -> None:
        async with self._changed:
            self.user_speaking = False
            self._last_user_stopped_at = time.monotonic()
            self._changed.notify_all()

    async def model_generation_started(self) -> None:
        async with self._changed:
            self.model_generations_started += 1
            self._last_model_generation_started_at = time.monotonic()
            self._last_model_output_at = None
            self._changed.notify_all()

    async def model_generation_completed(self) -> None:
        async with self._changed:
            self.model_generations_completed = min(
                self.model_generations_started,
                self.model_generations_completed + 1,
            )
            self._changed.notify_all()

    async def model_output_generated(self) -> None:
        async with self._changed:
            self.model_outputs_generated += 1
            if self._last_model_output_at is None:
                self._last_model_output_at = time.monotonic()
            self._changed.notify_all()

    def response_latency_ms(self) -> dict[str, int | None]:
        now = time.monotonic()

        def elapsed(started_at: float | None) -> int | None:
            if started_at is None:
                return None
            return max(0, round((now - started_at) * 1_000))

        return {
            "turn_end_to_audio_ms": elapsed(self._last_user_stopped_at),
            "llm_start_to_audio_ms": elapsed(self._last_model_generation_started_at),
            "llm_first_output_to_audio_ms": elapsed(self._last_model_output_at),
        }

    async def model_generation_interrupted(self) -> None:
        async with self._changed:
            self.model_generations_completed = self.model_generations_started
            self._changed.notify_all()

    async def wait_for_turn_started_after(self, sequence: int, timeout: float) -> bool:
        return await self._wait_for(lambda: self.turns_started > sequence, timeout)

    async def wait_for_turn_completed_after(self, sequence: int, timeout: float) -> bool:
        return await self._wait_for(lambda: self.turns_completed > sequence, timeout)

    async def wait_for_model_generation_started_after(self, sequence: int, timeout: float) -> bool:
        return await self._wait_for(lambda: self.model_generations_started > sequence, timeout)

    async def wait_for_model_idle_after(self, sequence: int, timeout: float) -> bool:
        return await self._wait_for(
            lambda: (
                self.model_generations_started > sequence
                and self.model_generations_completed >= self.model_generations_started
            ),
            timeout,
        )

    async def wait_for_model_idle(self, timeout: float) -> bool:
        return await self._wait_for(lambda: not self.model_generation_active, timeout)

    async def _wait_for(self, predicate, timeout: float) -> bool:
        try:
            async with asyncio.timeout(timeout):
                async with self._changed:
                    await self._changed.wait_for(predicate)
            return True
        except TimeoutError:
            return False


_END_CALL_NEGATION = re.compile(
    r"\bне\s+(?:(?:надо|нужно)\s+)?(?:сбрасывай|сбрасывать|сбросить|клади|положить|"
    r"завершай|завершить|заканчивай|закончить|отключайся|отключаться)\b"
)
_NON_TERMINAL_RESET = re.compile(r"\bсброс\w*\s+(?:настрой\w*|парол\w*|данн\w*)\b")
_END_CALL_PATTERNS = (
    re.compile(r"\b(?:сбрось|сбросите|сбросить)\s+(?:трубку|звонок|вызов)\b"),
    re.compile(r"\b(?:положи|положите|клади)\s+трубку\b"),
    re.compile(
        r"\b(?:заверши|завершите|завершить|закончим|закончить|прекрати|прекратите)\s+"
        r"(?:этот\s+)?(?:звонок|разговор|вызов)\b"
    ),
    re.compile(r"\b(?:отключись|отключитесь)\b"),
    re.compile(r"\b(?:hang\s*up|end\s+the\s+call)\b"),
    re.compile(r"\b(?:қоңырауды\s+аяқта|тұтқаны\s+қой)\b"),
)


def caller_requested_end_call(text: str) -> bool:
    normalized = " ".join(text.lower().replace("ё", "е").split())
    if (
        not normalized
        or _END_CALL_NEGATION.search(normalized)
        or _NON_TERMINAL_RESET.search(normalized)
    ):
        return False
    return any(pattern.search(normalized) for pattern in _END_CALL_PATTERNS)
