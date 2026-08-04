import asyncio
from types import SimpleNamespace
from typing import cast

import pytest

from app.pipeline.factory import _register_transcript_handlers
from app.pipeline.processors import ConversationActivity
from app.sessions.state import SessionState


class EventHalf:
    def __init__(self):
        self.handlers = {}

    def event_handler(self, name):
        def register(handler):
            self.handlers[name] = handler
            return handler

        return register


class Aggregators:
    def __init__(self):
        self._user = EventHalf()
        self._assistant = EventHalf()

    def user(self):
        return self._user

    def assistant(self):
        return self._assistant


class TranscriptState:
    def __init__(self):
        self.transcripts = []
        self.events = []
        self.tasks = []

    async def add_transcript(self, speaker, text, *, final, deduplicate_recent=False):
        self.transcripts.append((speaker, text, final))

    async def flush_transcript(self):
        return None

    async def safe_event(self, event, data):
        self.events.append((event, data))

    def spawn(self, coroutine):
        self.tasks.append(asyncio.create_task(coroutine))

    async def wait_for_tasks(self):
        if self.tasks:
            await asyncio.gather(*self.tasks)


@pytest.mark.asyncio
async def test_interrupted_assistant_text_is_not_persisted_as_spoken():
    aggregators = Aggregators()
    state = TranscriptState()
    _register_transcript_handlers(
        aggregators, cast(SessionState, state), ConversationActivity()
    )

    handler = aggregators.assistant().handlers["on_assistant_turn_stopped"]
    await handler(
        aggregators.assistant(),
        SimpleNamespace(content="Недоставленный ответ", interrupted=True),
    )
    await state.wait_for_tasks()

    assert state.transcripts == []
    assert state.events == [
        (
            "assistant_transcript_suppressed",
            {"reason": "interrupted", "content_chars": len("Недоставленный ответ")},
        )
    ]


@pytest.mark.asyncio
async def test_completed_assistant_text_is_persisted():
    aggregators = Aggregators()
    state = TranscriptState()
    _register_transcript_handlers(
        aggregators, cast(SessionState, state), ConversationActivity()
    )

    handler = aggregators.assistant().handlers["on_assistant_turn_stopped"]
    await handler(
        aggregators.assistant(),
        SimpleNamespace(content="Доставленный ответ", interrupted=False),
    )
    await state.wait_for_tasks()

    assert state.transcripts == [("ai", "Доставленный ответ", True)]
    assert state.events == []
