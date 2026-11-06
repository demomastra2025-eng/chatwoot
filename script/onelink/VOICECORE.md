# VoiceCore: изолированный DEV batch-ASR

Адаптер предназначен для `Telephony::CallSession` и существующего voice_call сообщения. Он выключен по умолчанию. Новых настроек в интерфейсе, миграций или переключения глобальной LLM-модели нет. Запуск/выкладка этим файлом не разрешены.

## Deployment configuration

| Переменная | Назначение |
| --- | --- |
| `ONELINK_VOICECORE_ENABLED` | Только точное `true` включает выбор локального пути; по умолчанию выключено. |
| `ONELINK_VOICECORE_ACCOUNT_IDS` | Явный список положительных account ID через запятую. При включении пустой/невалидный список — ошибка конфигурации. |
| `ONELINK_VOICECORE_URL` | Только HTTP loopback `127.0.0.1`/`::1`, origin или `/transcribe`; без credentials/query/fragment. HTTP proxy не используется. |
| `ONELINK_VOICECORE_TOKEN` | Секрет внутреннего Bearer-доступа, минимум32байта; не выводить в журнал/отчёт. |
| `ONELINK_VOICECORE_SPOOL_ROOT` | Абсолютный отдельный private directory, одинаково смонтированный Rails/runtime; symlink-компоненты запрещены. |

Граница DEV — отдельный согласованный deployment, а не Rails.env: DEV-контейнер тоже может работать с Rails.env=production. Не добавлять эти включающие настройки в PROD. Token не передавать командной строкой и не хранить в Git.

## Единственный поток

Существующие account flag/quota/cache проверяются до нового inference. У выбранного account service обращается к VoiceCore **до** cloud normalization, probe и LLM enrichment. У выключенного feature/невыбранного account старый provider продолжает работать. У выбранного VoiceCore ошибка не включает платный cloud fallback.

Источник берётся только из trusted CallSession. Локальный путь разрешается native `Storage::RecordingPaths` с account ID; legacy basename разрешён только через его tenant-scoped resolver. Remote key проверяется native `Storage::RecordingMetadata.local_key` до любого remote чтения. Поддерживаются account-first/provider-account storage layouts. Remote download передаётся chunk-by-chunk в ограниченный spool.

Rails создаёт private `<root>/<account_id>/<32hexjob>/audio.<ext>` (directory0700/file0600), сохраняя исходные байты/каналы. Расширения wav/mp3/ogg/m4a/flac, максимум100MiB. Runtime получает только account/job/фиксированное имя, доступ к spool только чтение; исходное storage не монтируется в runtime. Rails удаляет только свой job в ensure. Runtime обязан завершать worker/decode по deadline до client read deadline; аварийные остатки после process kill удаляются отдельной узкой TTL-процедурой перед повторным включением.

`POST /transcribe`, Content-Type application/json, Bearer token. Request≤16KiB:

```json
{"schema":"onelink.voicecore.request.v1","account_id":101,"job_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","audio_filename":"audio.wav","channel_map":{"0":"operator","1":"client"},"is_phone_call":true}
```

channel_map разрешается из native aliases; неизвестная/конфликтующая/неполная карта передаётся как `{}`. Явная zero-based0/1 и one-based1/2 различаются; смешанная0/1/2 не угадывается. Default operator/client по номеру канала отсутствует. Mono с явной стереокартой — ошибка формата, не повод молча менять роли.

Response≤2MiB со строго проверенными полями:

```json
{"schema":"onelink.voicecore.response.v1","account_id":101,"job_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","text":"Тест","dialogue_turns":[{"speaker":"unknown","channel":0,"start_sec":0.2,"end_sec":0.4,"text":"Тест"}],"language":"ru","duration_sec":2.0,"channels":1,"channel_status":"mono","model_version":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
```

model_version — SHA256 pinned runtime manifest. channels=1|2; channel_status=mono|mapped|unmapped; language=ru|kk|en|mixed|unknown. Числа времени finite,0≤start≤end≤duration(+0.1s tolerance), duration≤1800s. mapped speaker обязан совпадать с явной картой; mono/unmapped speaker=unknown. Короткие реплики и overlap сохраняются. Unsupported channel count, decoder failure и exception не являются пустым успехом. Валидная тишина — text пусто и dialogue_turns пустые с корректными probe metadata; Rails сохраняет нейтральную summary/no_answer без LLM.

Transport: connect2s, write10s, read120s, overall130s, automatic HTTP retry0, redirects запрещены. Runtime process deadline110s и bounded concurrency — серверная политика. Busy429/unavailable503/deadline504 и network timeout дают ограниченный retry штатным job (3попытки); invalid schema/auth/path/config — terminal. Клиент не переносит raw error body в лог. Лимиты — консервативные границы первого DEV, не обещание измеренной скорости.

Результат сохраняется native transaction с existing billed_at/unique call usage event. source=audio_transcription сохраняет прежнюю семантику учёта; provider=voicecore/model=manifest SHA явно показывают локальный источник. Структурные unknown роли, физический channel и дробные start/end сохраняются в transcript_items и provenance. UI показывает нейтральный канал/говорящего. Новый счётчик не добавлен; существующий legacy response counter и force semantics не меняются.

## Проверки и пределы

Целевые RSpec: `voice_core_client_spec`, `voice_core_recording_spool_spec`, `voice_core_recording_transcription_spec`, `call_recording_transcription_service_spec`, `call_transcript_spec`, job specs. Только synthetic bytes/fake HTTP/isolated DB. Отдельно проверяются runtime mono/stereo/reversed-map/no-speech/short-turn/overlap/codec/resource boundaries.

Эти проверки не доказывают качество ASR. Blind audio/provenance/человеческие эталоны, WER/CER, ошибки ролей и latency требуют отдельной разрешённой проверки pinned inference. Старые обучающие JSON/транскрипты пациентов не копировать в Git. `/clinic/learn`, внешний арбитр, модельные downloads и egress в DEV runtime выключены сервером. PROD и live DEV остаются вне разрешения этого документа.
