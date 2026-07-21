from unittest.mock import AsyncMock

import pytest
from pipecat.frames.frames import InputAudioRawFrame, TextFrame, TTSAudioRawFrame
from pipecat.processors.frame_processor import FrameDirection

from app.pipeline.processors import AudioResampleProcessor


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("frame", "target_rate"),
    [
        (
            InputAudioRawFrame(
                audio=(1000).to_bytes(2, "little", signed=True) * 3_200,
                sample_rate=16_000,
                num_channels=1,
            ),
            24_000,
        ),
        (
            TTSAudioRawFrame(
                audio=(-1000).to_bytes(2, "little", signed=True) * 4_800,
                sample_rate=24_000,
                num_channels=1,
                context_id="openai-turn",
            ),
            8_000,
        ),
    ],
)
async def test_audio_resample_processor_converts_pcm_and_preserves_frame_type(frame, target_rate):
    processor = AudioResampleProcessor(type(frame), target_rate)
    processor.push_frame = AsyncMock()
    source_duration = frame.num_frames / frame.sample_rate

    await processor.process_frame(frame, FrameDirection.DOWNSTREAM)

    output = processor.push_frame.await_args.args[0]
    assert type(output) is type(frame)
    assert output.sample_rate == target_rate
    assert output.num_channels == frame.num_channels
    assert abs((output.num_frames / target_rate) - source_duration) < 0.02
    if isinstance(frame, TTSAudioRawFrame):
        assert output.context_id == "openai-turn"


@pytest.mark.asyncio
async def test_audio_resample_processor_passes_unrelated_frames_unchanged():
    processor = AudioResampleProcessor(InputAudioRawFrame, 24_000)
    processor.push_frame = AsyncMock()
    frame = TextFrame("unchanged")

    await processor.process_frame(frame, FrameDirection.DOWNSTREAM)

    assert processor.push_frame.await_args.args[0] is frame
