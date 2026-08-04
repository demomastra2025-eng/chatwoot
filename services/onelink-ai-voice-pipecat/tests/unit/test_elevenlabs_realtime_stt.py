from urllib.parse import parse_qs, urlencode

from pipecat.services.elevenlabs.stt import CommitStrategy
from pipecat.transcriptions.language import Language

from app.services.elevenlabs_realtime_stt import OneLinkElevenLabsRealtimeSTTService


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
