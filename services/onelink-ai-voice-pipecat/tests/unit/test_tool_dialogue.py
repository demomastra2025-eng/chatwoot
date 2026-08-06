import asyncio
import json
from collections.abc import Coroutine
from types import SimpleNamespace
from typing import Any

import pytest

import app.pipeline.tool_dialogue as tool_dialogue_module
from app.pipeline.context import AiSettings, ToolDefinition
from app.pipeline.processors import ConversationActivity
from app.pipeline.tool_dialogue import ToolDialogueCoordinator, _voice_result_projection


class FakeState:
    def __init__(self, result=None, gate=None):
        self.result = result or {"answer": "готово"}
        self.gate = gate
        self.controls = []
        self.events = []
        self.tasks = []
        self.executions = 0
        self.termination_requested = False

    async def execute_tool(
        self,
        _name,
        _arguments,
        _tool_call_id,
        *,
        timeout_ms,
    ):
        assert timeout_ms > 0
        self.executions += 1
        if self.gate is not None:
            await self.gate.wait()
        return self.result

    async def safe_control(self, action, payload=None, **metadata):
        self.controls.append((action, payload or {}, metadata))
        return True

    async def safe_event(self, event, payload=None):
        self.events.append((event, payload or {}))
        return True

    def request_termination(self):
        self.termination_requested = True

    def spawn(self, work: Coroutine[Any, Any, Any]) -> asyncio.Task[Any]:
        task = asyncio.create_task(work)
        self.tasks.append(task)
        return task


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
    if values["provider"] == "gemini-live" and "model" not in overrides:
        values["model"] = "gemini-3.1-flash-live-preview"
    return AiSettings(**values)


def definition(name="account_check", **overrides):
    values = {"name": name, "timeout_ms": 5_000}
    values.update(overrides)
    return ToolDefinition(**values)


async def execute_with_answer(
    coordinator,
    activity,
    tool_definition=None,
    on_result=None,
):
    results = []

    async def result_callback(result, *, properties=None):
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


async def complete_empty_generation(activity):
    await activity.model_generation_started()
    await activity.model_generation_completed()


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
    assert spoken == ["Секунду, проверяю."]
    gate.set()
    results = await execution
    await asyncio.gather(*state.tasks)

    assert results == [{"answer": "готово"}]
    assert state.executions == 1
    assert [control[0] for control in state.controls].count("tool_progress") == 1


@pytest.mark.asyncio
async def test_identical_inflight_read_calls_share_execution_progress_and_continuation():
    gate = asyncio.Event()
    state = FakeState(result={"deals": [{"id": 386}]}, gate=gate)
    activity = ConversationActivity()
    spoken = []
    first_results = []
    duplicate_results = []
    duplicate_properties = []

    async def speak(message):
        spoken.append(message)

    async def first_callback(result, *, properties=None):
        first_results.append(result)
        await activity.bot_started()

    async def duplicate_callback(result, *, properties=None):
        duplicate_results.append(result)
        duplicate_properties.append(properties)

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(tool_start_after_ms=5, tool_delay_after_ms=5_000),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=speak, run_instruction=speak)
    tool = definition("search_deals")
    first = asyncio.create_task(
        coordinator.execute(
            tool,
            Params(
                arguments={"contact_id": "2179", "limit": 10},
                tool_call_id="search-1",
                result_callback=first_callback,
            ),
        )
    )
    duplicate = asyncio.create_task(
        coordinator.execute(
            tool,
            Params(
                arguments={"contact_id": "2179", "limit": 10},
                tool_call_id="search-2",
                result_callback=duplicate_callback,
            ),
        )
    )

    await asyncio.sleep(0.03)
    assert state.executions == 1
    assert len(spoken) == 1
    gate.set()
    await asyncio.gather(first, duplicate)
    await asyncio.gather(*state.tasks)

    expected = {
        "status": "ok",
        "total_count": 1,
        "returned_count": 1,
        "deals": [{"id": 386}],
    }
    assert first_results == duplicate_results == [expected]
    assert duplicate_properties[0].run_llm is False
    assert state.executions == 1
    assert [control[0] for control in state.controls].count("tool_progress") == 1
    assert [control[0] for control in state.controls].count("tool_suppressed") == 1


