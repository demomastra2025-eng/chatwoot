# Перевод платформы на openai/gpt-6-luna: инструкция оператора

Решение владельца (05.10): все ИИ-агенты и подсказки работают на `openai/gpt-6-luna`, голосовой агент для звонков тоже.
У gpt-6-luna мало реальной истории (PROD за 30 дней: 549 событий агента против 9 561 у `openai/gpt-5.6-luna`), поэтому
перевод сделан **данными**, одной проверяемой командой, и откатывается мгновенно. **Качество gpt-6-luna на настоящих
диалогах мы не проверяли**: у разработки нет ключей, ничего не вызывалось по-настоящему. Перед переводом пройдите
ручную проверку (раздел 7), после перевода следите за порогами (раздел 5).

PROD трогает только оператор с доступом. Всё ниже выполняется внутри контейнера Rails (так же, как остальные rake-задачи
релиза). Команды ничего не пишут в PROD, пока вы не передали `CONFIRM=yes`.

## 1. Какая модель у какой функции

Модель функции определяется цепочкой: выбор аккаунта (`accounts.settings -> captain_models`) -> строка
`installation_configs` -> умолчание в `config/llm.yml`. Строки в базе **перекрывают** умолчания кода, поэтому
выкладка кода одна ничего не меняет там, где строка уже есть.

| Функция | Сегодня на PROD | После выкладки кода (данные не тронуты) | После перевода |
|---|---|---|---|
| Агент для клиентов (`assistant`; также FAQ, заметки о контакте, поиск по статьям, разбор сайта при настройке, follow-up, оценка завершения) | `gpt-5.6-luna` из строки `CAPTAIN_DEFAULT_MODEL`; у 22 аккаунтов свой выбор (21 x `gpt-5.6-luna`, 1 x `gpt-6-luna`) | то же самое | `gpt-6-luna` у всех, выбор аккаунтов очищен |
| Текстовые инструменты (`editor`: «Улучшить текст», переписать, резюме, подсказка ответа, follow-up, CSAT) | `gpt-5.6-luna` из `CAPTAIN_DEFAULT_MODEL`, если она подходит функции (по каталогу OpenRouter); у 6 аккаунтов свой выбор (4 разные модели) | то же самое | `gpt-6-luna` у всех |
| Помощник в диалоге (`copilot`) | как у текстовых инструментов; у 8 аккаунтов свой выбор (7 разных моделей) | то же самое | `gpt-6-luna` у всех |
| Подсказки меток (`label_suggestion`) | строки `CAPTAIN_LABEL_SUGGESTION_MODEL` нет, берётся `CAPTAIN_DEFAULT_MODEL` | строка появляется при выкладке (посев из `installation_config.yml`) со значением `gpt-6-luna`; без посева действует умолчание кода, тоже `gpt-6-luna` | `gpt-6-luna` |
| Распознавание картинок и документов (`image_recognition`) | строки `CAPTAIN_IMAGE_RECOGNITION_MODEL` нет; в событиях за 30 дней `gpt-5.6-luna` 384, `gpt-5-mini` 84, `gpt-6-luna` 6; у 2 аккаунтов свой выбор | то же, что подсказки меток: `gpt-6-luna` | `gpt-6-luna` |
| Резюме диалога | это функция `editor` | как у `editor` | `gpt-6-luna` |
| Голосовой агент (`ai.model` провайдеров ElevenLabs / Cartesia / Fish + OpenRouter) | сохранённое в настройках агента или умолчание кода `openai/gpt-5.4-mini` (1 внутренняя запись на PROD имеет `voice_settings`) | умолчание кода `openai/gpt-6-luna`; сохранённые значения не меняются | сохранённые модели OpenRouter-провайдеров заменены на `gpt-6-luna` |

