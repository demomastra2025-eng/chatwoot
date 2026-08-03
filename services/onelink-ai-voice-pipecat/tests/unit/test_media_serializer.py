import base64
import json

import pytest
from pipecat.frames.frames import (
    Frame,
    InputAudioRawFrame,
    InterruptionFrame,
    OutputAudioRawFrame,
    TextFrame,
)

from app.media.serializer import OneLinkMediaSerializer


def test_serializer_initializes_pipecat_base_contract():
    serializer = OneLinkMediaSerializer(name="OneLinkTestSerializer")

    assert serializer.name == "OneLinkTestSerializer"
    assert serializer.should_ignore_frame(Frame()) is False


@pytest.mark.asyncio
async def test_deserialize_audio_in_fixture(fixture_json):
    serializer = OneLinkMediaSerializer()

    frame = await serializer.deserialize(json.dumps(fixture_json("runtime_audio_in.json")))

    assert isinstance(frame, InputAudioRawFrame)
    assert frame.audio == bytes(640)
    assert frame.sample_rate == 16_000
    assert frame.num_channels == 1


@pytest.mark.asyncio
async def test_serialize_audio_out_contract():
    serializer = OneLinkMediaSerializer()
    frame = OutputAudioRawFrame(
        audio=bytes(range(256)) + bytes(64),
        sample_rate=8_000,
        num_channels=1,
    )

    serialized = await serializer.serialize(frame)
    payload = json.loads(serialized)

    assert payload == {
        "type": "AUDIO_OUT",
        "data": base64.b64encode(frame.audio).decode("ascii"),
        "mime_type": "audio/pcm;rate=8000",
    }


@pytest.mark.asyncio
async def test_serialize_interruption_clears_browser_audio():
    serializer = OneLinkMediaSerializer()

    assert json.loads(await serializer.serialize(InterruptionFrame())) == {
        "type": "CLEAR_AUDIO"
    }


@pytest.mark.asyncio
async def test_serialize_interruption_preserves_browser_audio_when_clear_is_disabled():
    serializer = OneLinkMediaSerializer(clear_audio_on_interrupt=False)

    assert await serializer.serialize(InterruptionFrame()) is None


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "payload",
    [
        {"type": "UNKNOWN", "data": "AA==", "mime_type": "audio/pcm;rate=16000"},
        {"type": "AUDIO_IN", "data": "not-base64", "mime_type": "audio/pcm;rate=16000"},
        {"type": "AUDIO_IN", "data": "", "mime_type": "audio/pcm;rate=16000"},
        {
            "type": "AUDIO_IN",
            "data": base64.b64encode(bytes(640)).decode(),
            "mime_type": "audio/pcm;rate=8000",
        },
        {
            "type": "AUDIO_IN",
            "data": base64.b64encode(bytes(638)).decode(),
            "mime_type": "audio/pcm;rate=16000",
        },
    ],
)
async def test_invalid_input_frames_are_ignored(payload):
    serializer = OneLinkMediaSerializer()

    assert await serializer.deserialize(json.dumps(payload)) is None


@pytest.mark.asyncio
async def test_oversized_input_message_is_ignored():
    serializer = OneLinkMediaSerializer()

    assert await serializer.deserialize("x" * (64 * 1024 + 1)) is None


@pytest.mark.asyncio
async def test_non_audio_output_frame_is_ignored():
    serializer = OneLinkMediaSerializer()

    assert await serializer.serialize(TextFrame("not audio")) is None


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "frame",
    [
        OutputAudioRawFrame(audio=bytes(320), sample_rate=16_000, num_channels=1),
        OutputAudioRawFrame(audio=bytes(320), sample_rate=8_000, num_channels=2),
        OutputAudioRawFrame(audio=bytes(318), sample_rate=8_000, num_channels=1),
    ],
)
async def test_invalid_output_audio_is_ignored(frame):
    serializer = OneLinkMediaSerializer()

    assert await serializer.serialize(frame) is None
