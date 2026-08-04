import asyncio
import base64
import json

import pytest
from pipecat.frames.frames import (
    Frame,
    InputAudioRawFrame,
    InterruptionFrame,
    OutputAudioRawFrame,
    TTSAudioRawFrame,
)
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineParams, PipelineWorker
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor
from pipecat.workers.runner import WorkerRunner
from websockets.asyncio.server import serve

from app.api.models import RuntimeStream
from app.media.transport import create_media_transport


class FixedAudioReply(FrameProcessor):
    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        await super().process_frame(frame, direction)
        if isinstance(frame, InputAudioRawFrame):
            await self.push_frame(
                OutputAudioRawFrame(audio=bytes(320), sample_rate=8_000, num_channels=1),
                direction,
            )
            return
        await self.push_frame(frame, direction)


class InterruptThenReply(FrameProcessor):
    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        await super().process_frame(frame, direction)
        if isinstance(frame, InputAudioRawFrame):
            await self.push_frame(InterruptionFrame(), direction)
            await self.push_frame(
                OutputAudioRawFrame(audio=bytes(320), sample_rate=8_000, num_channels=1),
                direction,
            )
            return
        await self.push_frame(frame, direction)


class BufferedAudioThenInterrupt(FrameProcessor):
    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        await super().process_frame(frame, direction)
        if isinstance(frame, InputAudioRawFrame):
            for _ in range(20):
                await self.push_frame(
                    TTSAudioRawFrame(audio=bytes(320), sample_rate=8_000, num_channels=1),
                    direction,
                )
            await asyncio.sleep(0.04)
            await self.push_frame(InterruptionFrame(), direction)
            return
        await self.push_frame(frame, direction)


def test_media_transport_configures_bounded_word_tail():
    stream = RuntimeStream(
        runtime_session_id="fake-runtime-session",
        stream_url="ws://media.internal/runtime-stream",
        stream_token="fake-token",
        codec="pcm_s16le",
        input_sample_rate=16_000,
        output_sample_rate=8_000,
    )

    graceful = create_media_transport(
        stream,
        finish_current_word_on_interrupt=True,
        interrupt_word_boundary_grace_ms=120,
    )
    immediate = create_media_transport(
        stream,
        finish_current_word_on_interrupt=False,
        interrupt_word_boundary_grace_ms=120,
    )

    assert graceful.output()._interrupt_tail_seconds == 0.12
    assert immediate.output()._interrupt_tail_seconds == 0.0


@pytest.mark.asyncio
async def test_word_tail_drains_only_bounded_audio_before_clear(fixture_json):
    audio_in = fixture_json("runtime_audio_in.json")

    async def audio_frames_before_clear(grace_ms: int) -> int:
        received: asyncio.Future[int] = asyncio.get_running_loop().create_future()

        async def media_server(websocket):
            await websocket.send(json.dumps(audio_in))
            audio_frames = 0
            while True:
                payload = json.loads(await websocket.recv())
                if payload["type"] == "CLEAR_AUDIO":
                    received.set_result(audio_frames)
                    break
                audio_frames += 1
            await websocket.close()

        async with serve(media_server, "127.0.0.1", 0) as server:
            port = server.sockets[0].getsockname()[1]
            stream = RuntimeStream(
                runtime_session_id=f"word-tail-{grace_ms}",
                stream_url=f"ws://127.0.0.1:{port}/runtime-stream",
                stream_token="fake-token",
                codec="pcm_s16le",
                input_sample_rate=16_000,
                output_sample_rate=8_000,
            )
            transport = create_media_transport(
                stream,
                finish_current_word_on_interrupt=grace_ms > 0,
                interrupt_word_boundary_grace_ms=grace_ms,
            )
            pipeline = Pipeline(
                [transport.input(), BufferedAudioThenInterrupt(), transport.output()]
            )
            worker = PipelineWorker(
                pipeline,
                params=PipelineParams(
                    audio_in_sample_rate=16_000,
                    audio_out_sample_rate=8_000,
                ),
            )

            @transport.event_handler("on_disconnected")
            async def on_disconnected(_transport, _websocket):
                await worker.cancel()

            runner = WorkerRunner(handle_sigint=False, check_dangling_tasks=False)
            await runner.add_workers(worker)
            run_task = asyncio.create_task(runner.run())
            count = await asyncio.wait_for(received, timeout=5)
            await asyncio.wait_for(run_task, timeout=5)
            return count

    immediate_count = await audio_frames_before_clear(0)
    graceful_count = await audio_frames_before_clear(120)

    assert graceful_count >= immediate_count + 4
    assert graceful_count <= immediate_count + 7


