"""OneLink hardening for the Pipecat Fish Audio TTS adapter."""

from __future__ import annotations

import asyncio
from collections import deque
from collections.abc import AsyncGenerator
from dataclasses import dataclass, field

import ormsgpack
from loguru import logger
from pipecat.frames.frames import (
    ErrorFrame,
    Frame,
    InterruptionFrame,
    TTSAudioRawFrame,
)
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.fish.tts import FishAudioTTSService


@dataclass(slots=True)
class _SynthesisTransaction:
    context_id: str
    interruption_epoch: int
    text_message: bytes
    flush_message: bytes
    first_audio_event: asyncio.Event = field(default_factory=asyncio.Event)
    ready_event: asyncio.Event = field(default_factory=asyncio.Event)


class OneLinkFishAudioTTSService(FishAudioTTSService):
    """Preserve chunks and replay one lost websocket synthesis transaction."""

    FIRST_AUDIO_TIMEOUT_SECONDS = 1.5
    SYNTHESIS_ATTEMPTS = 2

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._synthesis_lock = asyncio.Lock()
        self._interruption_epoch = 0
        self._transactions: deque[_SynthesisTransaction] = deque()

    async def run_tts(self, text: str, context_id: str) -> AsyncGenerator[Frame | None, None]:
        logger.trace(f"{self}: Generating TTS [{text}]")
        async with self._synthesis_lock:
            interruption_epoch = self._interruption_epoch
            transaction = self._build_transaction(text, context_id, interruption_epoch)
            try:
                sent = await self._send_synthesis_transaction(transaction)
                if not sent:
                    return
                await self.start_tts_usage_metrics(text)

                received = await self._wait_for_first_audio(transaction)
                if not received:
                    return
                yield None
            except Exception as error:
                logger.exception(f"{self} TTS synthesis failed after replay: {error}")
                yield ErrorFrame(
                    error=f"Fish Audio TTS failed after replay: {type(error).__name__}",
                    fatal=False,
                    exception=error,
                )

    def _build_transaction(
        self,
        text: str,
        context_id: str,
        interruption_epoch: int,
    ) -> _SynthesisTransaction:
        return _SynthesisTransaction(
            context_id=context_id,
            interruption_epoch=interruption_epoch,
            text_message=ormsgpack.packb(
                {
                    "event": "text",
                    "text": text,
                    "normalize": self._settings.normalize,
                }
            ),
            flush_message=ormsgpack.packb({"event": "flush"}),
        )

    async def _wait_for_first_audio(self, transaction: _SynthesisTransaction) -> bool:
        await transaction.ready_event.wait()
        for attempt in range(1, self.SYNTHESIS_ATTEMPTS + 1):
            try:
                await asyncio.wait_for(
                    transaction.first_audio_event.wait(),
                    timeout=self.FIRST_AUDIO_TIMEOUT_SECONDS,
                )
            except TimeoutError:
                if self._transaction_cancelled(transaction):
                    return False
                if attempt >= self.SYNTHESIS_ATTEMPTS:
                    raise TimeoutError("Fish Audio returned no audio after replay") from None
                logger.warning(
                    f"{self} returned no audio in {self.FIRST_AUDIO_TIMEOUT_SECONDS:.1f}s; "
                    "reconnecting and replaying the synthesis request once"
                )
                if not await self._restart_connection():
                    raise ConnectionError("Fish Audio reconnect failed") from None
                self._reset_transactions_for_replay(transaction)
                await self._send_transaction_messages(transaction)
                continue

            if self._transaction_cancelled(transaction):
                return False
            return True
        return False

    async def _send_synthesis_transaction(self, transaction: _SynthesisTransaction) -> bool:
        self._enqueue_transaction(transaction)
        for attempt in range(1, self.SYNTHESIS_ATTEMPTS + 1):
            if self._transaction_cancelled(transaction):
                return False
            try:
                await self._send_transaction_messages(transaction)
                return True
            except Exception:
                if attempt >= self.SYNTHESIS_ATTEMPTS:
                    raise
                logger.warning(f"{self} send failed; reconnecting and replaying request")
                if not await self._restart_connection():
                    raise ConnectionError("Fish Audio reconnect failed") from None
                self._reset_transactions_for_replay(transaction)
        return False

    async def _send_transaction_messages(self, transaction: _SynthesisTransaction) -> None:
        if self._websocket is None:
            raise ConnectionError("Fish Audio websocket is not connected")
        transaction.first_audio_event.clear()
        await self._websocket.send(transaction.text_message)
        await self._websocket.send(transaction.flush_message)

    def _enqueue_transaction(self, transaction: _SynthesisTransaction) -> None:
        if transaction in self._transactions:
            return
        self._transactions.append(transaction)
        if len(self._transactions) == 1:
            transaction.ready_event.set()

    def _reset_transactions_for_replay(self, transaction: _SynthesisTransaction) -> None:
        for pending in self._transactions:
            if pending is not transaction:
                pending.first_audio_event.set()
                pending.ready_event.set()
        self._transactions.clear()
        transaction.ready_event.set()
        self._transactions.append(transaction)

    def _transaction_cancelled(self, transaction: _SynthesisTransaction) -> bool:
        return (
            self._interruption_epoch != transaction.interruption_epoch
            or transaction not in self._transactions
        )

    def _finish_active_transaction(self) -> _SynthesisTransaction | None:
        if not self._transactions:
            return None
        transaction = self._transactions.popleft()
        if self._transactions:
            self._transactions[0].ready_event.set()
        return transaction

    async def _handle_interruption(
        self,
        frame: InterruptionFrame,
        direction: FrameDirection,
    ) -> None:
        self._interruption_epoch += 1
        had_transactions = bool(self._transactions)
        bot_was_speaking = self._bot_speaking
        for transaction in self._transactions:
            transaction.first_audio_event.set()
            transaction.ready_event.set()
        self._transactions.clear()
        await super()._handle_interruption(frame, direction)
        if had_transactions and not bot_was_speaking:
            await self._restart_connection()

    async def _restart_connection(self) -> bool:
        last_error: Exception | None = None
        for attempt in range(1, 3):
            try:
                # The low-level websocket reconnect helper leaves the existing
                # receiver racing the socket swap. A full service restart cancels
                # it and lets Fish _connect() create a receiver for the new socket.
                await self._disconnect()
                await self._connect()
                return True
            except Exception as exc:
                last_error = exc
                logger.warning("Fish Audio websocket restart attempt %s failed: %s", attempt, exc)
                await asyncio.sleep(0.25 * attempt)

        await self.push_error(
            ErrorFrame(
                f"Fish Audio websocket restart failed: {last_error}",
                fatal=False,
            )
        )
        return False

    async def _receive_messages(self):
        async for message in self._get_websocket():
            try:
                if not isinstance(message, bytes):
                    continue

                payload = ormsgpack.unpackb(message)
                if not isinstance(payload, dict):
                    continue

                event = payload.get("event")
                if event == "audio":
                    audio_data = payload.get("audio")
                    transaction = self._transactions[0] if self._transactions else None
                    if transaction is not None and isinstance(audio_data, bytes) and audio_data:
                        frame = TTSAudioRawFrame(
                            audio_data,
                            self.sample_rate,
                            1,
                            context_id=transaction.context_id,
                        )
                        transaction.first_audio_event.set()
                        await self.append_to_audio_context(transaction.context_id, frame)
                        await self.stop_ttfb_metrics()
                elif event == "finish":
                    self._finish_active_transaction()
                    reason = payload.get("reason", "unknown")
                    if reason == "error":
                        await self.push_error(error_msg="Fish Audio server error during synthesis")
                    else:
                        logger.debug("Fish Audio session finished: {}", reason)
            except Exception as exc:
                await self.push_error(
                    error_msg=f"Fish Audio message handling failed: {type(exc).__name__}",
                    exception=exc,
                )