**Не меняется (и почему)**: проверка безопасности (`CAPTAIN_MODERATION_MODEL`), эмбеддинги (`CAPTAIN_EMBEDDING_MODEL`,
смена модели требует переиндексации базы знаний) и расшифровка голоса (`CAPTAIN_AUDIO_TRANSCRIPTION_MODEL`) это не
чат-модели; им нужны свои возможности (модерация, векторы, аудиовход), у `gpt-6-luna` их нет. Реранкинг знаний вообще
без модели. Строка `CAPTAIN_OPEN_AI_MODEL` (на PROD `gpt-5-mini`) используется только если `CAPTAIN_DEFAULT_MODEL` пуста
и подключён прямой ключ OpenAI; пока `CAPTAIN_DEFAULT_MODEL` заполнена, она ни на что не влияет, команды её не трогают.
Откуда у распознавания 84 события `gpt-5-mini`, по текущему коду определить нельзя (выбор аккаунта у 2 аккаунтов
другой); посмотрите, когда они были (запрос 5.5): если это старые дни, вопрос закрыт.

### Что именно делает перевод

Одна транзакция, строки и аккаунты заблокированы, при устаревшем снимке перевод отказывается:

1. Строки `installation_configs`: `CAPTAIN_DEFAULT_MODEL`, `CAPTAIN_IMAGE_RECOGNITION_MODEL`,
   `CAPTAIN_LABEL_SUGGESTION_MODEL` получают `openai/gpt-6-luna` (создаются, если их нет). `CAPTAIN_AI_AGENT_DEFAULT_MODEL`
   переводится только если она есть (на PROD её нет, и она не нужна: общая строка уже покрывает агента, второй переключатель
   только путал бы).
2. Выбор модели на уровне аккаунта для `assistant`, `editor`, `copilot`, `image_recognition`, `label_suggestion`
   **очищается**: аккаунт после этого следует умолчанию платформы. Так модель решает платформа, и одной правкой умолчания
   (раздел 6А) можно вернуть всех. Выбор вне короткого списка (deepseek, claude-haiku, gpt-5.1, gpt-5-mini и т. п.)
   не ломает аккаунт: он тоже очищается и аккаунт получает умолчание. Остальные настройки аккаунта
   (расшифровка голоса, эмбеддинги и т. д.) не трогаются.
3. Сохранённые модели голосовых агентов: у записей с провайдером `elevenlabs`, `cartesia` или `fish` ключ `model`
   (в `captain_assistants.config -> voice_settings` и в `telephony_routing_policies.ai_voice_settings`) становится
   `openai/gpt-6-luna`. Провайдеры `gemini-live`, `openai-live`, `openai-realtime` не меняются (раздел 8).
4. До записи проверяется: модель есть в каталоге и подходит каждой функции; короткий список моделей (если задан) содержит и
   `gpt-6-luna`, и `gpt-5.6-luna` (иначе быстрый откат из Super Admin не пройдёт проверку); у каждого аккаунта есть ключ OpenRouter и
   не отключены запасные модели и ZDR-режим (иначе у `gpt-6-luna` нет запасного маршрута на `gpt-5.6-luna`). После записи,
   до фиксации транзакции, проверяется, что для каждой функции на уровне установки и для агента каждого аккаунта действует именно
   `gpt-6-luna`; иначе всё откатывается.

## 2. Что должно быть готово до перевода

- Релиз с этим кодом выложен на PROD (миграций нет).
- Super Admin -> «ИИ-агенты»: поле «Модель ИИ по умолчанию» (`CAPTAIN_DEFAULT_MODEL`) показывает `openai/gpt-5.6-luna`;
  в «Короткий список моделей» есть `openai/gpt-6-luna` и `openai/gpt-5.6-luna`.
- Запросы раздела 5 для базового периода выполнены, цифры сохранены (30 дней `gpt-5.6-luna`).
- Выбрано время с живым оператором рядом на ближайшие 2 часа.
- Для голоса: см. раздел 8 (что нужно вне этого репозитория).

## 3. Предпросмотр и снимок (ничего не меняет)

```
bundle exec rake llm:luna_cutover:preview SNAPSHOT=/путь/на/постоянном/томе/luna6-snapshot.json
```

- Путь должен быть на томе, который переживёт перезапуск контейнера (не `/tmp`), и нужен потом для отката. Файл создаётся
  с правами 0600, существующий файл не перезаписывается, после записи файл читается обратно и сравнивается.
