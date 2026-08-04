import asyncio
from unittest.mock import AsyncMock

import ormsgpack
import pytest
from pipecat.frames.frames import ErrorFrame, InterruptionFrame, TTSAudioRawFrame, TTSStoppedFrame
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


async def complete_with_first_audio(service, generator):
    pending = asyncio.create_task(anext(generator))
    for _ in range(20):
        if service._pending_first_audio is not None:
            service._pending_first_audio.set()
            result = await pending
            await generator.aclose()
            return result
        await asyncio.sleep(0)
    pending.cancel()
    raise AssertionError("Fish synthesis did not start")


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
async def test_fish_tts_sends_text_and_flush_then_waits_for_first_audio_only():
    service = build_service()
    websocket = FakeSendWebsocket()
    service._websocket = websocket

    frames = service.run_tts("Здравствуйте", "ctx")
    assert await complete_with_first_audio(service, frames) is None

    assert websocket.sent == [
        {"event": "text", "text": "Здравствуйте"},
        {"event": "flush"},
    ]
    service.start_tts_usage_metrics.assert_awaited_once_with("Здравствуйте")
    assert OneLinkFishAudioTTSService.run_tts is not FishAudioTTSService.run_tts


@pytest.mark.asyncio
async def test_next_utterance_does_not_wait_for_per_flush_finish_event():
    service = build_service()
    websocket = FakeSendWebsocket()
    service._websocket = websocket

    first = service.run_tts("Секунду, проверяю.", "ctx-1")
    second = service.run_tts("Акына матата.", "ctx-2")

    assert await complete_with_first_audio(service, first) is None
    assert await complete_with_first_audio(service, second) is None
    assert websocket.sent == [
        {"event": "text", "text": "Секунду, проверяю."},
        {"event": "flush"},
        {"event": "text", "text": "Акына матата."},
        {"event": "flush"},
    ]


@pytest.mark.asyncio
async def test_missing_first_audio_reconnects_and_replays_once():
    service = build_service()
    service.FIRST_AUDIO_TIMEOUT_SECONDS = 0.01
    websocket = FakeSendWebsocket()
    service._websocket = websocket
    service._restart_connection = AsyncMock(return_value=True)
    service._audio_contexts = {"ctx": asyncio.Queue()}

    frames = service.run_tts("Секунду, проверяю.", "ctx")
    pending = asyncio.create_task(anext(frames))
    first_event = None
    for _ in range(100):
        current_event = service._pending_first_audio
        if first_event is None and current_event is not None:
            first_event = current_event
        if (
            service._restart_connection.await_count == 1
            and current_event is not None
            and current_event is not first_event
        ):
            current_event.set()
            break
        await asyncio.sleep(0.002)

    assert await pending is None
    await frames.aclose()
    service._restart_connection.assert_awaited_once()
    assert websocket.sent == [
        {"event": "text", "text": "Секунду, проверяю."},
        {"event": "flush"},
        {"event": "text", "text": "Секунду, проверяю."},
        {"event": "flush"},
    ]


@pytest.mark.asyncio
async def test_missing_audio_after_replay_emits_bounded_nonfatal_error():
    service = build_service()
    service.FIRST_AUDIO_TIMEOUT_SECONDS = 0.005
    service._websocket = FakeSendWebsocket()
    service._restart_connection = AsyncMock(return_value=True)
    service._audio_contexts = {"ctx": asyncio.Queue()}

    frames = [frame async for frame in service.run_tts("Проверка", "ctx")]

    assert len(frames) == 2
    assert isinstance(frames[0], ErrorFrame)
    assert frames[0].fatal is False
    assert isinstance(frames[1], TTSStoppedFrame)


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
