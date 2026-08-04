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
    execution = asyncio.create_task(
        execute_with_answer(coordinator, activity, on_result=on_result)
    )

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
        control[1]["activity"]
        for control in state.controls
        if control[0] == "tool_progress"
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
        "DIRECT_RESULT_CONTEXT_BARRIER_TIMEOUT_SECONDS",
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
    assert any(
        control[0] == "direct_tool_context_barrier_timeout"
        for control in state.controls
    )

    # A late native callback is only a context barrier and cannot repeat speech.
    await callback_properties[0].on_context_updated()
    assert spoken == [answer]


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
    while pending := [task for task in state.tasks if not task.done()]:
        await asyncio.gather(*pending)

    assert spoken == []
    assert any(control[0] == "direct_tool_speech_deferred" for control in state.controls)


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


def test_generic_voice_result_projection_is_hard_bounded():
    projected = _voice_result_projection(
        "custom_tool",
        {"status": "ok", "payload": [{"description": "x" * 5_000}] * 20},
    )

    assert len(json.dumps(projected, ensure_ascii=False)) <= 2_400
