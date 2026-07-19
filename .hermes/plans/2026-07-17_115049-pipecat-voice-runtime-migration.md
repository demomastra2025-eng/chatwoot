# Миграция OneLink Voice AI на Pipecat — Implementation Plan

> **Для реализации:** выполнять задачи последовательно, сохраняя TDD-порядок и обязательные stop-gates этого документа.

**Goal:** заменить самописную orchestration-часть `services/onelink-ai-voice` на параллельный Pipecat runtime без изменения Rails/media контрактов и без влияния на `human_operator` SIP-потоки.

**Architecture:** внедрить новый Python sidecar `services/onelink-ai-voice-pipecat`, который принимает те же attach-контракты, подключается WebSocket-клиентом к существующему `chatwoot_media_server` runtime stream и отправляет существующие OneLink callbacks. Legacy Node service остаётся рабочим до завершения canary и на первом этапе продолжает владеть server-side Janus SIP registration/signaling, существующими browser bridge/operator/app ветками и legacy AI pipeline для non-canary; только модельная orchestration выбранного AI-звонка передаётся либо legacy Node pipeline, либо Pipecat. Rails выбирает runtime один раз на звонок по явному allowlist и сохраняет выбор в metadata. Первая parity-версия использует Pipecat как runtime/orchestrator и `GeminiLiveLLMService` как модельный backend; полное удаление Gemini выполняется отдельным provider/cascade этапом после выбора STT/LLM/TTS.

**Tech Stack:** Python 3.11, `pipecat-ai==1.5.0`, FastAPI/Uvicorn, Pipecat `WebsocketClientTransport`, custom `FrameSerializer`, Silero VAD, httpx, pytest/pytest-asyncio, Ruff; существующие Rails, Go media-server, Docker Compose.

---

## 1. Зафиксированный контекст и ограничения

### 1.1 Локальные references

- Pipecat core repo: `/root/crafty/example/pipecat-library/pipecat`
  - Version: `v1.5.0`
  - Commit: `f97595f9ccdec52ece7561ecf642c0eec63fdefe`
- Pipecat examples repo: `/root/crafty/example/pipecat-library/pipecat-examples`
  - Commit: `4f84631a59f3e141ecfae917cbacf184298875bc`
- Релевантные примеры:
  - `/root/crafty/example/pipecat-library/pipecat-examples/websocket/bot.py`
  - `/root/crafty/example/pipecat-library/pipecat-examples/whatsapp/bot.py`
  - `/root/crafty/example/pipecat-library/pipecat-examples/gemini-live-starters/phone-bot/bot.py`
  - `/root/crafty/example/pipecat-library/pipecat-examples/gemini-live-starters/phone-bot/bot-cascade.py`
- Релевантные Pipecat abstractions:
  - `Pipeline`, `PipelineWorker`, `PipelineParams`, `WorkerRunner`
  - `WebsocketClientTransport`, `WebsocketClientParams`
  - `FrameSerializer`, `InputAudioRawFrame`, `OutputAudioRawFrame`
  - `GeminiLiveLLMService`
  - `LLMContext`, `LLMContextAggregatorPair`, `LLMUserAggregatorParams`
  - `SileroVADAnalyzer`
  - `FunctionCallParams`, `FunctionCallResultFrame`
  - `TranscriptionFrame`, `InterimTranscriptionFrame`
  - `UserTurnStoppedMessage`, `AssistantTurnStoppedMessage`
  - `TurnTrackingObserver`, `UserBotLatencyObserver`

### 1.2 Важное терминологическое решение

Pipecat — **не model provider**, а orchestration framework/runtime. Поэтому не заменять Rails `ai.provider = gemini-live` значением `pipecat`.

Разделить настройки:

- `runtime_engine`: `legacy_node` или `pipecat`;
- `realtime_provider`: сначала `gemini-live`, затем выбранный cascade/provider;
- `model`, `voice`, `language`: остаются provider-specific.

Это сохраняет смысл существующих Voice Settings и позволяет независимо откатывать runtime и модельный backend.

### 1.3 Неподвижные границы

1. Не менять `Telephony::InboundRoutingService` и алгоритм выбора `operator`/`ai`, кроме передачи уже вычисленного AI-route в runtime selector.
2. Pipecat runtime принимает только:
   - `routing.action == ai`/AI-compatible action;
   - Janus `sip_profile.profile_kind == voice_agent` и `voice_agent == true`;
   - WhatsApp AI route, уже подтверждённый Rails.
3. Не передавать в Pipecat operator credentials/profile и не подключать `human_operator` SIP profiles.
4. Rails остаётся control/data plane; Pipecat не пишет напрямую в БД.
5. Audio остаётся на media-server/runtime WebSocket path.
6. OneLink callbacks, их auth, idempotency, sequencing и terminal reconciliation сохраняются.
7. `stream_url` содержит одноразовый capability token: не логировать URL/query и не пытаться подключить два runtime к одному stream.
8. Runtime выбирается один раз до attach и остаётся sticky до terminal state; никакого автоматического переключения между runtime после открытия media stream.

### 1.4 Текущий рабочий репозиторий

На момент повторного аудита `onelink/chatwoot` находится на `dev/content-postiz-native-module`, HEAD `c910e660b9f3d157e33dafa3c144dfc202965d53`, с большим количеством чужих tracked-изменений. SHA и dirty state являются снимком, а не базой реализации: перед началом заново снять branch/HEAD/status. Реализацию выполнять в отдельном чистом worktree/ветке; текущий WIP не менять и не включать в diff.

