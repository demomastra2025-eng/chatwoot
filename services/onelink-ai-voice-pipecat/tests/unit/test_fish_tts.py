import asyncio
from collections import deque
from unittest.mock import AsyncMock

import ormsgpack
import pytest
from pipecat.frames.frames import (
    InterruptionFrame,
    TTSAudioRawFrame,
)
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.fish.tts import FishAudioTTSService

from app.services.fish_tts import OneLinkFishAudioTTSService


class FakeWebsocket:
    def __init__(self, messages):
        self._messages = iter(messages)

    def __aiter__(self):
        return self

    async def __anext__(self):
        try:
            return next(self._messages)
        except StopIteration as exc:
            raise StopAsyncIteration from exc


class SendWebsocket:
    def __init__(self, *, on_flush=None, fail_once=False):
        self.sent = []
        self._on_flush = on_flush
        self._fail_once = fail_once

    async def send(self, message):
        if self._fail_once:
            self._fail_once = False
            raise ConnectionError("connection dropped")
        self.sent.append(ormsgpack.unpackb(message))
        if self.sent[-1].get("event") == "flush" and self._on_flush is not None:
            self._on_flush()


def build_service():
    service = OneLinkFishAudioTTSService(
        api_key="fish-secret",
        sample_rate=8_000,
        settings=OneLinkFishAudioTTSService.Settings(
            model="s2-pro",
            voice="voice-ref",
        ),
    )
    service.start_ttfb_metrics = AsyncMock()
    service.start_tts_usage_metrics = AsyncMock()
    return service


def signal_first_audio(service):
    service._transactions[0].first_audio_event.set()


def enqueue_transaction(service, context_id):
    transaction = service._build_transaction("текст", context_id, service._interruption_epoch)
    service._enqueue_transaction(transaction)
    return transaction


@pytest.mark.asyncio
@pytest.mark.parametrize("size", [1, 1024, 1025])
async def test_fish_tts_preserves_every_non_empty_audio_chunk(size):
    service = OneLinkFishAudioTTSService(
        api_key="fish-secret",
        sample_rate=8_000,
        settings=OneLinkFishAudioTTSService.Settings(
            model="s2-pro",
            voice="voice-ref",
        ),
    )
    service._websocket = FakeWebsocket(
        [ormsgpack.packb({"event": "audio", "audio": b"a" * size})]
    )
    service._sample_rate = service._init_sample_rate
    enqueue_transaction(service, "ctx")
    service.append_to_audio_context = AsyncMock()
    service.stop_ttfb_metrics = AsyncMock()

    await service._receive_messages()

    service.append_to_audio_context.assert_awaited_once()
    context_id, frame = service.append_to_audio_context.await_args.args
    assert context_id == "ctx"
    assert isinstance(frame, TTSAudioRawFrame)
    assert frame.audio == b"a" * size
    assert frame.sample_rate == 8_000
    assert frame.context_id == "ctx"
    service.stop_ttfb_metrics.assert_awaited_once()


@pytest.mark.asyncio
async def test_fish_tts_ignores_empty_audio_chunk():
    service = OneLinkFishAudioTTSService(
        api_key="fish-secret",
        settings=OneLinkFishAudioTTSService.Settings(voice="voice-ref"),
    )
    service._websocket = FakeWebsocket(
        [ormsgpack.packb({"event": "audio", "audio": b""})]
    )
    service.append_to_audio_context = AsyncMock()

    await service._receive_messages()

    service.append_to_audio_context.assert_not_awaited()


@pytest.mark.asyncio
async def test_fish_tts_sends_text_and_flush_as_one_synthesis_transaction():
    service = build_service()
    websocket = SendWebsocket(on_flush=lambda: signal_first_audio(service))
    service._websocket = websocket

    frames = service.run_tts("Здравствуйте", "ctx")
    assert await anext(frames) is None

    assert websocket.sent == [
        {"event": "text", "text": "Здравствуйте", "normalize": True},
        {"event": "flush"},
    ]
    service.start_tts_usage_metrics.assert_awaited_once_with("Здравствуйте")


