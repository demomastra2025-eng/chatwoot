import asyncio
from collections.abc import Coroutine
from types import SimpleNamespace
from typing import Any, cast

import pytest
from pipecat.frames.frames import Frame, TranscriptionFrame
from pipecat.processors.frame_processor import FrameDirection

from app.pipeline.processors import CallerCommandProcessor, caller_requested_end_call
from app.sessions.state import SessionState


@pytest.mark.parametrize(
    "text",
    [
        "Сбрось трубку.",
        "Пожалуйста, завершите этот звонок",
        "Давай закончим разговор",
        "Отключись",
        "Hang up",
        "Қоңырауды аяқта",
        "До свидания",
        "Нет, не надо. До свидания.",
        "Спасибо, всего доброго!",
    ],
)
def test_caller_end_call_intent_matches_explicit_commands(text):
    assert caller_requested_end_call(text) is True


@pytest.mark.parametrize(
    "text",
    [
        "Не сбрасывай трубку",
        "Только не сбросить звонок",
        "Не надо заканчивать разговор",
        "Как сбросить настройки телефона?",
        "Сбрось",
        "Как правильно сказать до свидания?",
        "Не говори до свидания",
        "Продолжайте",
    ],
)
def test_caller_end_call_intent_rejects_negation_and_unrelated_speech(text):
    assert caller_requested_end_call(text) is False


class FakeState:
    def __init__(self):
        self.correlation = SimpleNamespace(runtime_session_id="runtime-1")
        self.tasks: list[asyncio.Task[Any]] = []
        self.controls = []
        self.tools = []

    def spawn(self, work: Coroutine[Any, Any, Any]) -> asyncio.Task[Any]:
        task = asyncio.create_task(work)
        self.tasks.append(task)
        return task

    async def safe_control(self, action, payload=None, **metadata):
        self.controls.append((action, payload or {}, metadata))
        return True

    async def execute_tool(self, name, arguments, tool_call_id, *, timeout_ms):
        self.tools.append((name, arguments, tool_call_id, timeout_ms))
        return {"action": "end_call", "status": "accepted"}


class CapturingCallerCommandProcessor(CallerCommandProcessor):
    def __init__(self, state, *, end_call_timeout_ms):
        super().__init__(state, end_call_timeout_ms=end_call_timeout_ms)
        self.frames: list[tuple[Frame, FrameDirection]] = []

    async def push_frame(self, frame: Frame, direction: FrameDirection) -> None:
        self.frames.append((frame, direction))


@pytest.mark.asyncio
async def test_caller_command_processor_executes_end_call_once_for_repeated_transcript():
    state = FakeState()
    processor = CapturingCallerCommandProcessor(
        cast(SessionState, state),
        end_call_timeout_ms=1_200,
    )
    frame = TranscriptionFrame(
        text="Сбрось трубку",
        user_id="caller",
        timestamp="2026-08-01T00:00:00Z",
        finalized=True,
    )

    await processor.process_frame(frame, FrameDirection.DOWNSTREAM)
    await processor.process_frame(frame, FrameDirection.UPSTREAM)
    while pending := [task for task in state.tasks if not task.done()]:
        await asyncio.gather(*pending)

    assert len(state.tools) == 1
    name, arguments, tool_call_id, timeout_ms = state.tools[0]
    assert name == "end_call"
    assert arguments == {"reason": "caller_requested_end_call", "ended_by": "caller"}
    assert tool_call_id.startswith("caller-intent-end-call:")
    assert timeout_ms == 1_200
    assert [control[0] for control in state.controls] == ["tool_requested_end_call"]
    assert len(processor.frames) == 2