### 1.5 Критическая граница server-side Janus

Текущий `services/onelink-ai-voice/src/janus/server-runtime.js` сам регистрирует только managed `voice_agent` SIP profiles, принимает Janus INVITE и напрямую вызывает `this.app.handleCall(...)`. Поэтому Rails `JanusSipAttachService` покрывает browser-assisted attach, но **не является единственной точкой входа server-side Janus**.

Обязательная целевая схема первого этапа:

1. Существующий Node service продолжает владеть SIP registration, INVITE/accept/hangup, browser bridge/operator/app ветками и созданием `chatwoot_media_server` session; эти ветки не переносятся в Pipecat.
2. Он запрашивает Rails route до ответа на звонок.
3. Для `operator`/`reject`/обычного `app` выполняется существующая ветка без runtime selector и без вызова Pipecat.
4. Только для подтверждённого `action == ai` и `sip_profile.voice_agent == true` Rails возвращает sticky `runtime_engine`/selection reason.
5. При `legacy_node` Node открывает runtime stream локально как сейчас.
6. При `pipecat` Node отвечает через существующий Janus/media adapter, но **не открывает one-time `stream_url` локально**: он передаёт attach payload в Pipecat, который становится единственным consumer stream URL.
7. Node в Pipecat-ветке не запускает Gemini, tools, transcript buffers, recording writer или AI finalizer; он сохраняет только transport ownership и закрывает Janus/media leg при terminal signal/stream close.
8. Attach failure после создания stream capability завершается fail-closed; запрещён автоматический local fallback, который может создать двух consumers или двойную finalization.
9. Полное удаление Node service невозможно, пока Janus SIP adapter не вынесен в отдельный gateway/media-plane компонент.

---

## 2. Mapping: текущий OneLink контракт → Pipecat

| OneLink surface | Pipecat abstraction | Реализация/примечание |
|---|---|---|
| `WebsocketRuntimeMediaStream` / `runtime_stream.stream_url` | `WebsocketClientTransport` | Pipecat уже имеет client transport; новый transport писать не нужно. Нужен только serializer OneLink JSON/base64 protocol. |
| Вход `AUDIO_IN`, PCM16 mono 16 kHz, 20 ms/640 bytes | `FrameSerializer.deserialize()` → `InputAudioRawFrame` | Валидировать type, base64, размер, mime/rate; invalid frame не должен падать сессией. |
| Выход `AUDIO_OUT`, PCM16 mono 8 kHz, 20 ms/320 bytes | `OutputAudioRawFrame` → `FrameSerializer.serialize()` | `audio_out_sample_rate=8000`, `audio_out_10ms_chunks=2`, `add_wav_header=False`; сериализовать JSON с `mime_type=audio/pcm;rate=8000`. |
| `VoiceApplication` + `VoiceSession` | `CallSession` + `PipelineWorker` | Один worker на один call_ref; lifecycle контролирует `SessionManager`. |
| `SessionRegistry` | `SessionManager` | Atomic reserve by `call_ref`, duplicate attach idempotency, max sessions, terminal cleanup. |
| `GeminiLiveClient` | `GeminiLiveLLMService` | Только parity-этап. Pipecat управляет audio/text/function calls; OneLink не держит собственный provider WebSocket. |
| `buildSystemPrompt` + context payload | `LLMContext` + `LLMContextAggregatorPair` | `realtime_service_mode=True`; system instruction строится из существующего `ai_context`. |
| Caller/AI transcripts | `TranscriptionFrame`, `InterimTranscriptionFrame`, aggregator events | Новый `TranscriptSink` нормализует `speaker`, `final`, `provider`, timestamp и отправляет существующий callback. |
| Caller barge-in/interruption | `SileroVADAnalyzer` в `LLMUserAggregatorParams` + Pipecat interruption frames | Обязательно даже с Gemini Live: reference отмечает, что `GeminiLiveLLMService` сам не выдаёт user turn start/stop. |
| Tool schemas | `LLMContext(tools=...)` / Pipecat function schemas | Конвертировать существующие OneLink schemas без изменения Rails tools API. |
| `ToolExecutor` | catch-all/explicit `llm.register_function` + `FunctionCallParams` | Сохранять tool_call_id, bounded timeout, idempotency, mutation fencing и late-result policy. |
| Async tool result | `result_callback` / `FunctionCallResultProperties` | Для realtime provider промежуточные результаты не поддерживаются; отправлять только final provider result, а промежуточный/late status сохранять в OneLink events. |
| `DialogueDirector` fillers | custom `DialoguePolicyProcessor` | Для realtime parity — provider text prompt; для cascade — `TTSSpeakFrame`. Не смешивать механизм с business tools. |
| Silence prompts/max silence | aggregator/user-idle events + `SilencePolicy` | Сохранить first/second/final timeout contract; terminal action проходит через единый finalizer. |
| Transcript/event buffers | `TranscriptBuffer`/`EventBuffer` adapters | Batch, retry, monotonic sequence, bounded memory, flush-before-finalize. |
| Recording writer | `OneLinkRecordingProcessor`/writer | Сохранять inbound/outbound channels и текущий recording-ready callback/storage contract; не считать `start` успехом записи. |
| `safeEvent` / `safeControl` | `OneLinkLifecycleObserver` + callback client | Нормализовать Pipecat frames/worker events в текущие Rails event/control types. |
| Completion/finalization | `SessionFinalizer` around worker termination | Exactly-once terminal state; flush transcript/events/recording, затем finalization. |
| Existing runtime metrics | Pipecat metrics + custom observer | TTFB/turn latency/tool latency/audio bytes/callback retries с call/session refs, без secrets. |
| Node health/internal HTTP | FastAPI `/health`, attach endpoints | Ответы и status codes должны быть contract-compatible: `202 accepted`, `401`, `422`, `503`, duplicate behavior. |