@pytest.mark.asyncio
async def test_ready_tool_result_finishes_started_progress_without_global_interruption():
    tool_gate = asyncio.Event()
    speech_started = asyncio.Event()
    speech_finished = asyncio.Event()
    result_delivered = asyncio.Event()
    state = FakeState(gate=tool_gate)
    activity = ConversationActivity()
    spoken = []
    interruptions = []

    async def speak(message):
        spoken.append(message)
        await activity.bot_started()
        speech_started.set()
        await speech_finished.wait()
        await activity.bot_stopped()
        return True

    async def interrupt():
        interruptions.append(True)

    async def on_result(_result):
        result_delivered.set()
        await activity.bot_started()

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(tool_start_after_ms=5, tool_delay_after_ms=5_000),
        state=state,
        activity=activity,
    )
    coordinator.bind(
        speak_exact=speak,
        speak_result=speak,
        run_instruction=speak,
        interrupt_generation=interrupt,
    )
    execution = asyncio.create_task(execute_with_answer(coordinator, activity, on_result=on_result))

    await asyncio.wait_for(speech_started.wait(), timeout=0.1)
    tool_gate.set()
    await asyncio.sleep(0)

    assert result_delivered.is_set() is False
    assert interruptions == []

    speech_finished.set()
    results = await asyncio.wait_for(execution, timeout=0.2)
    await asyncio.gather(*state.tasks)

    assert results == [{"answer": "готово"}]
    assert spoken == ["Секунду, проверяю."]
    assert interruptions == []


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
    execution = asyncio.create_task(
        execute_with_answer(coordinator, activity, definition("create_deal"))
    )

    await asyncio.sleep(0.03)
    gate.set()
    await execution
    await asyncio.gather(*state.tasks)

    assert spoken == [
        "Создаю сделку, это займёт немного времени.",
        "Ещё создаю сделку, почти готово.",
    ]


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
async def test_end_call_speaks_closing_message_once_before_the_terminal_action():
    state = FakeState(result={"action": "end_call"})
    activity = ConversationActivity()
    spoken = []

    async def speak(message):
        spoken.append(message)
        return True

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(closing_message="Спасибо за звонок. До свидания!"),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=speak, run_instruction=speak)

    results = await execute_with_answer(coordinator, activity, definition("end_call"))
    duplicate = await coordinator.execute_end_call({}, "duplicate-end-call", 5_000)

    assert results == [{"action": "end_call"}]
    assert duplicate == {"action": "end_call"}
    assert spoken == ["Спасибо за звонок. До свидания!"]
    assert state.executions == 1
    assert state.termination_requested is True
    assert state.events == [("closing_message_completed", {"spoken": True})]


@pytest.mark.asyncio
async def test_end_call_does_not_wait_indefinitely_for_closing_speech(monkeypatch):
    monkeypatch.setattr("app.pipeline.tool_dialogue.CLOSING_SPEECH_MAX_SECONDS", 0.01)
    state = FakeState(result={"action": "end_call"})
    activity = ConversationActivity()

    async def stalled_speech(_message):
        await asyncio.Event().wait()

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(closing_message="Спасибо за звонок. До свидания!"),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=stalled_speech, run_instruction=stalled_speech)

    result = await asyncio.wait_for(
        coordinator.execute_end_call({}, "end-call-timeout", 5_000),
        timeout=0.1,
    )
    await asyncio.gather(*state.tasks)

    assert result == {"action": "end_call"}
    assert state.executions == 1
    assert state.events == [("closing_message_completed", {"spoken": False})]


@pytest.mark.asyncio
async def test_slow_gemini_tool_returns_pending_then_injects_late_result_once():
    gate = asyncio.Event()
    state = FakeState(gate=gate)
    activity = ConversationActivity()
    instructions = []

    async def record_instruction(message):
        instructions.append(message)

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(
            provider="gemini-live",
            tool_foreground_wait_ms=5,
            tool_delay_after_ms=5,
        ),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=record_instruction, run_instruction=record_instruction)
    results = await execute_with_answer(
        coordinator,
        activity,
        tool_definition=definition("create_deal", foreground_wait_ms=100),
        on_result=lambda _result: asyncio.sleep(0),
    )

    assert results == [
        {
            "status": "pending",
            "runtime_owned_progress": True,
            "background_activity": "создание сделки",
            "tool_call_id": "tool-1",
        }
    ]
    await asyncio.sleep(0.02)
    assert instructions == ["Ещё создаю сделку, почти готово."]
    gate.set()
    while pending := [task for task in state.tasks if not task.done()]:
        await asyncio.gather(*pending)

    assert state.executions == 1
    assert len(instructions) == 2
    assert "создание сделки" in instructions[1]
    assert '"answer": "готово"' in instructions[1]
    assert [control[0] for control in state.controls].count("tool_progress") == 2
    assert {
        control[1]["activity"] for control in state.controls if control[0] == "tool_progress"
    } == {"создание сделки"}
    assert [control[0] for control in state.controls].count("tool_async_completed") == 1


