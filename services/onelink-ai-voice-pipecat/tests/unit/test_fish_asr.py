import io
import wave

import httpx
import ormsgpack
import pytest
from pipecat.frames.frames import ErrorFrame, TranscriptionFrame
from pipecat.transcriptions.language import Language

from app.services.fish_asr import FishAudioASRService


def wav_bytes(duration_seconds: float, sample_rate: int = 16_000) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(b"\x00\x00" * int(duration_seconds * sample_rate))
    return buffer.getvalue()


async def collect(service: FishAudioASRService, audio: bytes):
    return [frame async for frame in service.run_stt(audio)]


@pytest.mark.asyncio
async def test_fish_asr_posts_msgpack_wav_and_returns_final_transcript():
    captured = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["headers"] = request.headers
        captured["payload"] = ormsgpack.unpackb(request.content)
        return httpx.Response(
            200,
            headers={"content-type": "application/msgpack"},
            content=ormsgpack.packb({"text": " Привет ", "language": "ru"}),
        )

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    service = FishAudioASRService(
        api_key="fish-secret",
        http_client=client,
        settings=FishAudioASRService.Settings(
            language=Language.RU,
            ignore_timestamps=True,
        ),
    )

    frames = await collect(service, wav_bytes(1.25))

    assert len(frames) == 1
    assert isinstance(frames[0], TranscriptionFrame)
    assert frames[0].text == "Привет"
    assert frames[0].language == Language.RU
    assert captured["headers"]["authorization"] == "Bearer fish-secret"
    assert captured["headers"]["content-type"] == "application/msgpack"
    assert captured["payload"]["audio"].startswith(b"RIFF")
    assert captured["payload"]["language"] == "ru"
    assert captured["payload"]["ignore_timestamps"] is True
    await client.aclose()


@pytest.mark.asyncio
async def test_fish_asr_skips_segments_below_provider_minimum():
    calls = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(500)

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    service = FishAudioASRService(api_key="fish-secret", http_client=client)

    assert await collect(service, wav_bytes(0.9)) == []
    assert calls == 0
    await client.aclose()


@pytest.mark.asyncio
async def test_fish_asr_returns_safe_error_without_provider_body():
    calls = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(401, text="sensitive provider response")

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    service = FishAudioASRService(api_key="fish-secret", http_client=client)

    frames = await collect(service, wav_bytes(1.1))

    assert len(frames) == 1
    assert isinstance(frames[0], ErrorFrame)
    assert frames[0].error == "Fish ASR API error (401)"
    assert "sensitive" not in frames[0].error
    assert calls == 1
    await client.aclose()


@pytest.mark.asyncio
async def test_fish_asr_accepts_documented_json_response_shape():
    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"text": "Hello", "language": "en"})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    service = FishAudioASRService(api_key="fish-secret", http_client=client)

    frames = await collect(service, wav_bytes(1.1))

    assert frames[0].text == "Hello"
    assert frames[0].language == Language.EN
    await client.aclose()


@pytest.mark.asyncio
async def test_fish_asr_retries_transient_provider_status_with_same_segment():
    calls = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls == 1:
            return httpx.Response(503)
        return httpx.Response(200, json={"text": "Повтор принят", "language": "ru"})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    service = FishAudioASRService(
        api_key="fish-secret",
        http_client=client,
        max_retries=1,
        retry_backoff_seconds=0,
    )

    frames = await collect(service, wav_bytes(1.1))

    assert calls == 2
    assert frames[0].text == "Повтор принят"
    await client.aclose()


@pytest.mark.asyncio
async def test_fish_asr_retries_timeout_with_same_segment():
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise httpx.ReadTimeout("temporary timeout", request=request)
        return httpx.Response(200, json={"text": "Слышно", "language": "ru"})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    service = FishAudioASRService(
        api_key="fish-secret",
        http_client=client,
        max_retries=1,
        retry_backoff_seconds=0,
    )

    frames = await collect(service, wav_bytes(1.1))

    assert calls == 2
    assert frames[0].text == "Слышно"
    await client.aclose()


@pytest.mark.asyncio
async def test_fish_asr_retries_invalid_success_payload_with_same_segment():
    calls = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls == 1:
            return httpx.Response(200, content=b"not-msgpack")
        return httpx.Response(200, json={"text": "Готово", "language": "ru"})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    service = FishAudioASRService(
        api_key="fish-secret",
        http_client=client,
        max_retries=1,
        retry_backoff_seconds=0,
    )

    frames = await collect(service, wav_bytes(1.1))

    assert calls == 2
    assert frames[0].text == "Готово"
    await client.aclose()