- В снимке только номера аккаунтов и старые идентификаторы моделей, персональных данных нет.
- Вывод показывает: строки (было -> станет), по каждой функции и старой модели количество и номера аккаунтов, пометку
  `[outside the allowlist]` у выбора вне короткого списка, сохранённые модели голоса.
- Прочитайте вывод. Сверьте с ожиданием: 22 + 8 + 6 + 2 выбора аккаунтов, одна запись голоса.
- Если команда отказывается, причина написана в ошибке (устаревшее состояние, нет ключа OpenRouter, у аккаунта отключены
  запасные модели, `gpt-6-luna` не подходит функции). Исправьте и повторите; снимок при отказе не создаётся.

## 4. Применение

```
bundle exec rake llm:luna_cutover:apply SNAPSHOT=/путь/luna6-snapshot.json            # показывает план, ничего не меняет
bundle exec rake llm:luna_cutover:apply SNAPSHOT=/путь/luna6-snapshot.json CONFIRM=yes
```

- Без `CONFIRM=yes` это просмотр. С `CONFIRM=yes` всё делается одной транзакцией. Если после снимка что-то изменилось
  (другая модель в строке, новый выбор у аккаунта, исчезнувший аккаунт), перевод отказывается и ничего не меняет:
  сделайте новый снимок.
- Повторный запуск с тем же снимком безопасен: уже сделанное пропускается, выводится `0 accounts changed`.
- Аккаунт, созданный после снимка без своего выбора, ничего не требует: он сразу следует умолчанию.
- Проверка после применения (rails runner в контейнере):

```
bundle exec rails runner 'puts %w[assistant editor copilot label_suggestion image_recognition].map { |f| "#{f}=#{Llm::Config.model_for(feature: f, fallback: nil)}" }.join(" ")'
```

Все пять должны быть `openai/gpt-6-luna`.

## 5. Мониторинг первых 48 часов

Все запросы по таблице `llm_events` (события `llm.chat.complete` несут модель, длительность и стоимость; флаги
`error`, `schema_invalid`, `tool_failure` и счётчики `retry_count`, `schema_invalid_count` стоят на событиях любых типов).
Подставьте время перевода в `:cutover_at`. Выполняется в psql или `rails dbconsole`.

**5.1 База: 30 дней до перевода, `gpt-5.6-luna`** (выполнить ДО перевода, сохранить результат):

```sql
SELECT feature, model,
       count(*) FILTER (WHERE event_name = 'llm.chat.complete')                          AS chat_events,
       round(100.0 * count(*) FILTER (WHERE error) / greatest(count(*), 1), 2)          AS error_pct,
       coalesce(sum(schema_invalid_count), 0)                                           AS schema_invalid_count,
       count(*) FILTER (WHERE tool_failure)                                             AS tool_failure,
       coalesce(sum(retry_count), 0)                                                    AS retry_count,
       round((percentile_cont(0.5)  WITHIN GROUP (ORDER BY duration_ms)
              FILTER (WHERE event_name = 'llm.chat.complete'))::numeric)                AS p50_ms,
       round((percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms)
              FILTER (WHERE event_name = 'llm.chat.complete'))::numeric)                AS p95_ms,
       round(coalesce(sum(estimated_cost) FILTER (WHERE event_name = 'llm.chat.complete'), 0)::numeric, 4) AS estimated_cost_usd
FROM llm_events
WHERE created_at >= now() - interval '30 days' AND created_at < :cutover_at
  AND model IN ('openai/gpt-5.6-luna', 'gpt-5.6-luna')
GROUP BY feature, model ORDER BY feature, model;
```

**5.2 После перевода, то же по функциям и моделям** (в первые часы каждый час, потом два раза в сутки):

