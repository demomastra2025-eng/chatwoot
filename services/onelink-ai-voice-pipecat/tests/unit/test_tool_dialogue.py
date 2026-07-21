import asyncio
from collections.abc import Coroutine
from types import SimpleNamespace
from typing import Any

import pytest

from app.pipeline.context import AiSettings, ToolDefinition
from app.pipeline.processors import ConversationActivity
from app.pipeline.tool_dialogue import ToolDialogueCoordinator


class FakeState:
    def __init__(self, result=None, gate=None):
        self.result = result or {"answer": "готово"}
        self.gate = gate
        self.controls = []
        self.tasks = []
        self.executions = 0

    async def execute_tool(self, *_args, **_kwargs):
        self.executions += 1
        if self.gate is not None:
            await self.gate.wait()
        return self.result

    async def safe_control(self, action, payload=None, **metadata):
        self.controls.append((action, payload or {}, metadata))
        return True

    def spawn(self, work: Coroutine[Any, Any, Any]) -> None:
        task = asyncio.create_task(work)
        self.tasks.append(task)


class Params(SimpleNamespace):
    arguments: dict
    tool_call_id: str


def ai_settings(**overrides):
    values = {
        "provider": "elevenlabs",
        "model": "openai/gpt-5.4-mini",
        "voice": "voice-id",
        "system_prompt": "Отвечай коротко.",
        "tool_start_after_ms": 20,
        "tool_delay_after_ms": 20,
        "post_tool_continuation_ms": 100,
    }
    values.update(overrides)
    return AiSettings(**values)


def definition(name="faq_lookup"):
    return ToolDefinition(name=name, timeout_ms=5_000)


async def execute_with_answer(
    coordinator,
    activity,
    tool_definition=None,
    on_result=None,
):
    results = []

    async def result_callback(result):
        results.append(result)
        if on_result is not None:
            await on_result(result)
        else:
            await activity.bot_started()

    params = Params(
        arguments={"query": "тариф"}, tool_call_id="tool-1", result_callback=result_callback
    )
    await coordinator.execute(tool_definition or definition(), params)
    return results


@pytest.mark.asyncio
async def test_fast_tool_returns_without_progress_speech():
    state = FakeState()
    activity = ConversationActivity()
    spoken = []
    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(speak_exact=spoken.append, run_instruction=spoken.append)

    results = await execute_with_answer(coordinator, activity)
    await asyncio.gather(*state.tasks)

    assert results == [{"answer": "готово"}]
    assert spoken == []
    assert state.executions == 1


@pytest.mark.asyncio
async def test_long_read_tool_speaks_progress_then_returns_result_once():
    gate = asyncio.Event()
    state = FakeState(gate=gate)
    activity = ConversationActivity()
    spoken = []

    async def speak(message):
        spoken.append(message)

    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(speak_exact=speak, run_instruction=speak)
    execution = asyncio.create_task(execute_with_answer(coordinator, activity))

    await asyncio.sleep(0.03)
    assert spoken == ["Секунду, проверю."]
    gate.set()
    results = await execution
    await asyncio.gather(*state.tasks)

    assert results == [{"answer": "готово"}]
    assert state.executions == 1
    assert [control[0] for control in state.controls].count("tool_progress") == 1


@pytest.mark.asyncio
async def test_very_long_read_tool_speaks_start_and_delay_progress():
    gate = asyncio.Event()
    state = FakeState(gate=gate)
    activity = ConversationActivity()
    spoken = []

    async def speak(message):
        spoken.append(message)

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(tool_start_after_ms=5, tool_delay_after_ms=5),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=speak, run_instruction=speak)
    execution = asyncio.create_task(execute_with_answer(coordinator, activity))

    await asyncio.sleep(0.03)
    gate.set()
    await execution
    await asyncio.gather(*state.tasks)

    assert spoken == ["Секунду, проверю.", "Ещё смотрю, почти готово."]


