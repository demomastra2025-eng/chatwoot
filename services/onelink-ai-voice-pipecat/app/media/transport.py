"""Pipecat WebSocket client transport for OneLink runtime streams."""

from __future__ import annotations

from pipecat.transports.websocket.client import (
    WebsocketClientParams,
    WebsocketClientTransport,
)

from app.api.models import RuntimeStream
from app.media.serializer import OneLinkMediaSerializer


def create_media_transport(runtime_stream: RuntimeStream) -> WebsocketClientTransport:
    """Build a transport pinned to the existing OneLink PCM framing contract."""
    additional_headers = None
    if runtime_stream.stream_token is not None:
        additional_headers = {
            "authorization": f"Bearer {runtime_stream.stream_token.get_secret_value()}"
        }
    return WebsocketClientTransport(
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
            serializer=OneLinkMediaSerializer(),
        ),
    )
