# VoiceCore: изолированный DEV batch-ASR

Адаптер предназначен для `Telephony::CallSession`/voice_call и нативных голосовых вложений `Messages::AudioTranscriptionService`. Он выключен по умолчанию. Новых настроек в интерфейсе, миграций или переключения глобальной LLM-модели нет. Запуск/выкладка этим файлом не разрешены.

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

Для звонка источник берётся только из trusted CallSession. Локальный путь разрешается native `Storage::RecordingPaths` с account ID; legacy basename разрешён только через его tenant-scoped resolver. Remote key проверяется native `Storage::RecordingMetadata.local_key` до любого remote чтения. Поддерживаются account-first/provider-account storage layouts. Remote download передаётся chunk-by-chunk в ограниченный spool.

Configured spool root, account и job обязаны принадлежать текущему UID и иметь точный mode0700; существующие foreign/group/world-readable/writeable directories отвергаются без chmod/chown. Все ancestors проверяются без symlink. Rails удерживает nofollow directory/file descriptors и dev/inode/uid/mode identities до конца обработки, проверяет их перед записью, inference и очисткой. Подмена root/account/job/file либо прав/владельца даёт fixed error; cleanup пропускает удаление, а не следует подмене. После подмены остаётся собственный staged остаток для отдельной безопасной уборки.

Rails создаёт private `<root>/<account_id>/<32hexjob>/audio.<ext>` (directory0700/file0600), сохраняя исходные байты/каналы. Расширения wav/mp3/ogg/m4a/flac/aac/webm, максимум100MiB. Runtime получает только account/job/фиксированное имя, доступ к spool только чтение; исходное storage не монтируется в runtime. Rails удаляет только свой job в ensure. Runtime обязан завершать worker/decode по deadline до client read deadline; аварийные остатки после process kill удаляются отдельной узкой TTL-процедурой перед повторным включением.

`POST /transcribe`, Content-Type application/json, Bearer token. Request≤16KiB:

```json
{"schema":"onelink.voicecore.request.v1","account_id":101,"job_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","audio_filename":"audio.wav","channel_map":{"0":"operator","1":"client"},"is_phone_call":true}
```

is_phone_call — только JSON boolean: true для звонка (default клиента), false для голосового сообщения. Строка «false» запрещена. channel_map разрешается из native aliases; неизвестная/конфликтующая/неполная карта передаётся как `{}`. Явная zero-based0/1 и one-based1/2 различаются; смешанная0/1/2 не угадывается. Default operator/client по номеру канала отсутствует. Mono с явной стереокартой — ошибка формата, не повод молча менять роли.

Response≤2MiB со строго проверенными полями:

```json
{"schema":"onelink.voicecore.response.v1","account_id":101,"job_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","text":"Тест","dialogue_turns":[{"speaker":"unknown","channel":0,"start_sec":0.2,"end_sec":0.4,"text":"Тест"}],"language":"ru","duration_sec":2.0,"channels":1,"channel_status":"mono","model_version":"1f18b6338ccb72b202aa89c942b3989775dc93af137e201da21846a676b6095e"}
```

model_version — точный SHA256 утверждённого canonical runtime manifest: `1f18b6338ccb72b202aa89c942b3989775dc93af137e201da21846a676b6095e`. Rails сверяет его с `VoiceCoreClient::APPROVED_MANIFEST_SHA256`; другой64hex — terminal error до persistence/metering. Для нового manifest нужны review и обновление кода, нового customer knob нет. channels=1|2; channel_status=mono|mapped|unmapped; language=ru|kk|en|mixed|unknown. Числа времени finite,0≤start≤end≤duration(+0.1s tolerance), duration≤1800s. mapped speaker обязан совпадать с явной картой; mono/unmapped speaker=unknown. Короткие реплики и overlap сохраняются. Unsupported channel count, decoder failure и exception не являются пустым успехом. Валидная тишина — text пусто и dialogue_turns пустые с корректными probe metadata; Rails сохраняет нейтральную summary/no_answer без LLM.

Transport: connect2s, write10s, read120s, overall130s, automatic HTTP retry0, redirects запрещены. Runtime process deadline110s и bounded concurrency — серверная политика. Busy429/unavailable503/deadline504 и network timeout дают ограниченный retry штатным job (3попытки); invalid schema/auth/path/config — terminal. Клиент не переносит raw error body в лог. Лимиты — консервативные границы первого DEV, не обещание измеренной скорости.

Результат сохраняется native transaction с existing billed_at/unique call usage event. source=audio_transcription сохраняет прежнюю семантику учёта; provider=voicecore/model=manifest SHA явно показывают локальный источник. Структурные unknown роли, физический channel и дробные start/end сохраняются в transcript_items и provenance. UI показывает нейтральный канал/говорящего. Новый счётчик не добавлен; существующий legacy response counter и force semantics не меняются.

## Проверки и пределы

Целевые RSpec: `voice_core_client_spec`, `voice_core_recording_spool_spec`, `voice_core_recording_transcription_spec`, `call_recording_transcription_service_spec`, `call_transcript_spec`, job specs. Только synthetic bytes/fake HTTP/isolated DB. Отдельно проверяются runtime mono/stereo/reversed-map/no-speech/short-turn/overlap/codec/resource boundaries.

Эти проверки не доказывают качество ASR. Blind audio/provenance/человеческие эталоны, WER/CER, ошибки ролей и latency требуют отдельной разрешённой проверки pinned inference. Старые обучающие JSON/транскрипты пациентов не копировать в Git. `/clinic/learn`, внешний арбитр, модельные downloads и egress в DEV runtime выключены сервером. PROD и live DEV остаются вне разрешения этого документа.

## Голосовые сообщения

`Telephony::VoiceCoreAudioSpool` — единственный владелец private lifecycle, FD/UID/mode/inode проверок, лимита chunk bytes и guarded cleanup. Тонкие `Telephony::VoiceCoreRecordingSpool` и `Messages::VoiceCoreAttachmentSpool` поставляют только источник. Attachment использует уже привязанный native Blob, account_id сверяется с message.account_id до staging; native Blob.download с блоком передаёт chunks сразу ограниченному writer. Нет URL/download по пользовательскому пути и нет оригинального имени файла в spool.

Canonical MIME/extension берётся из существующего `Messages::AudioTranscriptionFile`; aliases oga→ogg, mpeg/mpga→mp3, mp4→m4a. AAC/WebM также сохраняют штатную поддержку; runtime применяет свой ограниченный decoder. Attachment не получает guessed operator/client map. Product text — plain turn texts, без выдуманных ролей/платной сводки.

Локальная ветка находится после прежних consent/audio-enabled/quota/cache gates, перед fetch_audio_file/cloud normalization. Штатный update_transcription по-прежнему сохраняет текст, обновляет события/язык/поиск и ровно один раз вызывает существующий usage increment на новом непустом результате. В `Attachment.meta.transcription` добавляются только проверенные provider=voicecore/model=approved manifest SHA, остальные meta сохраняются. Исторические cloud-транскрипты без provenance не получают придуманную модель. Native missing-blob retry сохраняется; transient VoiceCore retry ограничен3 попытками. Empty transcript по прежней семантике ничего не сохраняет/не списывает. Нового тарифа/квоты/пользовательской настройки нет.

Дополнительные focused specs: `spec/enterprise/services/messages/{voice_core_attachment_spool,voice_core_attachment_transcription,audio_transcription_service}_spec.rb`, `spec/enterprise/jobs/messages/audio_transcription_job_spec.rb`; вызовы fake/synthetic, без реальных сообщений и моделей.