---

## 3. Целевой code layout

Создать параллельный сервис:

```text
services/onelink-ai-voice-pipecat/
├── Dockerfile
├── README.md
├── pyproject.toml
├── uv.lock
├── app/
│   ├── __init__.py
│   ├── main.py
│   ├── config.py
│   ├── api/
│   │   ├── auth.py
│   │   ├── models.py
│   │   └── routes.py
│   ├── clients/
│   │   └── onelink.py
│   ├── media/
│   │   └── serializer.py
│   ├── pipeline/
│   │   ├── factory.py
│   │   ├── context.py
│   │   ├── dialogue_policy.py
│   │   ├── lifecycle_observer.py
│   │   └── transcript_sink.py
│   ├── recordings/
│   │   └── writer.py
│   ├── sessions/
│   │   ├── manager.py
│   │   ├── session.py
│   │   └── finalizer.py
│   └── tools/
│       ├── schemas.py
│       └── executor.py
└── tests/
    ├── fixtures/
    ├── contract/
    ├── integration/
    └── unit/
```

Не копировать Pipecat source в OneLink. Production dependency pin: `pipecat-ai==1.5.0`; `uv.lock` обязателен.

---

## 4. Пошаговый TDD-план

### Task 0: Снять golden contracts legacy runtime

**Objective:** превратить текущие Node tests/payloads в формальные fixtures, чтобы Python service реализовывал доказуемо тот же boundary.

**Files:**
- Read/reference: `services/onelink-ai-voice/test/janus-internal-server.test.js`
- Read/reference: `services/onelink-ai-voice/test/whatsapp-internal-server.test.js`
- Read/reference: `services/onelink-ai-voice/test/onelink-client.test.js`
- Create: `services/onelink-ai-voice-pipecat/tests/fixtures/janus_attach.json`
- Create: `services/onelink-ai-voice-pipecat/tests/fixtures/whatsapp_attach.json`
- Create: `services/onelink-ai-voice-pipecat/tests/fixtures/runtime_audio_in.json`
- Create: `services/onelink-ai-voice-pipecat/tests/contract/test_attach_contract.py`

**Steps:**
1. Зафиксировать `202` response shape для обоих attach endpoints.
2. Зафиксировать `401 unauthorized`, blank token `503`, malformed/missing fields `422`/legacy-equivalent.
3. Зафиксировать запрет Janus attach для `human_operator` и non-AI route.
4. Зафиксировать callback payload keys для context, events, transcripts, tools, recording-ready, finalization.
5. Запустить legacy baseline:
   - `cd services/onelink-ai-voice && npm test`
   - Expected: текущий baseline без новых failures (на предыдущем срезе 166/166).
6. Запустить пока отсутствующий Python contract test и убедиться, что он падает до scaffold.

### Task 1: Scaffold и fail-closed configuration

**Objective:** создать воспроизводимый Python service с health endpoint, locked dependencies и строгой config validation.

**Files:**
- Create: `services/onelink-ai-voice-pipecat/pyproject.toml`
- Create: `services/onelink-ai-voice-pipecat/uv.lock`
- Create: `services/onelink-ai-voice-pipecat/Dockerfile`
- Create: `services/onelink-ai-voice-pipecat/app/config.py`
- Create: `services/onelink-ai-voice-pipecat/app/main.py`
- Create: `services/onelink-ai-voice-pipecat/tests/unit/test_config.py`
- Create: `services/onelink-ai-voice-pipecat/tests/contract/test_health.py`

**Steps:**
1. Написать failing tests для missing internal token, invalid callback URL, unsupported provider, invalid session limits.
2. Pin `pipecat-ai==1.5.0`; добавить только реально используемые extras (`google`, `websocket`, `silero`) и test tooling.
3. Реализовать immutable settings; не печатать secret values.
4. `/health` должен различать process liveness и readiness (config/provider initialized), но не обращаться к Rails/Google на каждый probe.
5. Проверить:
   - `uv sync --frozen`
   - `uv run pytest tests/unit/test_config.py tests/contract/test_health.py -q`
   - `uv run ruff check app tests`

### Task 2: Attach API и SessionManager

**Objective:** принять существующие Rails attach payloads, ответить до завершения звонка и гарантировать одну owner-session на `call_ref`.

**Files:**
- Create: `app/api/auth.py`
- Create: `app/api/models.py`
- Create: `app/api/routes.py`
- Create: `app/sessions/manager.py`
- Create: `tests/contract/test_attach_contract.py`
- Create: `tests/unit/test_session_manager.py`

**Steps:**
1. Написать failing tests на exact `202` bodies:
   - Janus: `{status, mode, call_ref, transport}`;
   - WhatsApp: `{status, mode, call_ref}`.
2. Написать tests на constant-time bearer comparison, blank-token disabled state и redacted logs.
3. Валидировать Janus AI/`voice_agent` invariant до запуска background task.
4. Реализовать `SessionManager.reserve(call_ref)` с atomic duplicate handling:
   - повтор того же payload возвращает accepted/current state;
   - conflicting payload возвращает `409` и не стартует второй worker.