@pytest.mark.asyncio
async def test_slow_gemini_tool_waits_for_pending_model_generation_before_late_result():
    gate = asyncio.Event()
    state = FakeState(gate=gate)
    activity = ConversationActivity()
    instructions = []

    async def record_instruction(message):
        instructions.append(message)

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(
            provider="gemini-live",
            tool_foreground_wait_ms=5,
            tool_delay_after_ms=1_000,
            post_tool_continuation_ms=100,
        ),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=record_instruction, run_instruction=record_instruction)
    results = await execute_with_answer(
        coordinator,
        activity,
        tool_definition=definition("create_deal"),
        on_result=lambda _result: asyncio.sleep(0),
    )

    assert results[0]["status"] == "pending"
    await activity.model_generation_started()
    gate.set()
    await asyncio.sleep(0.03)
    assert instructions == []

    await activity.model_generation_completed()
    while pending := [task for task in state.tasks if not task.done()]:
        await asyncio.gather(*pending)

    assert len(instructions) == 1
    assert "создание сделки" in instructions[0]


@pytest.mark.asyncio
async def test_fast_gemini_tool_returns_actual_result_without_pending():
    state = FakeState()
    activity = ConversationActivity()
    instructions = []

    async def record_instruction(message):
        instructions.append(message)

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(provider="gemini-live", tool_foreground_wait_ms=50),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=record_instruction, run_instruction=record_instruction)

    results = await execute_with_answer(
        coordinator,
        activity,
        tool_definition=definition(foreground_wait_ms=100),
    )
    await asyncio.gather(*state.tasks)

    assert results == [{"answer": "готово"}]
    assert state.executions == 1
    assert all(control[0] != "tool_progress" for control in state.controls)


@pytest.mark.asyncio
async def test_gemini_tool_without_explicit_foreground_policy_uses_runtime_window():
    gate = asyncio.Event()
    state = FakeState(gate=gate)
    activity = ConversationActivity()
    spoken = []

    async def record(message):
        spoken.append(message)

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(provider="gemini-live", tool_foreground_wait_ms=5),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=record, run_instruction=record)
    results = await execute_with_answer(
        coordinator,
        activity,
        tool_definition=definition("create_deal"),
        on_result=lambda _result: asyncio.sleep(0),
    )

    assert results == [
        {
            "status": "pending",
            "runtime_owned_progress": True,
            "background_activity": "создание сделки",
            "tool_call_id": "tool-1",
        }
    ]
    gate.set()
    while pending := [task for task in state.tasks if not task.done()]:
        await asyncio.gather(*pending)

    assert state.executions == 1
    assert any(control[0] == "tool_progress" for control in state.controls)
    assert len(spoken) == 1
    assert "создание сделки" in spoken[0]


@pytest.mark.asyncio
async def test_late_result_instructions_are_serialized():
    state = FakeState()
    activity = ConversationActivity()
    instructions = []
    in_flight = 0
    max_in_flight = 0

    async def run_instruction(message):
        nonlocal in_flight, max_in_flight
        in_flight += 1
        max_in_flight = max(max_in_flight, in_flight)
        instructions.append(message)
        await asyncio.sleep(0.02)
        await activity.bot_started()
        await activity.bot_stopped()
        in_flight -= 1

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(provider="gemini-live", post_tool_continuation_ms=100),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=run_instruction, run_instruction=run_instruction)

    await asyncio.gather(
        coordinator._run_late_instruction("result A"),
        coordinator._run_late_instruction("result B"),
    )

    assert instructions == ["result A", "result B"]
    assert max_in_flight == 1


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

    assert spoken == ["Создаю данные, это займёт немного времени."]
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
        on_result=lambda _result: complete_empty_generation(activity),
    )
    assert coordinator.awaiting_continuation is True
    await asyncio.gather(*state.tasks)

    assert results == [{"answer": "готово"}]
    assert coordinator.awaiting_continuation is False
    assert len(instructions) == 1
    assert "проверка информации" in instructions[0]
    assert '"answer": "готово"' in instructions[0]
    assert "не вызывай тот же инструмент повторно" in instructions[0].lower()
    assert any(control[0] == "post_tool_model_stall" for control in state.controls)