```sql
SELECT feature, model,
       count(*) FILTER (WHERE event_name = 'llm.chat.complete')                          AS chat_events,
       round(100.0 * count(*) FILTER (WHERE error) / greatest(count(*), 1), 2)          AS error_pct,
       coalesce(sum(schema_invalid_count), 0)                                           AS schema_invalid_count,
       count(*) FILTER (WHERE tool_failure)                                             AS tool_failure,
       coalesce(sum(retry_count), 0)                                                    AS retry_count,
       round((percentile_cont(0.5)  WITHIN GROUP (ORDER BY duration_ms)
              FILTER (WHERE event_name = 'llm.chat.complete'))::numeric)                AS p50_ms,
       round((percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms)
              FILTER (WHERE event_name = 'llm.chat.complete'))::numeric)                AS p95_ms,
       round(coalesce(sum(estimated_cost) FILTER (WHERE event_name = 'llm.chat.complete'), 0)::numeric, 4) AS estimated_cost_usd,
       round((coalesce(sum(estimated_cost) FILTER (WHERE event_name = 'llm.chat.complete'), 0)
              / greatest(count(*) FILTER (WHERE event_name = 'llm.chat.complete'), 1))::numeric, 6) AS cost_per_chat_event
FROM llm_events
WHERE created_at >= :cutover_at
GROUP BY feature, model ORDER BY feature, model;
```

**5.3 Запасная модель сработала? (запрошено `gpt-6-luna`, ответила другая)**

```sql
SELECT feature, requested_model, actual_model, count(*) AS events
FROM llm_usage_events
WHERE occurred_at >= :cutover_at
GROUP BY feature, requested_model, actual_model ORDER BY events DESC;
```

**5.4 По часам за последние 2 часа** (быстрый взгляд на всплеск ошибок):

```sql
SELECT date_trunc('hour', created_at) AS hour, feature,
       count(*) FILTER (WHERE event_name = 'llm.chat.complete') AS chat_events,
       count(*) FILTER (WHERE error) AS errors, count(*) FILTER (WHERE tool_failure) AS tool_failures,
       coalesce(sum(schema_invalid_count), 0) AS schema_invalid
FROM llm_events
WHERE created_at >= now() - interval '2 hours' AND model = 'openai/gpt-6-luna'
GROUP BY 1, 2 ORDER BY 1, 2;
```

**5.5 Откуда события `gpt-5-mini` у распознавания** (разовый, до перевода):

```sql
SELECT date_trunc('day', created_at) AS day, count(*) FROM llm_events
WHERE feature = 'image_recognition' AND model = 'gpt-5-mini' AND created_at >= now() - interval '30 days'
GROUP BY 1 ORDER BY 1;
```

### Пороги: когда откатывать

Сравнивайте `gpt-6-luna` с базой из 5.1 по той же функции, при выборке не менее 200 событий `llm.chat.complete` за окно
(для функций с малым трафиком берите сутки). Откат нужен, если выполнено любое:

| Показатель | Порог отката |
|---|---|
| Доля ошибок (`error_pct`) | выше базы более чем на 2 процентных пункта за сутки, или выше 10% за любой час |
| `schema_invalid_count` на 100 событий | больше чем вдвое выше базы и не меньше 3 на 100 |
| `tool_failure` (доля событий) | больше чем вдвое выше базы и не меньше 1% |
| `retry_count` на событие | больше чем вдвое выше базы |
| `duration_ms` p95 | больше 1,5 x базы, либо выше 15 секунд для агента |
| `duration_ms` p50 | больше 1,5 x базы |
| `estimated_cost` на событие | больше 2 x базы (у `gpt-6-luna` цена ниже, рост значит затянувшиеся ответы или повторы) |
| Запасная модель (5.3) | больше 10% событий агента ответила не `gpt-6-luna` за любой час: у основной модели нет стабильных поставщиков |
| События `gpt-6-luna` отсутствуют при живом трафике функции | маршрут не работает |
| Жалобы | две жалобы владельца или клиентов на качество ответов агента за сутки |

Для голоса `llm_events` не ведётся: запросы к модели идут напрямую из голосового runtime в OpenRouter. Следите там за
активностью по модели `openai/gpt-6-luna` в панели OpenRouter, за журналом контейнера голосового runtime и по таблице
звонков за долей звонков, где агент молчал или звонок оборвался в первые секунды. Симптом остановки голоса: агент молчит,
в журнале OpenRouter «No endpoints found» (раздел 8).

## 6. Откат

### А. Мгновенный, из Super Admin (без команд и перезапуска)

Super Admin -> «ИИ-агенты»:

