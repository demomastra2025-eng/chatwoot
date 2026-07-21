import asyncio

import pytest

from app.sessions.manager import ReservationKind, SessionManager


@pytest.mark.asyncio
async def test_reserve_is_atomic_and_idempotent_for_identical_payload():
    manager = SessionManager(max_concurrent_sessions=2)
    payload = {"call_ref": "call-1", "runtime_stream": {"stream_url": "ws://one"}}

    first = await manager.reserve("call-1", payload)
    duplicate = await manager.reserve("call-1", payload.copy())

    assert first.kind is ReservationKind.CREATED
    assert duplicate.kind is ReservationKind.DUPLICATE
    assert duplicate.record is first.record
    assert manager.active_count == 1


@pytest.mark.asyncio
async def test_conflicting_duplicate_is_rejected():
    manager = SessionManager(max_concurrent_sessions=2)
    await manager.reserve("call-1", {"call_ref": "call-1", "account_id": "1"})

    conflict = await manager.reserve("call-1", {"call_ref": "call-1", "account_id": "2"})

    assert conflict.kind is ReservationKind.CONFLICT
    assert manager.active_count == 1


@pytest.mark.asyncio
async def test_capacity_is_enforced_before_second_session():
    manager = SessionManager(max_concurrent_sessions=1)
    await manager.reserve("call-1", {"call_ref": "call-1"})

    capacity = await manager.reserve("call-2", {"call_ref": "call-2"})

    assert capacity.kind is ReservationKind.CAPACITY_EXHAUSTED
    assert manager.active_count == 1


@pytest.mark.asyncio
async def test_release_only_removes_matching_record():
    manager = SessionManager(max_concurrent_sessions=1)
    reservation = await manager.reserve("call-1", {"call_ref": "call-1"})

    assert await manager.release("call-1", object()) is False
    assert await manager.release("call-1", reservation.record) is True
    assert manager.active_count == 0


@pytest.mark.asyncio
async def test_shutdown_cancels_bound_tasks():
    manager = SessionManager(max_concurrent_sessions=1)
    reservation = await manager.reserve("call-1", {"call_ref": "call-1"})
    task = asyncio.create_task(asyncio.sleep(60))
    await manager.bind_task(reservation.record, task)

    await manager.shutdown()

    assert task.cancelled()
    assert manager.active_count == 0
