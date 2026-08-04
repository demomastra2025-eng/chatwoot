"""OneLink turn strategies for low-latency, noise-safe voice interruption."""

from __future__ import annotations

import time

from pipecat.frames.frames import (
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    Frame,
    InterimTranscriptionFrame,
    TranscriptionFrame,
    VADUserStartedSpeakingFrame,
    VADUserStoppedSpeakingFrame,
)
from pipecat.turns.types import ProcessFrameResult
from pipecat.turns.user_start.base_user_turn_start_strategy import (
    BaseUserTurnStartStrategy,
    UserTurnStartedParams,
)


class ConfirmedUserTurnStartStrategy(BaseUserTurnStartStrategy):
    """Use transcripts as an idle fallback without weakening barge-in safety.

    While the assistant is idle, either local VAD or an STT transcript can start
    a turn. This matters on telephone audio where a strict local VAD can miss a
    quiet but intelligible phrase. While the assistant is speaking,
    ``transcript_confirmed`` mode still requires both local VAD and STT evidence
    before broadcasting an interruption. A delayed or echoed transcript
    therefore cannot cancel a new LLM/TTS response by itself.
    """

    def __init__(
        self,
        *,
        mode: str = "transcript_confirmed",
        min_words: int = 1,
        confirmation_window_seconds: float = 0.8,
        **kwargs,
    ) -> None:
        super().__init__(**kwargs)
        self._mode = mode
        self._min_words = max(1, min_words)
        self._confirmation_window_seconds = max(0.1, confirmation_window_seconds)
        self._bot_speaking = False
        self._vad_active = False
        self._last_vad_stop = 0.0

    async def reset(self) -> None:
        self._vad_active = False
        self._last_vad_stop = 0.0

    async def process_frame(self, frame: Frame) -> ProcessFrameResult:
        if isinstance(frame, BotStartedSpeakingFrame):
            self._bot_speaking = True
        elif isinstance(frame, BotStoppedSpeakingFrame):
            self._bot_speaking = False
        elif isinstance(frame, VADUserStartedSpeakingFrame):
            self._vad_active = True
            self._last_vad_stop = 0.0
            if not self._bot_speaking or self._mode == "vad_confirmed":
                await self.trigger_user_turn_started()
                return ProcessFrameResult.STOP
        elif isinstance(frame, VADUserStoppedSpeakingFrame):
            self._vad_active = False
            self._last_vad_stop = time.monotonic()
        elif isinstance(frame, (InterimTranscriptionFrame, TranscriptionFrame)):
            if self._idle_transcript_starts_turn(
                frame.text
            ) or self._transcript_confirms_active_speech(frame.text):
                await self.trigger_user_turn_started()
                return ProcessFrameResult.STOP

        return ProcessFrameResult.CONTINUE

    def _idle_transcript_starts_turn(self, text: str) -> bool:
        return not self._bot_speaking and bool(text.strip())

    def _transcript_confirms_active_speech(self, text: str) -> bool:
        if self._mode != "transcript_confirmed" or not self._bot_speaking:
            return False
        if len(text.split()) < self._min_words:
            return False
        if self._vad_active:
            return True
        return (
            self._last_vad_stop > 0
            and time.monotonic() - self._last_vad_stop <= self._confirmation_window_seconds
        )

    async def trigger_user_turn_started(self) -> None:
        await self._call_event_handler(
            "on_user_turn_started",
            UserTurnStartedParams(
                enable_interruptions=self._enable_interruptions,
                enable_user_speaking_frames=self._enable_user_speaking_frames,
            ),
        )