1. «Модель ИИ по умолчанию» = `openai/gpt-5.6-luna` (она остаётся в коротком списке) возвращает агента, текстовые
   инструменты и помощника у всех аккаунтов (после перевода их выбор очищен, все следуют умолчанию).
2. «Модель распознавания изображений» и «Модель подсказок меток» = `openai/gpt-5.6-luna`.
3. Голос (если переведён): вернуть модель в настройках голосового агента или выполнить Б.

Действует на следующий запрос (значения читаются из базы). Старые выборы аккаунтов этим способом не возвращаются,
для этого есть Б.

### Б. Полный откат из снимка (возвращает ровно старые значения)

```
bundle exec rake llm:luna_cutover:rollback SNAPSHOT=/путь/luna6-snapshot.json            # показ
bundle exec rake llm:luna_cutover:rollback SNAPSHOT=/путь/luna6-snapshot.json CONFIRM=yes
```

Возвращает строки (созданные при переводе строки удаляются), выбор моделей каждого аккаунта и модели голоса ровно как
в снимке; в конце сверяет действующие модели с теми, что были при снимке. Откат отказывается (ничего не меняя), если
после перевода кто-то выбрал другую модель у аккаунта из снимка или поменял строку: тогда верните модель у этого
аккаунта, повторите, или используйте А. Если откат уже сделан через А, команда Б всё равно проходит (строки в старом
состоянии принимаются) и восстанавливает выборы аккаунтов.

## 7. Ручная проверка владельцем на DEV (качество gpt-6-luna НЕ проверено нами)

Нужен ключ OpenRouter на DEV. Super Admin -> «ИИ-агенты»: «Модель ИИ по умолчанию» = `openai/gpt-6-luna`,
«Модель распознавания изображений» и «Модель подсказок меток» = `openai/gpt-6-luna`. В тестовом аккаунте очистите свой
выбор модели («Настройки -> ИИ»), агента оставьте с моделью по умолчанию.

1. Ответ агента: напишите тестовому агенту 5-6 реальных вопросов (цены, запись, жалоба, просьба позвать человека). Ждём:
   ответ по базе знаний, нет JSON и служебных слов, перевод на человека срабатывает, ответ на русском (и казахском).
2. Инструменты агента: вопрос, требующий вызова инструмента (запись, статус заявки): инструмент вызывается, результат в ответе.
3. Подсказки: откройте диалог, где подходят метки; подсказка меток и «Улучшить текст» / переписать / резюме / подсказка ответа работают.
4. Помощник в диалоге (copilot): задайте вопрос по диалогу.
5. Распознавание: пришлите фото документа и фото товара; текст с документа читается, описание картинки верное.
6. Голос (браузерный предпросмотр голосового агента, провайдер ElevenLabs/Cartesia/Fish + OpenRouter с моделью GPT-6 Luna):
   агент отвечает сразу, не молчит, инструменты работают, задержка ответа приемлема на слух.
7. Где смотреть: `llm_events` (запрос 5.2, поле `model` у событий тестового аккаунта должно быть `openai/gpt-6-luna`),
   ошибки в Super Admin -> «ИИ-агенты» -> диагностика OpenRouter.

Если хоть один пункт плох: не переводить PROD, оставить `CAPTAIN_DEFAULT_MODEL = openai/gpt-5.6-luna`.

## 8. Голосовой агент: как модель доходит до runtime и что нужно вне этого репозитория

Путь модели (из кода):

1. Настройки хранятся в двух местах: `telephony_routing_policies.ai_voice_settings` и `captain_assistants.config -> voice_settings`
   (агент важнее политики). `Telephony::AiVoice::VoiceSettingsDefaults.normalize` дополняет их умолчаниями провайдера.
2. `Telephony::AiVoice::ContextBuilder` собирает ответ `ai` (все настройки, включая `provider`, `model`, `delegation_model`);
   отдаёт его `GET/POST /internal/voice/ai/context`. Голосовой runtime (`services/onelink-ai-voice-pipecat`, на PROD отдельный
   контейнер `crafty-prod-onelink_ai_voice-1`) при начале звонка сам запрашивает этот контекст и берёт `ai.model` как есть.
