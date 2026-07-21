import wave
from array import array

import pytest

from app.recordings.writer import DualChannelRecorder


@pytest.mark.asyncio
async def test_recorder_writes_dual_channel_8khz_wav_and_integrity(tmp_path):
    recorder = DualChannelRecorder(
        root=tmp_path,
        account_id=7,
        call_ref="call/unsafe",
    )
    inbound = (1000).to_bytes(2, "little", signed=True) * 320
    outbound = (-1000).to_bytes(2, "little", signed=True) * 160

    await recorder.write_inbound(inbound, sample_rate=16_000)
    await recorder.write_outbound(outbound, sample_rate=8_000)
    result = await recorder.close()

    path = tmp_path / result["storage_key"]
    assert path.is_file()
    assert result["recorded_by"] == "pipecat"
    assert result["layout"] == "dual_channel"
    assert result["mode"] == "ai_voice"
    assert result["size_bytes"] == path.stat().st_size
    assert len(result["sha256"]) == 64
    assert result["duration_sec"] >= 1

    with wave.open(str(path), "rb") as recording:
        assert recording.getnchannels() == 2
        assert recording.getsampwidth() == 2
        assert recording.getframerate() == 8_000
        frames = recording.readframes(recording.getnframes())

    samples = memoryview(frames).cast("h")
    assert any(samples[index] != 0 for index in range(0, len(samples), 2))
    assert any(samples[index] != 0 for index in range(1, len(samples), 2))


@pytest.mark.asyncio
async def test_recorder_close_is_idempotent(tmp_path):
    recorder = DualChannelRecorder(root=tmp_path, account_id=7, call_ref="call-1")
    await recorder.write_inbound(bytes(640), sample_rate=16_000)

    first = await recorder.close()
    second = await recorder.close()

    assert second == first


@pytest.mark.asyncio
async def test_recorder_aligns_channels_on_one_session_clock(tmp_path):
    now = [0.0]
    recorder = DualChannelRecorder(
        root=tmp_path,
        account_id=42,
        call_ref="sipuni:clock-alignment",
        clock=lambda: now[0],
    )

    await recorder.write_inbound(array("h", [100] * 160).tobytes(), sample_rate=8_000)
    now[0] = 0.02
    await recorder.write_outbound(array("h", [200] * 160).tobytes(), sample_rate=8_000)
    result = await recorder.close()

    with wave.open(str(tmp_path / result["storage_key"]), "rb") as recording:
        assert recording.getnframes() == 320
        samples = array("h")
        samples.frombytes(recording.readframes(320))

    assert result["duration_ms"] == 40
    assert samples[0:4] == array("h", [100, 0, 100, 0])
    assert samples[320:324] == array("h", [0, 200, 0, 200])


@pytest.mark.asyncio
async def test_recorder_close_failure_is_degraded_and_idempotent(monkeypatch, tmp_path):
    recorder = DualChannelRecorder(root=tmp_path, account_id=7, call_ref="call-failure")
    await recorder.write_inbound(bytes(320), sample_rate=8_000)

    def fail_write(*_args):
        raise OSError("synthetic storage failure")

    monkeypatch.setattr(recorder, "_write_interleaved", fail_write)
    first = await recorder.close()
    second = await recorder.close()

    assert first == second
    assert first["recording_status"] == "failed"
    assert first["degraded"] is True
    assert first["reason"] == "recording_finalize_failed"
    assert first["duration_sec"] == 0
    assert first["error_class"] == "OSError"
    assert not recorder.path.exists()
