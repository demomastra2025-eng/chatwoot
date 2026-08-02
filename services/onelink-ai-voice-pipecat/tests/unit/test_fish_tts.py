from unittest.mock import AsyncMock, Mock

import ormsgpack
import pytest
from pipecat.frames.frames import TTSAudioRawFrame

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
    service._websocket = FakeWebsocket([ormsgpack.packb({"event": "audio", "audio": b"a" * size})])
    service._sample_rate = service._init_sample_rate
    service.get_active_audio_context_id = Mock(return_value="ctx")
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
    service._websocket = FakeWebsocket([ormsgpack.packb({"event": "audio", "audio": b""})])
    service.append_to_audio_context = AsyncMock()

    await service._receive_messages()

    service.append_to_audio_context.assert_not_awaited()
