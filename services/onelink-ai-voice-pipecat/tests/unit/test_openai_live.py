from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from pipecat.frames.frames import (
    FunctionCallCancelFrame,
    FunctionCallResultFrame,
    FunctionCallResultProperties,
)
from pipecat.services.openai.live.events import (
    ResponseCreateEvent,
    ResponseItemCreateEvent,
    SessionResource,
    SessionStartedEvent,
)

from app.services.openai_live import OneLinkOpenAILiveLLMService


def _service() -> OneLinkOpenAILiveLLMService:
    service = OneLinkOpenAILiveLLMService(
        api_key="test-key",
        settings=OneLinkOpenAILiveLLMService.Settings(model="gpt-live-1", voice="marin"),
    )
    service.send_client_event = AsyncMock()
    return service


def _result(call_id: str, *, run_llm: bool | None) -> FunctionCallResultFrame:
    properties = FunctionCallResultProperties(run_llm=run_llm) if run_llm is not None else None
    return FunctionCallResultFrame(
        function_name="lookup",
        tool_call_id=call_id,
        arguments={},
        result={"status": "completed"},
        properties=properties,
    )


def _register_calls(
    service: OneLinkOpenAILiveLLMService,
    *call_ids: str,
    response_key: str = "response-1",
) -> None:
    service._open_function_calls.update(dict.fromkeys(call_ids, response_key))
    service._pending_responses[response_key] = SimpleNamespace(
        call_ids=set(call_ids),
        had_calls=True,
        finished=True,
    )


@pytest.mark.asyncio
async def test_session_started_speaks_opening_instruction_as_commentary() -> None:
    service = _service()
    service._opening_instruction = "Поздоровайся сейчас."
    service._maybe_send_tools_update = AsyncMock()
    service._call_event_handler = AsyncMock()
    service._send_context_append = AsyncMock()

    await service._handle_evt_session_started(
        SessionStartedEvent(
            type="session.started",
            session=SessionResource(id="session-1"),
        )
    )

    service._send_context_append.assert_awaited_once_with(None, "Поздоровайся сейчас.", spoken=True)
    assert service._opening_instruction is None


@pytest.mark.asyncio
async def test_explicitly_suppressed_result_does_not_continue_response() -> None:
    service = _service()
    _register_calls(service, "call-1")

    await service._handle_function_call_result(_result("call-1", run_llm=False))

    events = [call.args[0] for call in service.send_client_event.await_args_list]
    assert len(events) == 1
    assert isinstance(events[0], ResponseItemCreateEvent)
    assert "response-1" not in service._pending_responses


@pytest.mark.asyncio
async def test_default_result_continues_response() -> None:
    service = _service()
    _register_calls(service, "call-1")

    await service._handle_function_call_result(_result("call-1", run_llm=None))

    events = [call.args[0] for call in service.send_client_event.await_args_list]
    assert [type(event) for event in events] == [ResponseItemCreateEvent, ResponseCreateEvent]


@pytest.mark.asyncio
async def test_parallel_response_continues_when_any_result_requests_it() -> None:
    service = _service()
    _register_calls(service, "call-1", "call-2")

    await service._handle_function_call_result(_result("call-1", run_llm=False))
    await service._handle_function_call_result(_result("call-2", run_llm=True))

    events = [call.args[0] for call in service.send_client_event.await_args_list]
    assert [type(event) for event in events] == [
        ResponseItemCreateEvent,
        ResponseItemCreateEvent,
        ResponseCreateEvent,
    ]


@pytest.mark.asyncio
async def test_parallel_response_stays_suppressed_when_all_results_disable_it() -> None:
    service = _service()
    _register_calls(service, "call-1", "call-2")

    await service._handle_function_call_result(_result("call-1", run_llm=False))
    await service._handle_function_call_result(_result("call-2", run_llm=False))

    events = [call.args[0] for call in service.send_client_event.await_args_list]
    assert [type(event) for event in events] == [
        ResponseItemCreateEvent,
        ResponseItemCreateEvent,
    ]
    assert "response-1" not in service._pending_responses


@pytest.mark.asyncio
async def test_parallel_timeout_cancellation_requests_continuation() -> None:
    service = _service()
    _register_calls(service, "call-1", "call-2")

    await service._handle_function_call_result(_result("call-1", run_llm=False))
    await service._handle_function_call_cancel(
        FunctionCallCancelFrame(
            function_name="lookup",
            tool_call_id="call-2",
            run_llm=True,
        )
    )

    events = [call.args[0] for call in service.send_client_event.await_args_list]
    assert [type(event) for event in events] == [
        ResponseItemCreateEvent,
        ResponseItemCreateEvent,
        ResponseCreateEvent,
    ]


@pytest.mark.asyncio
async def test_cancellation_without_inference_stays_suppressed() -> None:
    service = _service()
    _register_calls(service, "call-1")

    await service._handle_function_call_cancel(
        FunctionCallCancelFrame(function_name="lookup", tool_call_id="call-1")
    )

    events = [call.args[0] for call in service.send_client_event.await_args_list]
    assert [type(event) for event in events] == [ResponseItemCreateEvent]


@pytest.mark.asyncio
async def test_disconnect_clears_continuation_policy_before_reusing_correlation_key() -> None:
    service = _service()
    _register_calls(service, "call-old", response_key="uncorrelated")
    service._pending_responses["uncorrelated"].finished = False
    await service._handle_function_call_result(_result("call-old", run_llm=True))
    assert service._response_continuation_requested == {"uncorrelated": True}

    await service._disconnect()
    assert service._response_continuation_requested == {}

    _register_calls(service, "call-new", response_key="uncorrelated")
    await service._handle_function_call_result(_result("call-new", run_llm=False))

    events = [call.args[0] for call in service.send_client_event.await_args_list]
    assert not any(isinstance(event, ResponseCreateEvent) for event in events)