@pytest.mark.asyncio
async def test_post_tool_stall_does_not_overlap_active_original_generation():
    state = FakeState()
    activity = ConversationActivity()
    instructions = []

    async def record(message):
        instructions.append(message)

    async def start_original_generation(_result):
        await activity.model_generation_started()

    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(speak_exact=record, run_instruction=record)
    await execute_with_answer(
        coordinator,
        activity,
        on_result=start_original_generation,
    )

    await asyncio.sleep(0.15)
    assert instructions == []
    assert coordinator.awaiting_continuation is True

    await activity.model_output_generated()
    await activity.model_generation_completed()
    await asyncio.gather(*state.tasks)

    assert instructions == []
    assert coordinator.awaiting_continuation is False
    assert any(
        control[1].get("recovery") == "skipped_original_output_generated"
        for control in state.controls
        if control[0] == "post_tool_model_stall"
    )


@pytest.mark.asyncio
async def test_active_post_tool_generation_is_interrupted_and_result_is_spoken(monkeypatch):
    monkeypatch.setattr(tool_dialogue_module, "POST_TOOL_GENERATION_MAX_SECONDS", 0.02)
    state = FakeState(result={"message": "Контакт создан"})
    activity = ConversationActivity()
    spoken = []
    interruptions = []

    async def record(message):
        spoken.append(message)

    async def interrupt():
        interruptions.append(True)
        await activity.model_generation_interrupted()

    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(
        speak_exact=record,
        speak_result=record,
        run_instruction=record,
        interrupt_generation=interrupt,
    )
    await execute_with_answer(
        coordinator,
        activity,
        tool_definition=definition("create_contact"),
        on_result=lambda _result: activity.model_generation_started(),
    )
    await asyncio.gather(*state.tasks)

    assert interruptions == [True]
    assert spoken == ["Контакт создан"]
    assert any(
        control[1].get("recovery") == "interrupting_generation_timeout"
        for control in state.controls
        if control[0] == "post_tool_model_stall"
    )


@pytest.mark.asyncio
async def test_faq_result_is_spoken_directly_without_second_llm_generation():
    answer = "OneLink автоматизирует продажи и общение с клиентами."
    state = FakeState(result={"matches": [{"id": 107, "answer": answer}]})
    activity = ConversationActivity()
    spoken = []
    callback_properties = []

    async def speak_result(message):
        spoken.append(message)
        return True

    async def result_callback(_result, *, properties=None):
        callback_properties.append(properties)
        await properties.on_context_updated()

    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(
        speak_exact=speak_result,
        speak_result=speak_result,
        run_instruction=speak_result,
    )
    params = Params(
        arguments={"query": "Какие услуги у вас?"},
        tool_call_id="faq-1",
        result_callback=result_callback,
    )

    await coordinator.execute(definition("faq_lookup"), params)

    assert len(callback_properties) == 1
    assert callback_properties[0].run_llm is False
    while pending := [task for task in state.tasks if not task.done()]:
        await asyncio.gather(*pending)
    assert spoken == [answer]
    assert coordinator.awaiting_continuation is False


@pytest.mark.asyncio
async def test_faq_result_speaks_after_bounded_context_barrier_timeout(monkeypatch):
    monkeypatch.setattr(
        tool_dialogue_module,
        "DIRECT_RESULT_CONTEXT_CALLBACK_TIMEOUT_SECONDS",
        0.01,
    )
    answer = "OneLink автоматизирует продажи и общение с клиентами."
    state = FakeState(result={"matches": [{"id": 107, "answer": answer}]})
    activity = ConversationActivity()
    spoken = []
    callback_properties = []

    async def speak_result(message):
        spoken.append(message)
        return True

    async def result_callback(_result, *, properties=None):
        callback_properties.append(properties)

    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(
        speak_exact=speak_result,
        speak_result=speak_result,
        run_instruction=speak_result,
    )
    params = Params(
        arguments={"query": "Какой у вас слоган?"},
        tool_call_id="faq-recovery",
        result_callback=result_callback,
    )

    await coordinator.execute(definition("faq_lookup"), params)
    while pending := [task for task in state.tasks if not task.done()]:
        await asyncio.gather(*pending)

    assert spoken == [answer]
    assert any(control[0] == "direct_tool_context_barrier_timeout" for control in state.controls)

    # A late native callback is only a context barrier and cannot repeat speech.
    await callback_properties[0].on_context_updated()
    assert spoken == [answer]


