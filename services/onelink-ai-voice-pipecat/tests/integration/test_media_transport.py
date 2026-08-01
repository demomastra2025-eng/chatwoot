import asyncio
import base64
import json

import pytest
from pipecat.frames.frames import Frame, InputAudioRawFrame, OutputAudioRawFrame
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
