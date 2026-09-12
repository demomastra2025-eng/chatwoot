"""OneLink adapter for OpenAI Live provider-specific operations."""

from typing import Any

from pipecat.frames.frames import FunctionCallCancelFrame, FunctionCallResultFrame
from pipecat.services.openai.live.llm import OpenAILiveLLMService


class OneLinkOpenAILiveLLMService(OpenAILiveLLMService):
    """Expose bounded commentary and honor OneLink tool continuation policy."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self._response_continuation_requested: dict[str, bool] = {}

    async def send_commentary(self, text: str) -> None:
        """Append speakable context using Pipecat's token-aware chunking."""
        await self._send_context_append(None, text, spoken=True)

    async def _handle_function_call_result(self, frame: FunctionCallResultFrame) -> None:
        key = self._open_function_calls.get(frame.tool_call_id)
        is_final = frame.properties.is_final if frame.properties else True
        if key is not None and is_final:
            requested = _result_requests_continuation(frame)
            self._response_continuation_requested[key] = (
                self._response_continuation_requested.get(key, False) or requested
            )
        await super()._handle_function_call_result(frame)

    async def _handle_function_call_cancel(self, frame: FunctionCallCancelFrame) -> None:
        key = self._open_function_calls.get(frame.tool_call_id)
        if key is not None:
            self._response_continuation_requested[key] = (
                self._response_continuation_requested.get(key, False) or frame.run_llm
            )
        await super()._handle_function_call_cancel(frame)

    async def _disconnect(self) -> None:
        try:
            await super()._disconnect()
        finally:
            # Parent disconnect clears its response ledgers. Clear our
            # correlation-key policy even when teardown itself reports an error,
            # so a reconnect cannot inherit a previous session's decision.
            self._response_continuation_requested.clear()

    async def _maybe_continue_response(self, key: str) -> None:
        pending = self._pending_responses.get(key)
        if pending is None or not pending.finished or not pending.had_calls or pending.call_ids:
            return

        if self._response_continuation_requested.pop(key, True):
            await super()._maybe_continue_response(key)
            return

        # Every completed call in this delegated response explicitly disabled
        # inference. Their outputs still reach the provider/context, but no
        # response.create is emitted because OneLink speaks the result itself.
        del self._pending_responses[key]


def _result_requests_continuation(frame: FunctionCallResultFrame) -> bool:
    if frame.properties and frame.properties.run_llm is not None:
        return frame.properties.run_llm
    if frame.run_llm is not None:
        return frame.run_llm
    return True