@pytest.mark.asyncio
async def test_direct_faq_speech_does_not_block_parallel_tool_completion():
    answer = "OneLink автоматизирует продажи и общение с клиентами."
    speech_started = asyncio.Event()
    release_speech = asyncio.Event()
    callbacks = []

    class ParallelState(FakeState):
        async def execute_tool(self, name, _arguments, _tool_call_id, *, timeout_ms):
            assert timeout_ms > 0
            self.executions += 1
            if name == "faq_lookup":
                return {"matches": [{"answer": answer}]}
            return {"action": "transfer", "status": "completed"}

    state = ParallelState()
    activity = ConversationActivity()

    async def speak_result(_message):
        speech_started.set()
        await release_speech.wait()
        return True

    async def result_callback(result, *, properties=None):
        callbacks.append(result)
        if properties and properties.on_context_updated:
            await properties.on_context_updated()

    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(
        speak_exact=speak_result,
        speak_result=speak_result,
        run_instruction=speak_result,
    )
    faq_params = Params(
        arguments={"query": "Какие услуги у вас?"},
        tool_call_id="faq-parallel",
        result_callback=result_callback,
    )
    docs_params = Params(
        arguments={"query": "Документация"},
        tool_call_id="docs-parallel",
        result_callback=result_callback,
    )

    await asyncio.wait_for(
        asyncio.gather(
            coordinator.execute(definition("faq_lookup"), faq_params),
            coordinator.execute(definition("search_documentation"), docs_params),
        ),
        timeout=0.2,
    )

    assert len(callbacks) == 2
    assert state.executions == 2
    await asyncio.wait_for(speech_started.wait(), timeout=0.2)
    release_speech.set()
    while pending := [task for task in state.tasks if not task.done()]:
        await asyncio.gather(*pending)


@pytest.mark.asyncio
async def test_faq_result_defers_direct_speech_during_caller_barge_in():
    answer = "OneLink автоматизирует продажи и общение с клиентами."
    state = FakeState(result={"matches": [{"id": 107, "answer": answer}]})
    activity = ConversationActivity()
    activity.user_speaking = True
    spoken = []
    callback_properties = []

    async def result_callback(_result, *, properties=None):
        callback_properties.append(properties)
        await properties.on_context_updated()

    async def speak_result(message):
        spoken.append(message)

    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(
        speak_exact=speak_result,
        speak_result=speak_result,
        run_instruction=speak_result,
    )
    params = Params(
        arguments={"query": "Какие услуги у вас?"},
        tool_call_id="faq-2",
        result_callback=result_callback,
    )

    await coordinator.execute(definition("faq_lookup"), params)
    for _ in range(20):
        if any(control[0] == "direct_tool_speech_deferred" for control in state.controls):
            break
        await asyncio.sleep(0.01)

    assert spoken == []
    await activity.user_stopped()
    while pending := [task for task in state.tasks if not task.done()]:
        await asyncio.gather(*pending)

    assert spoken == [answer]
    assert any(control[0] == "direct_tool_speech_deferred" for control in state.controls)


@pytest.mark.asyncio
async def test_direct_result_from_superseded_caller_turn_is_not_spoken():
    gate = asyncio.Event()
    state = FakeState(result={"matches": [{"answer": "Устаревший ответ"}]}, gate=gate)
    activity = ConversationActivity()
    spoken = []

    async def result_callback(_result, *, properties=None):
        await properties.on_context_updated()

    async def speak_result(message):
        spoken.append(message)

    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(
        speak_exact=speak_result,
        speak_result=speak_result,
        run_instruction=speak_result,
    )
    params = Params(
        arguments={"query": "Первый вопрос"},
        tool_call_id="faq-stale",
        result_callback=result_callback,
    )
    execution = asyncio.create_task(coordinator.execute(definition("faq_lookup"), params))

    await asyncio.sleep(0)
    await activity.user_started()
    await activity.user_stopped()
    gate.set()
    await execution
    while pending := [task for task in state.tasks if not task.done()]:
        await asyncio.gather(*pending)

    assert spoken == []
    assert any(
        control[0] == "tool_speech_suppressed"
        and control[1].get("reason") == "caller_turn_superseded"
        for control in state.controls
    )


@pytest.mark.asyncio
async def test_progress_from_superseded_caller_turn_is_not_spoken():
    gate = asyncio.Event()
    state = FakeState(gate=gate)
    activity = ConversationActivity()
    spoken = []

    async def speak(message):
        spoken.append(message)

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(tool_start_after_ms=20, tool_delay_after_ms=5_000),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=speak, run_instruction=speak)
    execution = asyncio.create_task(execute_with_answer(coordinator, activity))

    await asyncio.sleep(0)
    await activity.user_started()
    await activity.user_stopped()
    await asyncio.sleep(0.03)
    gate.set()
    await execution
    await asyncio.gather(*state.tasks)

    assert spoken == []