5. Ограничить max concurrent sessions и вернуть `503 capacity_exhausted` до открытия stream.
6. Проверить, что HTTP response приходит немедленно, а worker остаётся background task.

### Task 3: OneLink media serializer поверх Pipecat WebSocket client

**Objective:** без изменений Go media-server преобразовывать OneLink JSON/base64 audio frames в Pipecat frames и обратно.

**Files:**
- Create: `app/media/serializer.py`
- Create: `tests/unit/test_media_serializer.py`
- Create: `tests/integration/test_media_websocket.py`
- Reference: `enterprise/media-server/internal/server/runtime_stream.go`
- Reference: Pipecat `src/pipecat/transports/websocket/client.py`

**Steps:**
1. Failing tests: `AUDIO_IN` 640-byte PCM16/16k → `InputAudioRawFrame(sample_rate=16000, num_channels=1)`.
2. Failing tests: `OutputAudioRawFrame` → `AUDIO_OUT`, PCM16/8k, no WAV header, valid base64.
3. Добавить negative tests: unknown type, invalid base64, empty data, frame >64 KiB, wrong rate/channels.
4. Реализовать только `FrameSerializer`; использовать Pipecat `WebsocketClientTransport`, не писать собственную connection loop.
5. Настроить:
   - `audio_in_enabled=True`
   - `audio_in_sample_rate=16000`
   - `audio_out_enabled=True`
   - `audio_out_sample_rate=8000`
   - `audio_out_10ms_chunks=2`
   - `add_wav_header=False`
6. Интеграционный fake WebSocket должен доказать 20 ms pacing/320-byte output frames и корректное завершение при remote close.
7. Go regression:
   - `cd enterprise/media-server && go test ./...`
   - `go test ./internal/server -run 'TestRuntime(FFmpegProducesRTPBeforeInputEOF|DecodeFFmpegProducesPCMBeforeInputEOF)$' -count=10`

### Task 4: Rails context и OneLink callback client

**Objective:** сохранить существующий Rails как источник assistant/context/tools и единственный persistence boundary.

**Files:**
- Create: `app/clients/onelink.py`
- Create: `app/pipeline/context.py`
- Create: `tests/unit/test_onelink_client.py`
- Create: `tests/unit/test_context.py`
- Reference: `app/services/telephony/ai_voice/context_builder.rb`
- Reference: `services/onelink-ai-voice/src/onelink/client.js`

**Steps:**
1. Зафиксировать request/response fixtures для context endpoint и всех callback endpoints.
2. Реализовать shared auth headers, connect/read timeout, bounded retry only для idempotent callbacks.
3. Не retry-ить mutable tool dispatch без idempotency key.
4. Коррелировать каждый callback по `call_ref`, `call_session_id`, `account_id`, `conversation_id`, `runtime_session_id`, `runtime_engine=pipecat`.
5. Реализовать prompt/context normalization без изменения Rails payload keys.
6. Redaction tests: bearer, API key, SIP password, stream_url query и recording URL не попадают в logs/errors.

### Task 5: Pipecat realtime parity pipeline

**Objective:** запустить реальный `PipelineWorker` с Gemini Live через Pipecat и получить двусторонний audio + turn boundaries.

**Files:**
- Create: `app/pipeline/factory.py`
- Create: `app/sessions/session.py`
- Create: `tests/unit/test_pipeline_factory.py`
- Create: `tests/integration/test_realtime_session.py`

**Pipeline order:**

```text
WebsocketClientTransport.input()
→ LLMContext user aggregator (Silero VAD)
→ GeminiLiveLLMService
→ transcript/lifecycle processors
→ WebsocketClientTransport.output()
→ assistant aggregator
```

**Steps:**
1. Failing test на построение pipeline из normalized `ai_context` (`model`, `voice`, `language`, prompt, tools, max duration).
2. Использовать `LLMContextAggregatorPair(..., realtime_service_mode=True)`.
3. Настроить `LLMUserAggregatorParams(vad_analyzer=SileroVADAnalyzer(...))`; не полагаться на Gemini server VAD для Pipecat turn events.
4. `PipelineParams(enable_metrics=True, enable_usage_metrics=True)`; bounded idle/max-duration cancellation.
5. Initial greeting запускать через context + `LLMRunFrame`, а не direct audio bypass.
6. Mock provider integration test должен доказать:
   - incoming PCM доходит до LLM service;
   - generated audio сериализуется в media stream;
   - disconnect/hangup отменяет worker;
   - cancellation не создаёт второй finalization.
7. Реальный provider smoke выполнять только в DEV с тестовым API key/config, без вывода key.

### Task 6: Transcript parity и interruption semantics

**Objective:** сохранить caller/AI transcripts, final/interim markers и controlled barge-in.

**Files:**
- Create: `app/pipeline/transcript_sink.py`
- Create: `tests/unit/test_transcript_sink.py`
- Create: `tests/integration/test_interruptions.py`

**Steps:**
1. Failing tests на mapping `TranscriptionFrame`/`InterimTranscriptionFrame` и aggregator stop events в OneLink transcript payload.
2. Дедуплицировать final transcript по `(speaker, provider_item_id/turn_id, normalized_text)` без потери повторно сказанных фраз в разных turns.
3. Сохранить `speaker=caller|assistant`, `final`, provider, timestamp, monotonic sequence.
4. Barge-in test: caller speech во время bot audio вызывает Pipecat interruption и очищает только Pipecat output queue текущего AI-call.
5. Не посылать interrupt/clear события в Janus operator/browser paths.
6. Сопоставить текущие `caller_interrupted`, `media_stream_*`, `realtime_audio_*` events с provider-neutral metadata (`runtime_engine`, `realtime_provider`).

