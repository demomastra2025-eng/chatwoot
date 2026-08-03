"""Pipecat WebSocket client transport for OneLink runtime streams."""

from __future__ import annotations

import asyncio

from pipecat.frames.frames import Frame, InterruptionFrame
from pipecat.processors.frame_processor import FrameDirection
from pipecat.transports.websocket.client import (
    WebsocketClientCallbacks,
    WebsocketClientOutputTransport,
    WebsocketClientParams,
    WebsocketClientSession,
    WebsocketClientTransport,
)

from app.api.models import RuntimeStream
from app.media.serializer import OneLinkMediaSerializer


class _SingleConnectionWebsocketClientSession(WebsocketClientSession):
    """Prevent Pipecat input/output startup from consuming two stream grants."""

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._connect_lock = asyncio.Lock()

    async def connect(self) -> None:
        async with self._connect_lock:
            await super().connect()


class _OneLinkWebsocketClientOutputTransport(WebsocketClientOutputTransport):
    """Send OneLink's interruption control frame after clearing local output buffers."""

    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        await super().process_frame(frame, direction)

        if isinstance(frame, InterruptionFrame):
            await self._write_frame(frame)
            self._next_send_time = 0


class OneLinkMediaTransport(WebsocketClientTransport):
    """Use one duplex WebSocket for the runtime stream's one-time grant."""

    def __init__(self, uri: str, params: WebsocketClientParams) -> None:
        super().__init__(uri=uri, params=params)
        callbacks = WebsocketClientCallbacks(
            on_connected=self._on_connected,
            on_disconnected=self._on_disconnected,
            on_message=self._on_message,
        )
        self._session = _SingleConnectionWebsocketClientSession(
            uri,
            self._params,
            callbacks,
            self.name,
        )

    def output(self) -> WebsocketClientOutputTransport:
        if not self._output:
            self._output = _OneLinkWebsocketClientOutputTransport(
                self, self._session, self._params
            )
        return self._output


def create_media_transport(
    runtime_stream: RuntimeStream, *, clear_audio_on_interrupt: bool = True
) -> WebsocketClientTransport:
    """Build a transport pinned to the existing OneLink PCM framing contract."""
    additional_headers = None
    if runtime_stream.stream_token is not None:
        additional_headers = {
            "authorization": f"Bearer {runtime_stream.stream_token.get_secret_value()}"
        }
    return OneLinkMediaTransport(
        uri=str(runtime_stream.stream_url),
        params=WebsocketClientParams(
            audio_in_enabled=True,
            audio_in_sample_rate=runtime_stream.input_sample_rate,
            audio_in_channels=1,
            audio_out_enabled=True,
            audio_out_sample_rate=runtime_stream.output_sample_rate,
            audio_out_channels=1,
            audio_out_10ms_chunks=2,
            audio_out_end_silence_secs=0,
            audio_out_auto_silence=False,
            add_wav_header=False,
            additional_headers=additional_headers,
            serializer=OneLinkMediaSerializer(
                clear_audio_on_interrupt=clear_audio_on_interrupt
            ),
        ),
    )