3. Для провайдеров `elevenlabs`, `cartesia`, `fish` runtime вызывает OpenRouter с `model = ai.model`; для `openai-live`
   `ai.model` это модель GPT Live, а `ai.delegation_model` модель OpenAI Responses для инструментов; у `openai-realtime`
   и `gemini-live` `ai.model` это модель речь-в-речь, и подставить туда `gpt-6-luna` нельзя.

Что сделано в коде: умолчания `model` провайдеров ElevenLabs, Cartesia, Fish и список моделей в форме настройки агента теперь
`openai/gpt-6-luna` (список сохраняет и `gpt-5.6-luna`, и `gpt-5.4-mini`); runtime трактует семейство `openai/gpt-6*` как `openai/gpt-5*`
(без рассуждений и без `temperature` в запросе голосового хода).

**Что нельзя решить кодом и нужно владельцу / оператору**

- Образ голосового runtime нужно пересобрать и перевыложить: изменение `app/pipeline/factory.py` без этого не вступит в
  силу. Без него `openai/gpt-6-luna` уйдёт в OpenRouter с `temperature` и без отключения рассуждений: из-за
  `require_parameters` запрос может не найти подходящих поставщиков, и агент замолчит (такой случай уже описан в коде для
  `parallel_tool_calls`). Это не проверено вызовом: проверить на DEV перед PROD (раздел 7, п. 6).
- Провайдер по умолчанию голосового агента `gemini-live` (`gemini-3.1-flash-live-preview`): это речь-в-речь модель Google,
  Luna туда подставить нельзя. «Голос тоже Luna» верно только для агентов с провайдером ElevenLabs/Cartesia/Fish + OpenRouter.
  Для них нужны ключи `ELEVENLABS_API_KEY` / `CARTESIA_API_KEY` / Fish и `OPENROUTER_API_KEY` в окружении runtime.
  Если владелец хочет Luna для всех голосовых агентов, нужно сменить провайдер по умолчанию (другое качество голоса и задержка) - это отдельное решение.
- `delegation_model` (только `openai-live`) вызывается напрямую в OpenAI (`OPENAI_API_KEY`), а не через OpenRouter, поэтому
  он оставлен `gpt-5.4-mini`: идентификатор `openai/gpt-6-luna` там не сработает, а как называется Luna в API OpenAI напрямую, из кода не определить.
- Строка про переменные окружения: изменение переменных runtime для самой модели не нужно (модель приходит из контекста);
  нужны только ключи провайдеров выше.

Что код делает про время и запасные варианты (голос чувствителен к задержке):

- Запрос к OpenRouter идёт с `sort: latency`, `allow_fallbacks: true` (смена поставщика той же модели), `require_parameters: true`,
  `preferred_max_latency: p90 1 с, p99 2,5 с`. **Запасной модели нет**: список `models` не передаётся, при остановке `gpt-6-luna`
  у всех поставщиков ход не получит ответа.
- Явного таймаута запроса к LLM в runtime нет (значение по умолчанию библиотеки Pipecat). Защитные механизмы: если модель
  молчит дольше `ordinary_answer_continuation_ms` (по умолчанию 2500 мс), runtime прерывает ход и один раз повторяет его
  инструкцией «ответь коротко»; после инструмента `post_tool_continuation_ms` (2000 мс) принудительно продолжает; есть
  фразы-заполнители на время работы инструментов и тихие подсказки при молчании собеседника.
- Мгновенный откат голоса: вернуть в настройках агента модель `openai/gpt-5.6-luna` (она есть в списке формы) или
  `rake llm:luna_cutover:rollback`.

## 9. Открытые вопросы

- Нужно ли принудительно ограничивать выбор моделей `editor` и `copilot` коротким списком на сервере: сейчас список
  проверяется при смене модели агента (`assistant`), а у `editor` и `copilot` аккаунт может выбрать любую модель из
  каталога. После перевода выбор очищен, но его можно задать снова.
- `LlmConstants::DEFAULT_MODEL` (`gpt-5.4`, прямой OpenAI) остаётся запасным при отсутствии OpenRouter: не затрагивался.