### Task 7: OneLink tools и bounded/late results

**Objective:** перенести текущий tool contract без double mutations и без бесконечного молчания.

**Files:**
- Create: `app/tools/schemas.py`
- Create: `app/tools/executor.py`
- Create: `app/pipeline/dialogue_policy.py`
- Create: `tests/unit/test_tool_schemas.py`
- Create: `tests/unit/test_tool_executor.py`
- Create: `tests/integration/test_tool_dialogue.py`
- Reference: `services/onelink-ai-voice/src/tools/tool-executor.js`
- Reference: `services/onelink-ai-voice/src/dialogue/dialogue-director.js`

**Steps:**
1. Failing tests на schema conversion, unknown tool, malformed args, timeout, retryable/non-retryable result.
2. Передавать `tool_call_id` как idempotency key Rails dispatch.
3. Для mutation tools использовать exactly-once fencing на Rails side; runtime retry разрешить только после явного idempotent response contract.
4. Реализовать bounded foreground wait и events `tool_started`, `tool_completed`, `tool_failed`, `tool_async_result_*`.
5. Учесть Pipecat v1.5 limitation: realtime services не принимают streamed intermediate tool results. В provider возвращать только final result; late/intermediate status хранить как OneLink event и при необходимости инициировать отдельный continuation turn.
6. Сохранить audible fillers/tool-delay/failure behavior:
   - realtime parity: controlled provider text instruction;
   - будущий cascade: `TTSSpeakFrame`.
7. Interruption во время tool wait не должна отменять уже начатую server mutation без явной cancel semantics.

### Task 8: Silence, max duration и terminal lifecycle

**Objective:** все завершения сходятся в один exactly-once finalizer.

**Files:**
- Create: `app/sessions/finalizer.py`
- Create: `app/pipeline/lifecycle_observer.py`
- Create: `tests/unit/test_finalizer.py`
- Create: `tests/integration/test_terminal_races.py`

**Steps:**
1. Табличные failing tests для terminal reasons: caller hangup, provider disconnect, max duration, max silence, tool-requested end, transfer, media error, provider error, cancellation.
2. `SessionFinalizer` должен atomic compare-and-set terminal state.
3. Flush order:
   1. остановить приём нового audio/tool work;
   2. остановить output;
   3. flush transcripts/events;
   4. finalize recording;
   5. отправить finalization;
   6. удалить session из registry.
4. Late callback после terminal не меняет end reason и не воскресит session.
5. Race tests: hangup + provider error; max silence + tool result; duplicate attach + disconnect.
6. Ошибка callback не должна зависить worker бесконечно: bounded retries, persist failure metric, terminal cleanup.

### Task 9: Recording parity

**Objective:** сохранить двухстороннюю запись, stored-recording-ready и playable verification.

**Files:**
- Create: `app/recordings/writer.py`
- Create: `tests/unit/test_recording_writer.py`
- Create: `tests/integration/test_recording_finalize.py`
- Reference: `services/onelink-ai-voice/src/recordings/recording-writer.js`
- Reference: `app/controllers/internal/voice/recordings_controller.rb`
- Reference: `app/services/telephony/stored_recording_ready_service.rb`

**Steps:**
1. Golden tests на inbound/outbound PCM, sample-rate normalization и channel duration.
2. Сохранять текущий storage layout/callback contract; volume остаётся shared storage.
3. Partial direction/write failure → `recording_incomplete` с missing direction, не false success.
4. Final callback только после fsync/close и валидного file metadata.
5. Integration test должен открыть полученный WAV/контейнер и проверить channels, duration >0, sample rate и readability.
6. Rails spec должен доказать linkage к `Telephony::CallSession`/conversation и отсутствие duplicate attachment.

### Task 10: Provider-neutral configuration и optional cascade mode

**Objective:** после runtime parity позволить убрать Gemini backend без повторного изменения Rails/media contracts.

**Files:**
- Modify: `app/config.py`
- Modify: `app/pipeline/factory.py`
- Create: `app/pipeline/providers.py`
- Create: `tests/unit/test_provider_factory.py`
- Modify: `app/services/telephony/ai_voice/voice_settings_defaults.rb`
- Modify only if UI exposure is approved: `app/javascript/dashboard/components-next/captain/pageComponents/assistant/settings/AssistantSystemSettingsForm.vue`
- Test: `spec/services/telephony/ai_voice/context_builder_spec.rb`
- Test: `app/javascript/dashboard/components-next/captain/pageComponents/assistant/settings/AssistantSystemSettingsForm.spec.js`

**Steps:**
1. Не добавлять неподтверждённые vendor dependencies заранее.
2. Поддержать internal modes:
   - `realtime`: Pipecat + Gemini Live (migration parity);
   - `cascade`: Pipecat + выбранные STT → LLM → TTS.
3. До реализации `cascade` принять product/ops решение по STT/LLM/TTS, языку `ru-KZ`, latency, data residency, voices и стоимости.
4. Provider factory tests должны fail closed на неполную cascade configuration.
5. Не использовать `provider=pipecat`; отдавать `runtime_engine=pipecat`, фактический provider/model отдельно.
6. UI изменение отложить до успешного DEV canary; первый rollout управлять server-side allowlist.

### Task 11: Sticky runtime selector и оба Janus entry paths