@pytest.mark.asyncio
async def test_generic_result_from_superseded_turn_updates_context_without_running_llm():
    gate = asyncio.Event()
    state = FakeState(gate=gate)
    activity = ConversationActivity()
    callback_properties = []

    async def result_callback(_result, *, properties=None):
        callback_properties.append(properties)

    async def no_speech(_message):
        return None

    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(speak_exact=no_speech, run_instruction=no_speech)
    params = Params(
        arguments={"query": "Первый вопрос"},
        tool_call_id="generic-stale",
        result_callback=result_callback,
    )
    execution = asyncio.create_task(coordinator.execute(definition("account_check"), params))

    await asyncio.sleep(0)
    await activity.user_started()
    await activity.user_stopped()
    gate.set()
    await execution
    await asyncio.gather(*state.tasks)

    assert len(callback_properties) == 1
    assert callback_properties[0].run_llm is False


@pytest.mark.asyncio
async def test_gemini_late_result_from_superseded_turn_is_not_spoken():
    gate = asyncio.Event()
    state = FakeState(gate=gate)
    activity = ConversationActivity()
    instructions = []

    async def record(message):
        instructions.append(message)

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(provider="gemini-live", tool_foreground_wait_ms=5),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=record, run_instruction=record)
    results = await execute_with_answer(
        coordinator,
        activity,
        tool_definition=definition("create_deal"),
        on_result=lambda _result: asyncio.sleep(0),
    )
    assert results[0]["status"] == "pending"

    await activity.user_started()
    await activity.user_stopped()
    gate.set()
    while pending := [task for task in state.tasks if not task.done()]:
        await asyncio.gather(*pending)

    assert instructions == []
    assert any(control[0] == "tool_speech_suppressed" for control in state.controls)


@pytest.mark.asyncio
async def test_fast_faq_result_suppresses_obsolete_progress_phrase():
    state = FakeState(result={"matches": [{"answer": "Готовый ответ"}]})
    activity = ConversationActivity()
    progress = []

    async def speak_exact(message):
        progress.append(message)
        return True

    async def result_callback(_result, *, properties=None):
        await properties.on_context_updated()

    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(tool_start_after_ms=5),
        state=state,
        activity=activity,
    )
    coordinator.bind(
        speak_exact=speak_exact,
        speak_result=speak_exact,
        run_instruction=speak_exact,
    )
    params = Params(
        arguments={"query": "слоган"},
        tool_call_id="faq-fast",
        result_callback=result_callback,
    )

    await coordinator.execute(definition("faq_lookup", foreground_wait_ms=100), params)
    while pending := [task for task in state.tasks if not task.done()]:
        await asyncio.gather(*pending)

    assert progress == ["Готовый ответ"]
    assert not any(control[0] == "tool_progress" for control in state.controls)


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
        on_result=lambda _result: complete_empty_generation(activity),
    )
    await asyncio.gather(*state.tasks)

    assert spoken == ["Не получилось проверить автоматически. Могу соединить со специалистом."]


def test_pipeline_result_projection_keeps_names_and_ids_without_nested_noise():
    pipelines = [
        {
            "id": index,
            "name": f"Воронка {index}",
            "metadata": "x" * 2_000,
            "stages": [
                {"id": index * 10 + stage, "name": f"Этап {stage}", "raw": "x" * 1_000}
                for stage in range(3)
            ],
        }
        for index in range(4)
    ]
    result = {
        "action": "list_deal_pipelines",
        "result": json.dumps({"pipelines": pipelines}, ensure_ascii=False),
    }

    projected = _voice_result_projection("list_deal_pipelines", result)

    assert projected["count"] == 4
    assert [item["name"] for item in projected["pipelines"]] == [
        "Воронка 0",
        "Воронка 1",
        "Воронка 2",
        "Воронка 3",
    ]
    assert projected["pipelines"][0]["stages"][0] == {"id": 0, "name": "Этап 0"}
    assert "metadata" not in projected["pipelines"][0]
    assert len(json.dumps(projected, ensure_ascii=False)) <= 2_400


def test_faq_result_projection_keeps_real_answers():
    result = {
        "result": {
            "matches": [
                {
                    "id": 7,
                    "question": "Что такое OneLink?",
                    "answer": "OneLink объединяет каналы общения.",
                    "embedding": [0.1] * 2_000,
                },
                {
                    "id": 8,
                    "question": "Есть CRM?",
                    "answer": "Да, CRM встроена.",
                },
            ]
        }
    }

    projected = _voice_result_projection("faq_lookup", result)

    assert projected["count"] == 2
    assert projected["matches"][0]["answer"] == "OneLink объединяет каналы общения."
    assert projected["matches"][1]["answer"] == "Да, CRM встроена."
    assert "embedding" not in projected["matches"][0]