@pytest.mark.asyncio
async def test_pipecat_transport_round_trips_existing_media_protocol(fixture_json):
    received: asyncio.Future[dict] = asyncio.get_running_loop().create_future()
    authorization: asyncio.Future[str | None] = asyncio.get_running_loop().create_future()
    connections = 0
    audio_in = fixture_json("runtime_audio_in.json")

    async def media_server(websocket):
        nonlocal connections
        connections += 1
        if not authorization.done():
            authorization.set_result(websocket.request.headers.get("authorization"))
        await websocket.send(json.dumps(audio_in))
        payload = json.loads(await websocket.recv())
        if not received.done():
            received.set_result(payload)
        await websocket.close()

    async with serve(media_server, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        stream = RuntimeStream(
            runtime_session_id="fake-runtime-session",
            stream_url=f"ws://127.0.0.1:{port}/runtime-stream",
            stream_token="fake-token",
            codec="pcm_s16le",
            input_sample_rate=16_000,
            output_sample_rate=8_000,
        )
        transport = create_media_transport(stream)
        pipeline = Pipeline([transport.input(), FixedAudioReply(), transport.output()])
        worker = PipelineWorker(
            pipeline,
            params=PipelineParams(audio_in_sample_rate=16_000, audio_out_sample_rate=8_000),
        )

        @transport.event_handler("on_disconnected")
        async def on_disconnected(_transport, _websocket):
            await worker.cancel()

        runner = WorkerRunner(handle_sigint=False, check_dangling_tasks=False)
        await runner.add_workers(worker)
        run_task = asyncio.create_task(runner.run())
        payload = await asyncio.wait_for(received, timeout=5)
        auth_header = await asyncio.wait_for(authorization, timeout=5)
        await asyncio.wait_for(run_task, timeout=5)

    assert payload == {
        "type": "AUDIO_OUT",
        "data": base64.b64encode(bytes(320)).decode("ascii"),
        "mime_type": "audio/pcm;rate=8000",
    }
    assert auth_header == "Bearer fake-token"
    assert connections == 1


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("clear_audio_on_interrupt", "expected_types"),
    [(True, ["CLEAR_AUDIO", "AUDIO_OUT"]), (False, ["AUDIO_OUT"])],
)
async def test_pipecat_transport_honors_clear_audio_on_interrupt(
    fixture_json, clear_audio_on_interrupt, expected_types
):
    received: asyncio.Future[list[dict]] = asyncio.get_running_loop().create_future()
    audio_in = fixture_json("runtime_audio_in.json")

    async def media_server(websocket):
        await websocket.send(json.dumps(audio_in))
        payloads = [json.loads(await websocket.recv()) for _ in expected_types]
        if not received.done():
            received.set_result(payloads)
        await websocket.close()

    async with serve(media_server, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        stream = RuntimeStream(
            runtime_session_id="fake-runtime-session",
            stream_url=f"ws://127.0.0.1:{port}/runtime-stream",
            stream_token="fake-token",
            codec="pcm_s16le",
            input_sample_rate=16_000,
            output_sample_rate=8_000,
        )
        transport = create_media_transport(
            stream, clear_audio_on_interrupt=clear_audio_on_interrupt
        )
        pipeline = Pipeline([transport.input(), InterruptThenReply(), transport.output()])
        worker = PipelineWorker(
            pipeline,
            params=PipelineParams(audio_in_sample_rate=16_000, audio_out_sample_rate=8_000),
        )

        @transport.event_handler("on_disconnected")
        async def on_disconnected(_transport, _websocket):
            await worker.cancel()

        runner = WorkerRunner(handle_sigint=False, check_dangling_tasks=False)
        await runner.add_workers(worker)
        run_task = asyncio.create_task(runner.run())
        payloads = await asyncio.wait_for(received, timeout=5)
        await asyncio.wait_for(run_task, timeout=5)

    assert [payload["type"] for payload in payloads] == expected_types