**Objective:** выбирать legacy/Pipecat до открытия one-time runtime stream на account/inbox/voice-agent-profile allowlist, покрыть browser-assisted и server-side Janus и не затрагивать operator route.

**Files:**
- Create: `app/services/telephony/ai_voice/runtime_endpoint_resolver.rb`
- Create: `spec/services/telephony/ai_voice/runtime_endpoint_resolver_spec.rb`
- Modify: `app/services/telephony/inbound_routing_service.rb` только для добавления runtime metadata в уже вычисленное AI decision; алгоритм route не менять
- Modify: `app/services/telephony/ai_voice/janus_sip_runtime_client.rb`
- Modify: `app/services/telephony/ai_voice/janus_sip_attach_service.rb`
- Create: `services/onelink-ai-voice/src/pipecat/attach-client.js`
- Modify: `services/onelink-ai-voice/src/app/voice-application.js`
- Modify: `services/onelink-ai-voice/src/janus/server-runtime.js` только если нужен явный transport lifecycle hook; SIP registration contract не менять
- Modify: `enterprise/app/services/whatsapp/ai_voice_runtime_client.rb`
- Modify: `enterprise/app/services/whatsapp/ai_voice_call_service.rb`
- Modify tests:
  - `spec/services/telephony/inbound_routing_service_spec.rb`
  - `spec/services/telephony/ai_voice/janus_sip_runtime_client_spec.rb`
  - `spec/services/telephony/ai_voice/janus_sip_attach_service_spec.rb`
  - `services/onelink-ai-voice/test/voice-application.test.js`
  - `services/onelink-ai-voice/test/janus-server-runtime.test.js`
  - `spec/services/whatsapp/ai_voice_runtime_client_spec.rb`
  - `spec/services/whatsapp/ai_voice_call_service_spec.rb`

**Configuration:**

- `ONELINK_AI_VOICE_PIPECAT_ENABLED=false` default;
- `ONELINK_AI_VOICE_PIPECAT_BASE_URL`;
- отдельный internal bearer token для Node/Rails → Pipecat attach, без переиспользования Janus SIP credentials;
- allowlists: account IDs, inbox IDs, voice-agent SIP profile IDs;
- legacy `ONELINK_AI_VOICE_BASE_URL` остаётся без изменения.

**Steps:**
1. Failing resolver table tests: disabled, allowlisted account, inbox, profile, malformed allowlist, missing Pipecat URL.
2. Resolver возвращает `{engine, base_url, reason}`; URL/token не сохранять и не логировать. В route payload отдавать только `engine` и безопасный reason/version, URL остаётся process config вызывающего adapter/client.
3. Добавить dependency injection `base_url:` в Rails runtime clients, сохранив legacy env fallback.
4. Browser-assisted Janus selector вызывается только после `ai_route?` и `sip_profile.voice_agent?`.
5. Server-side Janus: `VoiceApplication` сначала получает Rails route. Ветка `routeAction === 'operator'` должна завершаться текущим operator flow **до** любого Pipecat selector/client call.
6. Для server-side подтверждённого AI route и `voice_agent` profile:
   - `legacy_node`: текущие `answer → startMediaStream → startRealtimeBridge` без изменений;
   - `pipecat`: `answer` создаёт media/runtime capability; Node не вызывает `call.stream()` и не запускает local realtime, а отправляет Pipecat attach payload с единственным `stream_url` consumer contract.
7. Pipecat attach client отвечает bounded `202`; Node продолжает владеть Janus signaling/transport lifecycle, но не дублирует AI callbacks/finalizer/recording writer.
8. WhatsApp selector вызывается только после `routing_decision.ai?`.
9. Сохранить в `ai_voice` metadata: `runtime_engine`, selection reason, Pipecat version; не сохранять token/URL.
10. Negative specs:
    - `human_operator` SIP profile никогда не вызывает resolver/Pipecat client;
    - server-side `routeAction === operator` никогда не вызывает Pipecat client и сохраняет текущий dial flow;
    - empty allowlist = 0 Pipecat calls;
    - Pipecat branch не вызывает local `call.stream()`/Gemini/tool/finalizer;
    - один `stream_url` передаётся ровно одному consumer.
11. Не делать transparent fallback после stream capability creation/ownership. Attach failure проходит fail-closed failure/reconciliation path; следующий звонок возвращается на legacy после выключения allowlist.

### Task 12: Compose, image и disabled-by-default deployment

**Objective:** запустить оба runtime параллельно, не переключая трафик автоматически.

**Files:**
- Modify: `/root/crafty/docker-compose.development.yml`
- Modify: `/root/crafty/docker-compose.production.yml`
- Modify: `/root/crafty/PRODUCTION.md`
- Create/modify: `services/onelink-ai-voice-pipecat/Dockerfile`
- Create: `services/onelink-ai-voice-pipecat/README.md`

**Steps:**
1. Добавить service `onelink_ai_voice_pipecat` на внутренний port `8082`; legacy `onelink_ai_voice:8081` оставить.
2. Отдельный image tag и healthcheck; `cap_drop: ALL`, `no-new-privileges`, non-root user, bounded logs.
3. Подключить shared storage только если recording tests подтверждают необходимый path.
4. Pipecat service не нуждается в Janus SIP credentials и не должен быть источником SIP registrations; существующий Node Janus adapter и media-plane остаются. Не переносить и не дублировать `human_operator` profiles/credentials.
5. Передавать callback auth/API credentials через env без печати в compose output/report.
6. Compose validation:
   - `docker compose --env-file .env.production -f docker-compose.production.yml config -q`
