import asyncio
from unittest.mock import AsyncMock

import ormsgpack
import pytest
from pipecat.frames.frames import InterruptionFrame, TTSAudioRawFrame
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.fish.tts import FishAudioTTSService
from websockets.protocol import State

from app.services.fish_tts import OneLinkFishAudioTTSService


class FakeReceiveWebsocket:
    def __init__(self, messages):
        self._messages = iter(messages)

    def __aiter__(self):
        return self

    async def __anext__(self):
        try:
            return next(self._messages)
        except StopIteration as exc:
            raise StopAsyncIteration from exc


class FakeSendWebsocket:
    state = State.OPEN

    def __init__(self):
        self.sent = []

    async def send(self, message):
        self.sent.append(ormsgpack.unpackb(message))


def build_service():
    service = OneLinkFishAudioTTSService(
        api_key="fish-secret",
        sample_rate=8_000,
        settings=OneLinkFishAudioTTSService.Settings(
            model="s2.1-pro-free",
            voice="voice-ref",
        ),
    )
    service.stop_ttfb_metrics = AsyncMock()
    service.start_tts_usage_metrics = AsyncMock()
    return service


@pytest.mark.asyncio
@pytest.mark.parametrize("size", [1, 1024, 1025])
async def test_fish_tts_preserves_every_non_empty_audio_chunk(size):
    service = build_service()
    service._websocket = FakeReceiveWebsocket(
        [ormsgpack.packb({"event": "audio", "audio": b"a" * size})]
    )
    service._sample_rate = service._init_sample_rate
    service._turn_context_id = "ctx"
    service.append_to_audio_context = AsyncMock()

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
    service = build_service()
    service._websocket = FakeReceiveWebsocket(
        [ormsgpack.packb({"event": "audio", "audio": b""})]
    )
    service.append_to_audio_context = AsyncMock()

    await service._receive_messages()

    service.append_to_audio_context.assert_not_awaited()


@pytest.mark.asyncio
async def test_fish_tts_uses_native_non_blocking_flush_lifecycle():
    service = build_service()
    websocket = FakeSendWebsocket()
    service._websocket = websocket

    frames = service.run_tts("Здравствуйте", "ctx")
    assert await anext(frames) is None

    assert websocket.sent == [
        {"event": "text", "text": "Здравствуйте"},
        {"event": "flush"},
    ]
    service.start_tts_usage_metrics.assert_awaited_once_with("Здравствуйте")
    assert OneLinkFishAudioTTSService.run_tts is FishAudioTTSService.run_tts


@pytest.mark.asyncio
async def test_next_utterance_does_not_wait_for_per_flush_finish_event():
    service = build_service()
    websocket = FakeSendWebsocket()
    service._websocket = websocket

    first = service.run_tts("Секунду, проверяю.", "ctx-1")
    second = service.run_tts("Акына матата.", "ctx-2")

    assert await anext(first) is None
    assert await anext(second) is None
    assert websocket.sent == [
        {"event": "text", "text": "Секунду, проверяю."},
        {"event": "flush"},
        {"event": "text", "text": "Акына матата."},
        {"event": "flush"},
    ]


@pytest.mark.asyncio
async def test_pending_synthesis_reconnects_on_interruption(monkeypatch):
    service = build_service()
    service._audio_contexts = {"ctx": asyncio.Queue()}
    service._bot_speaking = False
    base_interruption = AsyncMock()
    monkeypatch.setattr(FishAudioTTSService, "_handle_interruption", base_interruption)
    service._restart_connection = AsyncMock(return_value=True)

    await service._handle_interruption(InterruptionFrame(), FrameDirection.DOWNSTREAM)

    base_interruption.assert_awaited_once()
    service._restart_connection.assert_awaited_once()


@pytest.mark.asyncio
async def test_playing_synthesis_uses_native_interruption_reconnect(monkeypatch):
    service = build_service()
    service._audio_contexts = {"ctx": asyncio.Queue()}
    service._bot_speaking = True
    base_interruption = AsyncMock()
    monkeypatch.setattr(FishAudioTTSService, "_handle_interruption", base_interruption)
    service._restart_connection = AsyncMock(return_value=True)

    await service._handle_interruption(InterruptionFrame(), FrameDirection.DOWNSTREAM)

    base_interruption.assert_awaited_once()
    service._restart_connection.assert_not_awaited()


@pytest.mark.asyncio
async def test_restart_connection_uses_full_service_lifecycle():
    service = build_service()
    service._disconnect = AsyncMock()
    service._connect = AsyncMock()

    assert await service._restart_connection() is True

    service._disconnect.assert_awaited_once()
    service._connect.assert_awaited_once()


def test_fish_tts_uses_short_safe_audio_idle_timeout():
    service = build_service()

    assert service._stop_frame_timeout_s == 1.5
