"""Clock-aligned dual-channel WAV writer for OneLink AI Voice calls."""

from __future__ import annotations

import asyncio
import hashlib
import math
import re
import tempfile
import time
import wave
from array import array
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import IO, Any

from pipecat.audio.resamplers.soxr_resampler import SOXRAudioResampler

_SAMPLE_RATE = 8_000
_CHANNELS = 2
_SAMPLE_WIDTH = 2
_INTERLEAVE_CHUNK_FRAMES = 4_096
_SAFE_PART = re.compile(r"[^a-zA-Z0-9_.-]+")


class DualChannelRecorder:
    """Own one WAV file: caller on left, Pipecat assistant on right."""

    def __init__(
        self,
        *,
        root: Path,
        account_id: str | int,
        call_ref: str,
        clock: Callable[[], float] = time.monotonic,
    ):
        account = _safe_part(account_id)
        call = _safe_part(call_ref)
        self.storage_key = f"voice-recordings/{account}/{call}/recording.wav"
        self.path = root / self.storage_key
        self._lock = asyncio.Lock()
        self._resamplers = {
            "inbound": SOXRAudioResampler(quality="HQ"),
            "outbound": SOXRAudioResampler(quality="HQ"),
        }
        self._tracks: dict[str, IO[bytes]] = {
            "inbound": tempfile.SpooledTemporaryFile(max_size=2 * 1024 * 1024, mode="w+b"),
            "outbound": tempfile.SpooledTemporaryFile(max_size=2 * 1024 * 1024, mode="w+b"),
        }
        self._track_frames = {"inbound": 0, "outbound": 0}
        self._closed_result: dict[str, Any] | None = None
        self._inbound_bytes = 0
        self._outbound_bytes = 0
        self._clock = clock
        self._started_monotonic = clock()
        self._started_at = datetime.now(UTC)

    async def write_inbound(self, audio: bytes, *, sample_rate: int) -> None:
        await self._write("inbound", audio, sample_rate=sample_rate)

    async def write_outbound(self, audio: bytes, *, sample_rate: int) -> None:
        await self._write("outbound", audio, sample_rate=sample_rate)

    async def _write(self, direction: str, audio: bytes, *, sample_rate: int) -> None:
        if not audio:
            return
        normalized = await self._resamplers[direction].resample(
            audio, sample_rate, _SAMPLE_RATE
        )
        normalized = normalized[: len(normalized) - (len(normalized) % _SAMPLE_WIDTH)]
        if not normalized:
            return

        async with self._lock:
            if self._closed_result is not None:
                return
            elapsed_frames = max(
                0,
                round((self._clock() - self._started_monotonic) * _SAMPLE_RATE),
            )
            start_frame = max(elapsed_frames, self._track_frames[direction])
            track = self._tracks[direction]
            track.seek(start_frame * _SAMPLE_WIDTH)
            track.write(normalized)
            frame_count = len(normalized) // _SAMPLE_WIDTH
            self._track_frames[direction] = start_frame + frame_count
            if direction == "inbound":
                self._inbound_bytes += len(normalized)
            else:
                self._outbound_bytes += len(normalized)

    async def close(self) -> dict[str, Any]:
        async with self._lock:
            if self._closed_result is not None:
                return dict(self._closed_result)

            max_frames = max(self._track_frames.values())
            try:
                self.path.parent.mkdir(parents=True, exist_ok=True)
                with wave.open(str(self.path), "wb") as writer:
                    writer.setnchannels(_CHANNELS)
                    writer.setsampwidth(_SAMPLE_WIDTH)
                    writer.setframerate(_SAMPLE_RATE)
                    self._write_interleaved(writer, max_frames)
                ended_at = datetime.now(UTC)
                size_bytes = self.path.stat().st_size
                digest = await asyncio.to_thread(_sha256_file, self.path)
                duration_ms = round(max_frames / _SAMPLE_RATE * 1_000)
                self._closed_result = {
                    "recording_ref": self.storage_key,
                    "storage_key": self.storage_key,
                    "sha256": digest,
                    "size_bytes": size_bytes,
                    "byte_size": size_bytes,
                    "content_type": "audio/wav",
                    "duration_ms": duration_ms,
                    "duration_sec": math.ceil(duration_ms / 1_000) if duration_ms else 0,
                    "wall_duration_ms": round(
                        (ended_at - self._started_at).total_seconds() * 1_000
                    ),
                    "sample_rate": _SAMPLE_RATE,
                    "channels": _CHANNELS,
                    "bits_per_sample": 16,
                    "recorded_by": "pipecat",
                    "writer": "onelink-ai-voice-pipecat",
                    "mode": "ai_voice",
                    "layout": "dual_channel",
                    "channel_layout": {"left": "caller", "right": "voice_agent"},
                    "inbound_bytes": self._inbound_bytes,
                    "outbound_bytes": self._outbound_bytes,
                    **_recording_health(self._inbound_bytes, self._outbound_bytes),
                }
            except Exception as error:
                try:
                    self.path.unlink(missing_ok=True)
                except OSError:
                    pass
                self._closed_result = {
                    "recording_status": "failed",
                    "degraded": True,
                    "reason": "recording_finalize_failed",
                    "duration_ms": 0,
                    "duration_sec": 0,
                    "recorded_by": "pipecat",
                    "writer": "onelink-ai-voice-pipecat",
                    "mode": "ai_voice",
                    "layout": "dual_channel",
                    "inbound_bytes": self._inbound_bytes,
                    "outbound_bytes": self._outbound_bytes,
                    "error_class": type(error).__name__,
                }
            finally:
                for track in self._tracks.values():
                    track.close()
            return dict(self._closed_result)

    def _write_interleaved(self, writer: wave.Wave_write, max_frames: int) -> None:
        inbound = self._tracks["inbound"]
        outbound = self._tracks["outbound"]
        inbound.seek(0)
        outbound.seek(0)
        remaining = max_frames
        while remaining > 0:
            frame_count = min(remaining, _INTERLEAVE_CHUNK_FRAMES)
            byte_count = frame_count * _SAMPLE_WIDTH
            left = _padded_samples(inbound.read(byte_count), frame_count)
            right = _padded_samples(outbound.read(byte_count), frame_count)
            stereo = array("h")
            for index in range(frame_count):
                stereo.extend((left[index], right[index]))
            writer.writeframesraw(stereo.tobytes())
            remaining -= frame_count


def _padded_samples(audio: bytes, frame_count: int) -> array:
    samples = array("h")
    samples.frombytes(audio[: len(audio) - (len(audio) % _SAMPLE_WIDTH)])
    if len(samples) < frame_count:
        samples.extend([0] * (frame_count - len(samples)))
    return samples


def _safe_part(value: object) -> str:
    return _SAFE_PART.sub("-", str(value)).strip("-") or "unknown"


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as recording:
        while chunk := recording.read(128 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _recording_health(inbound_bytes: int, outbound_bytes: int) -> dict[str, Any]:
    if inbound_bytes and outbound_bytes:
        return {"recording_status": "ready", "degraded": False}
    if inbound_bytes:
        missing = "outbound"
        reason = "voice_agent_audio_missing"
    elif outbound_bytes:
        missing = "inbound"
        reason = "caller_audio_missing"
    else:
        missing = "both"
        reason = "empty_recording"
    return {
        "recording_status": "degraded",
        "degraded": True,
        "missing_direction": missing,
        "reason": reason,
    }