@pytest.mark.asyncio
async def test_fish_tts_reconnects_and_replays_when_first_audio_times_out():
    service = build_service()
    service.FIRST_AUDIO_TIMEOUT_SECONDS = 0.01
    first_websocket = SendWebsocket()
    replay_websocket = SendWebsocket(on_flush=lambda: signal_first_audio(service))
    service._websocket = first_websocket

    async def reconnect(**_kwargs):
        service._websocket = replay_websocket
        return True

    service._restart_connection = AsyncMock(side_effect=reconnect)

    frames = service.run_tts("Повторите, пожалуйста", "ctx")
    assert await anext(frames) is None

    service._restart_connection.assert_awaited_once()
    assert first_websocket.sent[-1] == {"event": "flush"}
    assert replay_websocket.sent == first_websocket.sent


@pytest.mark.asyncio
async def test_fish_tts_replays_whole_transaction_after_send_failure():
    service = build_service()
    failed_websocket = SendWebsocket(fail_once=True)
    replay_websocket = SendWebsocket(on_flush=lambda: signal_first_audio(service))
    service._websocket = failed_websocket

    async def reconnect(**_kwargs):
        service._websocket = replay_websocket
        return True

    service._restart_connection = AsyncMock(side_effect=reconnect)

    frames = service.run_tts("Секунду", "ctx")
    assert await anext(frames) is None

    assert replay_websocket.sent == [
        {"event": "text", "text": "Секунду", "normalize": True},
        {"event": "flush"},
    ]


@pytest.mark.asyncio
async def test_fish_tts_never_replays_text_cancelled_by_real_interruption(monkeypatch):
    service = build_service()
    websocket = SendWebsocket()
    service._websocket = websocket
    base_interruption = AsyncMock()
    monkeypatch.setattr(FishAudioTTSService, "_handle_interruption", base_interruption)
    service._restart_connection = AsyncMock(return_value=True)

    frames = service.run_tts("Эта реплика отменена", "ctx")
    pending_frame = asyncio.create_task(anext(frames))
    await asyncio.sleep(0)
    await service._handle_interruption(InterruptionFrame(), FrameDirection.DOWNSTREAM)
    with pytest.raises(StopAsyncIteration):
        await pending_frame

    base_interruption.assert_awaited_once()
    service._restart_connection.assert_awaited_once()
    assert len(websocket.sent) == 2


@pytest.mark.asyncio
async def test_restart_connection_uses_full_service_lifecycle():
    service = build_service()
    service._disconnect = AsyncMock()
    service._connect = AsyncMock()

    assert await service._restart_connection() is True

    service._disconnect.assert_awaited_once()
    service._connect.assert_awaited_once()


@pytest.mark.asyncio
async def test_receive_loop_binds_audio_to_each_transaction_until_finish():
    service = build_service()
    first = enqueue_transaction(service, "ctx-1")
    second = enqueue_transaction(service, "ctx-2")
    service._websocket = FakeWebsocket(
        [
            ormsgpack.packb({"event": "audio", "audio": b"first"}),
            ormsgpack.packb({"event": "finish", "reason": "done"}),
            ormsgpack.packb({"event": "audio", "audio": b"second"}),
            ormsgpack.packb({"event": "finish", "reason": "done"}),
        ]
    )
    service._sample_rate = service._init_sample_rate
    service.append_to_audio_context = AsyncMock()
    service.stop_ttfb_metrics = AsyncMock()

    await service._receive_messages()

    contexts = [call.args[0] for call in service.append_to_audio_context.await_args_list]
    assert contexts == ["ctx-1", "ctx-2"]
    assert first.first_audio_event.is_set()
    assert second.ready_event.is_set()
    assert second.first_audio_event.is_set()
    assert service._transactions == deque()