def test_search_deals_projection_keeps_titles_instead_of_raw_json_prefix():
    deals = [
        {
            "id": index,
            "title": f"Сделка {index}",
            "description": "Описание " + ("x" * 1_000),
            "pipeline_id": 2,
            "stage_id": 3,
            "primary_contact": {"phone_number": "+77000000000"},
            "custom_attributes": {"raw": "x" * 2_000},
        }
        for index in range(8)
    ]
    result = {
        "action": "captain_tool",
        "result": json.dumps(
            {"total_count": 8, "deals": deals},
            ensure_ascii=False,
        ),
    }

    projected = _voice_result_projection("search_deals", result)

    assert projected["total_count"] == 8
    assert projected["returned_count"] == 8
    assert [deal["title"] for deal in projected["deals"]] == [
        f"Сделка {index}" for index in range(8)
    ]
    assert "primary_contact" not in projected["deals"][0]
    assert "custom_attributes" not in projected["deals"][0]
    assert len(json.dumps(projected, ensure_ascii=False)) <= 2_400


def test_generic_voice_result_projection_is_hard_bounded():
    projected = _voice_result_projection(
        "custom_tool",
        {"status": "ok", "payload": [{"description": "x" * 5_000}] * 20},
    )

    assert len(json.dumps(projected, ensure_ascii=False)) <= 2_400


@pytest.mark.asyncio
async def test_causal_turn_is_captured_before_tool_started_can_yield():
    tool_started_entered = asyncio.Event()
    release_tool_started = asyncio.Event()
    state = FakeState(result={"answer": "актуальный ответ"})
    activity = ConversationActivity()
    spoken = []
    results = []
    original_tool_started = activity.tool_started

    async def delayed_tool_started():
        tool_started_entered.set()
        await release_tool_started.wait()
        await original_tool_started()

    async def speak_result(message):
        spoken.append(message)
        return True

    async def result_callback(result, *, properties=None):
        results.append(result)
        if properties is not None and properties.on_context_updated is not None:
            await properties.on_context_updated()

    activity.tool_started = delayed_tool_started
    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(
        speak_exact=speak_result,
        speak_result=speak_result,
        run_instruction=speak_result,
    )
    execution = asyncio.create_task(
        coordinator.execute(
            definition("faq_lookup"),
            Params(
                arguments={"query": "тариф"},
                tool_call_id="snapshot-1",
                result_callback=result_callback,
            ),
        )
    )

    await tool_started_entered.wait()
    await activity.user_started()
    await activity.user_stopped()
    release_tool_started.set()
    await execution
    await asyncio.gather(*state.tasks)

    assert results == [{"answer": "актуальный ответ"}]
    assert spoken == []
    assert any(control[0] == "tool_speech_suppressed" for control in state.controls)


@pytest.mark.asyncio
async def test_direct_speech_admission_rejects_turn_started_after_coordinator_check(
    monkeypatch,
):
    before_admission = asyncio.Event()
    release_admission = asyncio.Event()
    state = FakeState(result={"answer": "старый ответ"})
    activity = ConversationActivity()
    enqueued = []

    async def legacy_speak(_message):
        return True

    async def causal_speak(message, causal_user_turn):
        before_admission.set()
        await release_admission.wait()

        async def enqueue():
            enqueued.append(message)

        return await activity.admit_causal_side_effect(causal_user_turn, enqueue)

    async def result_callback(_result, *, properties=None):
        assert properties is not None
        assert properties.on_context_updated is not None
        await properties.on_context_updated()

    monkeypatch.setattr(tool_dialogue_module, "DIRECT_RESULT_SETTLE_SECONDS", 0)
    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(
        speak_exact=legacy_speak,
        speak_result=legacy_speak,
        run_instruction=legacy_speak,
        speak_exact_for_turn=causal_speak,
        speak_result_for_turn=causal_speak,
        run_instruction_for_turn=causal_speak,
    )

    await coordinator.execute(
        definition("faq_lookup"),
        Params(
            arguments={"query": "тариф"},
            tool_call_id="admission-tts",
            result_callback=result_callback,
        ),
    )
    await before_admission.wait()
    await activity.user_started()
    await activity.user_stopped()
    release_admission.set()
    await asyncio.gather(*state.tasks)

    assert enqueued == []