@pytest.mark.asyncio
async def test_tool_result_waits_for_interrupted_progress_turn_to_stop():
    tool_gate = asyncio.Event()
    speech_started = asyncio.Event()
    speech_stopped = asyncio.Event()
    result_delivered = asyncio.Event()
    state = FakeState(gate=tool_gate)
    activity = ConversationActivity()

    async def speak(_message):
        await activity.bot_started()
        speech_started.set()
        await speech_stopped.wait()
        await activity.bot_stopped()

    async def on_result(_result):
        result_delivered.set()
        await activity.bot_started()

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(tool_start_after_ms=5),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=speak, run_instruction=speak)
    execution = asyncio.create_task(execute_with_answer(coordinator, activity, on_result=on_result))

    await asyncio.wait_for(speech_started.wait(), timeout=0.1)
    tool_gate.set()
    await asyncio.sleep(0)
    assert result_delivered.is_set() is False

    speech_stopped.set()
    await execution
    await asyncio.gather(*state.tasks)
    assert result_delivered.is_set() is True


@pytest.mark.asyncio
async def test_terminal_tool_never_speaks_progress_filler():
    gate = asyncio.Event()
    state = FakeState(result={"action": "transfer"}, gate=gate)
    activity = ConversationActivity()
    spoken = []

    async def speak(message):
        spoken.append(message)

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(tool_start_after_ms=5),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=speak, run_instruction=speak)
    execution = asyncio.create_task(
        execute_with_answer(coordinator, activity, definition("request_transfer"))
    )

    await asyncio.sleep(0.02)
    gate.set()
    await execution
    await asyncio.gather(*state.tasks)

    assert spoken == []


@pytest.mark.asyncio
async def test_gemini_tool_does_not_inject_progress_as_a_user_turn():
    gate = asyncio.Event()
    state = FakeState(gate=gate)
    activity = ConversationActivity()
    spoken = []

    async def speak(message):
        spoken.append(message)

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(provider="gemini-live", tool_start_after_ms=5),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=speak, run_instruction=speak)
    execution = asyncio.create_task(execute_with_answer(coordinator, activity))

    await asyncio.sleep(0.02)
    gate.set()
    await execution
    await asyncio.gather(*state.tasks)

    assert spoken == []
    assert all(control[0] != "tool_progress" for control in state.controls)


@pytest.mark.asyncio
async def test_mutating_tool_speaks_progress_without_duplicate_execution():
    gate = asyncio.Event()
    progress_started = asyncio.Event()
    state = FakeState(result={"contact_id": 7}, gate=gate)
    activity = ConversationActivity()
    spoken = []

    async def speak(message):
        spoken.append(message)
        progress_started.set()

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(tool_start_after_ms=5),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=speak, run_instruction=speak)
    execution = asyncio.create_task(
        execute_with_answer(coordinator, activity, definition("create_contact"))
    )

    await asyncio.wait_for(progress_started.wait(), timeout=0.1)
    gate.set()
    await execution
    await asyncio.gather(*state.tasks)

    assert spoken == ["Секунду, проверю."]
    assert state.executions == 1


@pytest.mark.asyncio
async def test_post_tool_stall_forces_one_continuation_instruction():
    state = FakeState()
    activity = ConversationActivity()
    instructions = []

    async def record(message):
        instructions.append(message)

    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(speak_exact=record, run_instruction=record)
    results = await execute_with_answer(
        coordinator,
        activity,
        on_result=lambda _result: asyncio.sleep(0),
    )
    await asyncio.gather(*state.tasks)

    assert results == [{"answer": "готово"}]
    assert len(instructions) == 1
    assert "faq_lookup" in instructions[0]
    assert any(control[0] == "post_tool_model_stall" for control in state.controls)


@pytest.mark.asyncio
async def test_failed_tool_stall_speaks_configured_failure_phrase():
    state = FakeState(result={"error": "tool_execution_failed"})
    activity = ConversationActivity()
    spoken = []

    async def record(message):
        spoken.append(message)

    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(speak_exact=record, run_instruction=record)
    await execute_with_answer(
        coordinator,
        activity,
        on_result=lambda _result: asyncio.sleep(0),
    )
    await asyncio.gather(*state.tasks)

    assert spoken == ["Не получилось проверить автоматически. Могу соединить со специалистом."]