7. Build:
   - `docker compose --env-file .env.production -f docker-compose.production.yml build onelink_ai_voice_pipecat`
8. Container smoke в DEV:
   - health ready;
   - unauthorized attach → 401;
   - valid fixture attach → 202;
   - no allowlist → ни одного live call на Pipecat.
9. PROD build/deploy/recreate только после отдельного разрешения пользователя. Disabled deploy не должен перезапускать `janus_gateway`; применять только новые/изменённые services и штатный rolling deploy Rails при необходимости.

### Task 13: Полная code-level verification

**Objective:** доказать совместимость всех затронутых planes до live calls.

**Commands:**

```bash
cd services/onelink-ai-voice-pipecat
uv sync --frozen
uv run ruff check app tests
uv run pytest -q

cd ../onelink-ai-voice
npm test

cd ../../enterprise/media-server
go test ./...
go test ./internal/server -run 'TestRuntime(FFmpegProducesRTPBeforeInputEOF|DecodeFFmpegProducesPCMBeforeInputEOF)$' -count=10

cd ../..
bundle exec rspec \
  spec/services/telephony/ai_voice/runtime_endpoint_resolver_spec.rb \
  spec/services/telephony/inbound_routing_service_spec.rb \
  spec/services/telephony/ai_voice/janus_sip_runtime_client_spec.rb \
  spec/services/telephony/ai_voice/janus_sip_attach_service_spec.rb \
  spec/services/telephony/ai_voice/context_builder_spec.rb \
  spec/services/whatsapp/ai_voice_runtime_client_spec.rb \
  spec/services/whatsapp/ai_voice_call_service_spec.rb
```

**Required assertions:**

- Pipecat tests include auth, cross-account fencing, duplicate attach, media framing, interruption, tools, transcript flush, recording, finalization races.
- Legacy Node test suite остаётся green до retirement.
- Go media-server не меняет runtime protocol.
- Rails specs подтверждают zero selection для operator profiles.
- Node specs подтверждают обе server-side Janus ветки: operator unchanged и Pipecat single-consumer handoff.
- Финальный diff не содержит unrelated current WhatsApp WIP и secrets.

---

## 5. DEV/live validation matrix

Выполнять только на отдельном AI test number/profile.

| Case | Legacy control | Pipecat canary | Evidence |
|---|---:|---:|---|
| Janus inbound AI answer, browser-assisted | PASS required | PASS required | Rails route + runtime attach + media WS + transcript + terminal timeline |
| Janus inbound AI answer, server-side SIP registration | PASS required | PASS required | Node Janus adapter + Rails route/engine + single Pipecat attach + media WS + terminal timeline |
| Audio caller→AI | PASS | PASS | input frame counts/sample rate + recognized caller transcript |
| Audio AI→caller | PASS | PASS | first audio timestamp + 320-byte/8k frames + audible check |
| Barge-in | PASS | PASS | interrupt event, output queue clear, no stale audio |
| Tool success | PASS | PASS | same tool args/result, one mutation |
| Tool timeout/late result | PASS | PASS | filler/failure behavior, no duplicate mutation |
| Caller hangup during tool | PASS | PASS | terminal once; late tool cannot resurrect call |
| Silence prompts/end | PASS | PASS | configured timings/reason |
| Recording | PASS | PASS | stored, linked, playable, both directions |
| WhatsApp AI call | PASS | PASS if in scope | accept→media→runtime→terminal |
| Human operator SIP negative control | PASS | **must never touch Pipecat** | zero Pipecat attach logs/metrics for human_operator |

Сравнить legacy/Pipecat по одинаковому scripted dialogue минимум на:

- first audible response latency;
- p50/p95 turn latency;
- transcript completeness;
- tool latency/error rate;
- media framing/pacer drops;
- callback retries/failures;
- terminal/finalization completeness;
- recording completeness.

---

## 6. Rollout

### Stage A — DEV parity

1. Pipecat service запущен параллельно.
2. Только test account/inbox/`voice_agent` profile в allowlist.
3. Выполнить matrix выше.
4. Никакого PROD изменения.

### Stage B — PROD deploy disabled

Только после явного разрешения:

1. Build/deploy Pipecat container.
2. `ONELINK_AI_VOICE_PIPECAT_ENABLED=false`.
3. Проверить health, container logs, no traffic, compose ps.
4. Legacy runtime остаётся active default.
5. До и после deploy снять read-only baseline: routing modes, SIP profile kinds, active `voice_agent` profiles и количество Pipecat attaches. При неожиданном изменении baseline rollout остановить.
6. Не перезапускать `janus_gateway`; после deploy выполнить один согласованный operator control call и доказать zero Pipecat attach/session по его call ref.

### Stage C — один canary profile

1. Добавить один отдельный `voice_agent` SIP profile/test number в allowlist.
2. Не добавлять account-wide allowlist, если в аккаунте есть customer traffic.
3. Проверить 3–5 контролируемых звонков с tools, interruption, hangup, recording.
4. Подтвердить zero Pipecat events для `human_operator` профилей.

### Stage D — account/inbox cohorts

1. Расширять только явными allowlists, без случайного percentage routing.
2. Каждый этап сохраняет sticky engine selection на звонок.
3. Сравнивать с baseline; не смешивать deploy noise и fresh call window.

### Stage E — default switch

Возможен только после согласованных SLO и достаточного объёма canary evidence. Legacy Node service остаётся доступным для rollback минимум один согласованный observation window.

