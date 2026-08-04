import asyncio

import pytest

from app.callbacks.outbox import CallbackOutbox
from app.clients.onelink import Correlation, OnelinkApiError


class FlakyClient:
    def __init__(self, *, fail: bool):
        self.fail = fail
        self.finalizations = []
        self.recordings = []

    async def finalize_call(self, correlation, **kwargs):
        self.finalizations.append((correlation, kwargs))
        if self.fail:
            raise OnelinkApiError("unavailable", code="transport_error")
        return {"status": "ok"}

    async def recording_stored(self, correlation, **kwargs):
        self.recordings.append((correlation, kwargs))
        if self.fail:
            raise OnelinkApiError("unavailable", code="transport_error")
        return {"status": "ok"}


class SlowClient(FlakyClient):
    async def finalize_call(self, correlation, **kwargs):
        self.finalizations.append((correlation, kwargs))
        await asyncio.Event().wait()


class SlowRecordingClient(FlakyClient):
    async def recording_stored(self, correlation, **kwargs):
        self.recordings.append((correlation, kwargs))
        await asyncio.Event().wait()


@pytest.fixture
def correlation():
    return Correlation(
        call_ref="call-1",
        runtime_session_id="runtime-1",
        account_id=7,
    )


@pytest.mark.asyncio
async def test_failed_finalize_survives_restart_and_replays(tmp_path, correlation):
    root = tmp_path / "outbox"
    outbox = CallbackOutbox(root)
    failing = FlakyClient(fail=True)

    with pytest.raises(OnelinkApiError):
        await outbox.deliver_finalize(
            failing,
            correlation,
            payload={"status": "failed", "reason": "provider_error"},
            event_id="finalize:runtime-1:call-1",
        )

    assert len(list(root.glob("*.json"))) == 1

    restarted_outbox = CallbackOutbox(root)
    recovered = FlakyClient(fail=False)
    assert await restarted_outbox.replay(recovered) == 1
    assert len(recovered.finalizations) == 1
    assert list(root.glob("*.json")) == []


@pytest.mark.asyncio
async def test_successful_recording_delivery_acks_entry(tmp_path, correlation):
    root = tmp_path / "outbox"
    outbox = CallbackOutbox(root)
    client = FlakyClient(fail=False)

    await outbox.deliver_recording(
        client,
        correlation,
        payload={"storage_key": "voice-recordings/7/call-1/recording.wav"},
        event_id="recording_stored:7:call-1:digest",
    )

    assert len(client.recordings) == 1
    assert list(root.glob("*.json")) == []


@pytest.mark.asyncio
async def test_finalize_timeout_keeps_durable_entry_for_replay(tmp_path, correlation):
    root = tmp_path / "outbox"
    outbox = CallbackOutbox(root)

    with pytest.raises(TimeoutError):
        await outbox.deliver_finalize(
            SlowClient(fail=False),
            correlation,
            payload={"status": "completed", "reason": "caller_hangup"},
            event_id="finalize:runtime-1:call-timeout",
            foreground_timeout_seconds=0.01,
        )

    assert len(list(root.glob("*.json"))) == 1


@pytest.mark.asyncio
async def test_replay_prioritizes_finalize_and_bounds_a_slow_recording(tmp_path, correlation):
    root = tmp_path / "outbox"
    outbox = CallbackOutbox(root)
    failing = FlakyClient(fail=True)

    with pytest.raises(OnelinkApiError):
        await outbox.deliver_recording(
            failing,
            correlation,
            payload={"storage_key": "voice-recordings/7/call-1/recording.wav"},
            event_id="recording_stored:7:call-1:digest",
        )
    with pytest.raises(OnelinkApiError):
        await outbox.deliver_finalize(
            failing,
            correlation,
            payload={"status": "completed", "reason": "caller_hangup"},
            event_id="finalize:runtime-1:call-1",
        )

    replay = SlowRecordingClient(fail=False)
    delivered = await outbox.replay(
        replay,
        delivery_timeout_seconds=0.01,
        concurrency=1,
    )

    assert delivered == 1
    assert len(replay.finalizations) == 1
    assert len(replay.recordings) == 1
    remaining = [outbox._read_entry(path)["kind"] for path in root.glob("*.json")]
    assert remaining == ["recording_stored"]