@pytest.mark.asyncio
async def test_late_instruction_admission_rejects_turn_started_after_coordinator_check():
    before_admission = asyncio.Event()
    release_admission = asyncio.Event()
    state = FakeState()
    activity = ConversationActivity()
    enqueued = []

    async def legacy_speak(_message):
        return True

    async def causal_instruction(message, causal_user_turn):
        before_admission.set()
        await release_admission.wait()

        async def enqueue():
            enqueued.append(message)

        return await activity.admit_causal_side_effect(causal_user_turn, enqueue)

    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(
        speak_exact=legacy_speak,
        run_instruction=legacy_speak,
        run_instruction_for_turn=causal_instruction,
    )
    instruction = asyncio.create_task(
        coordinator._run_late_instruction(
            "Озвучь старый результат.",
            causal_user_turn=activity.user_turns_started,
        )
    )

    await before_admission.wait()
    await activity.user_started()
    await activity.user_stopped()
    release_admission.set()
    await instruction

    assert enqueued == []


@pytest.mark.asyncio
async def test_generic_result_admission_falls_back_to_context_only_after_new_turn():
    before_admission = asyncio.Event()
    release_admission = asyncio.Event()
    state = FakeState(result={"status": "ok", "balance": 10})
    activity = ConversationActivity()
    callback_properties = []
    original_admission = activity.admit_causal_side_effect

    async def delayed_admission(causal_user_turn, side_effect):
        before_admission.set()
        await release_admission.wait()
        return await original_admission(causal_user_turn, side_effect)

    async def no_speech(_message):
        return True

    async def result_callback(_result, *, properties=None):
        callback_properties.append(properties)

    activity.admit_causal_side_effect = delayed_admission
    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    coordinator.bind(speak_exact=no_speech, run_instruction=no_speech)
    execution = asyncio.create_task(
        coordinator.execute(
            definition("account_check"),
            Params(
                arguments={},
                tool_call_id="admission-generic",
                result_callback=result_callback,
            ),
        )
    )

    await before_admission.wait()
    await activity.user_started()
    await activity.user_stopped()
    release_admission.set()
    await execution
    await asyncio.gather(*state.tasks)

    assert len(callback_properties) == 1
    assert callback_properties[0] is not None
    assert callback_properties[0].run_llm is False
    assert coordinator.awaiting_continuation is False


@pytest.mark.asyncio
async def test_result_callback_timeout_falls_back_without_running_llm(monkeypatch):
    state = FakeState()
    activity = ConversationActivity()
    coordinator = ToolDialogueCoordinator(ai=ai_settings(), state=state, activity=activity)
    callback_properties = []
    callback_calls = 0
    stalled = asyncio.Event()

    async def result_callback(_result, *, properties=None):
        nonlocal callback_calls
        callback_calls += 1
        if callback_calls == 1:
            await stalled.wait()
        callback_properties.append(properties)

    monkeypatch.setattr("app.pipeline.processors.CAUSAL_SIDE_EFFECT_TIMEOUT_SECONDS", 0.01)
    admitted = await coordinator._deliver_result_callback_causally(
        definition("account_check"),
        Params(arguments={}, tool_call_id="callback-timeout", result_callback=result_callback),
        {"status": "completed"},
        activity.user_turns_started,
    )

    assert admitted is False
    assert callback_calls == 2
    assert callback_properties[0] is not None
    assert callback_properties[0].run_llm is False


@pytest.mark.asyncio
async def test_stale_gemini_pending_result_is_delivered_without_running_llm():
    before_admission = asyncio.Event()
    release_admission = asyncio.Event()
    tool_gate = asyncio.Event()
    state = FakeState(gate=tool_gate)
    activity = ConversationActivity()
    callback_properties = []
    original_admission = activity.admit_causal_side_effect

    async def delayed_admission(causal_user_turn, side_effect):
        before_admission.set()
        await release_admission.wait()
        return await original_admission(causal_user_turn, side_effect)

    async def no_speech(_message):
        return True

    async def result_callback(_result, *, properties=None):
        callback_properties.append(properties)

    activity.admit_causal_side_effect = delayed_admission
    coordinator = ToolDialogueCoordinator(
        ai=ai_settings(provider="gemini-live", tool_foreground_wait_ms=5),
        state=state,
        activity=activity,
    )
    coordinator.bind(speak_exact=no_speech, run_instruction=no_speech)
    execution = asyncio.create_task(
        coordinator.execute(
            definition("create_deal"),
            Params(
                arguments={},
                tool_call_id="stale-gemini-pending",
                result_callback=result_callback,
            ),
        )
    )

    await before_admission.wait()
    await activity.user_started()
    await activity.user_stopped()
    release_admission.set()
    await execution
    tool_gate.set()
    while pending := [task for task in state.tasks if not task.done()]:
        await asyncio.gather(*pending)

    assert len(callback_properties) == 1
    assert callback_properties[0] is not None
    assert callback_properties[0].run_llm is False
    assert coordinator.awaiting_continuation is False