### Stage F — убрать Gemini backend

1. Выбрать и утвердить cascade vendors.
2. Пройти те же contract/live tests для `cascade`.
3. Переключать `realtime_provider`, не `runtime_engine`.
4. Gemini credentials удалять только после полного отсутствия Gemini sessions и подтверждённого rollback strategy.

### Stage G — retirement legacy orchestration

Удалить Gemini/orchestration части из `services/onelink-ai-voice` можно отдельной задачей после:

- отсутствия legacy-routed calls за согласованный период;
- закрытия rollback window;
- parity по recordings/tools/transcripts/finalization;
- финального security/dependency review.

Сам Node service/compose service нельзя удалять, пока он владеет server-side Janus SIP registration/signaling, browser bridge или operator/app ветками. Для полного удаления сначала вынести эти transport/routing adapters в отдельный `voice-agent-janus-gateway`/media-plane component, доказать registration/invite/hangup/operator parity и повторить operator negative-control matrix.

---

## 7. Rollback

### Immediate rollback mechanism

1. Убрать canary IDs из allowlist или установить `ONELINK_AI_VOICE_PIPECAT_ENABLED=false`.
2. Не переключать уже активные calls; дать им завершиться или завершить штатным terminal path.
3. Новые calls идут в legacy Node runtime.
4. Pipecat container не удалять до сбора logs/metrics.

### Zero-tolerance triggers

Откат немедленно, если:

- любой `human_operator` call попал в Pipecat;
- cross-account/inbox/profile mismatch;
- duplicate business mutation/tool execution;
- duplicate/conflicting finalization;
- capability token/credential появился в logs;
- запись привязалась к неправильному call/conversation.

### Performance/reliability triggers

Сначала зафиксировать legacy baseline. Откат cohort, если на достаточном fresh window:

- attach/media establishment error rate заметно выше baseline;
- first-audio или turn p95 деградирует больше согласованного порога;
- растут pacer drops/audio framing errors;
- transcript/recording/finalization completeness ниже baseline;
- callback queue/retry backlog не успевает дренироваться.

Не задавать окончательные численные SLO до измерения текущего legacy baseline на том же provider/profile.

---

## 8. Риски и меры

| Риск | Мера |
|---|---|
| Pipecat воспринимается как model provider | Раздельные `runtime_engine` и `realtime_provider`; первый этап сохраняет Gemini только для behavioral parity. |
| Gemini Live не даёт Pipecat user turn frames | Silero VAD в user aggregator; interruption tests обязательны. |
| One-time media stream token подключён дважды | Sticky selector до attach; без live audio shadowing/automatic fallback. |
| 16k input / 8k output mismatch | Explicit transport sample rates, 20 ms packet tests и Go integration suite. |
| Realtime tool late results не стримятся | Final-only provider result; late status через OneLink events/новый continuation turn. |
| Duplicate mutable tool | Rails idempotency key = tool_call_id; runtime не делает blind retry. |
| Terminal races | Atomic `SessionFinalizer`, monotonic event sequence, late-event fencing. |
| Recording считается успешной слишком рано | Success только после close/storage/link/playability checks. |
| Dirty current branch contaminates diff | Реализация в чистом worktree; финальный scoped diff review. |
| Operator regression | Pipecat allowlist только `voice_agent`; negative operator call test и zero-tolerance metric. |
| Server-side Janus обходит Rails attach selector | Rails engine metadata в AI route + selector branch в Node `VoiceApplication` до открытия stream; отдельные Node contract tests. |
| Node удалён вместе с legacy orchestration и потеряны SIP registrations | На первом этапе Node остаётся Janus adapter; полное удаление только после отдельной extraction/migration задачи. |

---

## 9. Открытые решения перед Task 10/PROD rollout

1. Нужно ли конечной целью полностью удалить Gemini backend или только заменить самописный Gemini runtime на Pipecat orchestration?
2. Если Gemini удаляется: какие STT, LLM и TTS vendors утверждены для `ru-KZ`, data residency, стоимости и latency?
3. Входит ли WhatsApp AI Voice в первый canary или сначала только Janus SIP?
4. Какой observation window и минимальное количество успешных canary calls нужны перед расширением cohort?
5. Нужен ли UI-переключатель runtime/provider после стабилизации, или настройка остаётся ops-only?

Эти вопросы не блокируют Tasks 0–9 и DEV parity, но блокируют полный отказ от Gemini и PROD default switch.

---

## 10. Definition of Done

### Code-level

- Новый Pipecat service имеет locked dependency tree, tests/lint green.
- Attach/media/callback contracts совместимы с legacy.
- Browser-assisted и server-side Janus entry paths имеют отдельные contract tests; `stream_url` имеет ровно одного consumer.
- Node baseline, Rails scoped specs и Go media tests green.
- Final diff не содержит unrelated WIP/secrets.

### DEV/live

- Browser-assisted и server-side Janus AI calls проходят route→attach→two-way audio→transcripts/tools→recording→terminal.
- Если включён WhatsApp scope — тот же lifecycle подтверждён для WhatsApp.
- Human operator negative control не создаёт ни одной Pipecat session.
- Legacy rollback проверен на новом звонке после выключения allowlist.

### PROD

- Только после отдельного разрешения.
- Disabled deploy health подтверждён отдельно от canary.
- Canary доказан свежими call refs/timestamps/logs/DB/API evidence.
- Непроверенные planes явно отмечены; Pipecat не называется production-ready до прохождения их live matrix.
