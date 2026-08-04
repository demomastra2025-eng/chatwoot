import base64
import json
from urllib.parse import parse_qs, urlencode

import pytest
from pipecat.services.elevenlabs.stt import CommitStrategy
from pipecat.transcriptions.language import Language
from websockets.protocol import State

from app.services.elevenlabs_realtime_stt import OneLinkElevenLabsRealtimeSTTService


class OpenWebSocket:
    state = State.OPEN

    def __init__(self):
        self.messages = []

    async def send(self, message):
        self.messages.append(json.loads(message))


def service() -> OneLinkElevenLabsRealtimeSTTService:
    instance = OneLinkElevenLabsRealtimeSTTService(
        api_key="test-key",
        sample_rate=16_000,
        commit_strategy=CommitStrategy.MANUAL,
        settings=OneLinkElevenLabsRealtimeSTTService.Settings(
            model="scribe_v2_realtime",
            language=Language.RU,
        ),
    )
    instance._sample_rate = 16_000
    instance._audio_format = "pcm_16000"
    return instance


def test_connection_query_repeats_secondary_language_hints():
    service = OneLinkElevenLabsRealtimeSTTService(
        api_key="test-key",
        sample_rate=16_000,
        secondary_languages=["kk", "en", "kk", "ru"],
        commit_strategy=CommitStrategy.MANUAL,
        settings=OneLinkElevenLabsRealtimeSTTService.Settings(
            model="scribe_v2_realtime",
            language=Language.RU,
        ),
    )
    service._audio_format = "pcm_16000"

    query = parse_qs(urlencode(service._connection_query_params()))

    assert query["language_code"] == ["ru"]
    assert query["secondary_languages"] == ["kk", "en"]
    assert query["audio_format"] == ["pcm_16000"]
    assert query["commit_strategy"] == ["manual"]


@pytest.mark.asyncio
async def test_provider_boundary_coalesces_five_20ms_frames_into_one_100ms_chunk():
    instance = service()
    websocket = OpenWebSocket()
    instance._websocket = websocket
    instance._connected_event.set()

    for _ in range(5):
        _ = [frame async for frame in instance.run_stt(bytes(640))]

    assert len(websocket.messages) == 1
    message = websocket.messages[0]
    assert message["commit"] is False
    assert message["sample_rate"] == 16_000
    assert len(base64.b64decode(message["audio_base_64"])) == 3_200


@pytest.mark.asyncio
async def test_partial_provider_tail_is_silence_padded_to_supported_chunk_size():
    instance = service()
    websocket = OpenWebSocket()
    instance._websocket = websocket
    instance._connected_event.set()
    instance._provider_audio_buffer.extend(b"voice" * 100)

    await instance._flush_provider_audio_buffer()

    assert instance._provider_audio_buffer == bytearray()
    assert len(websocket.messages) == 1
    audio = base64.b64decode(websocket.messages[0]["audio_base_64"])
    assert len(audio) == 3_200
    assert audio.startswith(b"voice" * 100)
    assert audio.endswith(bytes(2_700))
