# OneLink: разработка → DEV → PROD

## Главное правило

Ежедневная ветка одна: **`onelink-dev`**.

```text
изменение → проверки → commit → push → проверки GitHub → DEV
                                                       ↓
                                              ручная кнопка PROD
```

- Зелёный push автоматически и атомарно обновляет `dev.one-link.kz`.
- Красный push не меняет DEV: там остаётся предыдущая рабочая версия.
- PROD получает тот же проверенный Git SHA и OCI image digest без повторной сборки.
- Грязный или незакоммиченный каталог никогда не является релизом.

## Обычная работа

```bash
cd /root/crafty/onelink/chatwoot
git switch onelink-dev
git pull --ff-only origin onelink-dev

# изменить код и выполнить подходящие локальные проверки

git add <нужные-файлы>
git commit -m "тип: короткое описание"
git push origin onelink-dev
```

После push больше ничего делать не нужно: GitHub проверяет изменение и при успехе
выкатывает его в DEV. После ручной проверки DEV разработчик запускает workflow
`OneLink Promote Production`, указывает полный SHA и подтверждает GitHub Environment
`production`.

## Когда нужна отдельная ветка

Только для большого, рискованного или параллельного изменения:

```bash
git switch onelink-dev
git pull --ff-only origin onelink-dev
git switch -c feature/<короткое-название>

# изменить, проверить, commit, push и открыть PR в onelink-dev
```

После merge ветка удаляется. Постоянные персональные, release- и develop-ветки не нужны.
`onelink-main` используется только как техническая база синхронизации с upstream Chatwoot.

## Что автоматизировано

- `.github/workflows/onelink_pr_gate.yml` — проверки необязательной feature-ветки/PR.
- `.github/workflows/onelink_release.yml` — проверки каждого push в `onelink-dev`,
  быстрый DEV deploy и сборка подписанного production image.
- `.github/workflows/onelink_nightly.yml` — полный Ruby/Vue/security suite: по расписанию,
  вручную или для точного SHA по запросу production promotion. Ручной запуск с feature-ветки
  проверяет exact HEAD, но не публикует `nightly` proof, пригодный для promotion.
- `.github/workflows/onelink_promote_production.yml` — ручное продвижение проверенного
  DEV SHA в PROD.
- Каждый job с RSpec (`release-gate`, PR `backend`, nightly `backend`) до запуска спеков
  ставит системную `libopus0` и проверяет, что `libopus.so.0` загружается: спеки WhatsApp
  Opus decoder вызывают настоящий libopus через Fiddle и без него падают, а не пропускаются.
  Контракт проверяет `script/onelink/test_workflow_native_deps.py`.

Проверки выбираются по diff от последнего успешно развернутого DEV SHA: Ruby, Vue,
migration и Docker-проверки запускаются только когда соответствующий слой изменился.
Если успешного DEV proof ещё нет, workflow принудительно выполняет bootstrap deploy;
после красного runtime-run следующий push повторно включает неприменённые изменения.
Автоматический flow принимает только безопасные
expand-миграции; destructive contract-cleanup выполняется отдельной операторской задачей. Изменения
встроенных sidecar-сервисов пока блокируются fail-closed, чтобы не создать смешанный
runtime из разных SHA.

Миграции для PROD выполняются, пока предыдущий релиз ещё обслуживает запросы, поэтому
«expand» означает не только аддитивность, но и короткие блокировки.
`change_plan.py --validate-migrations` отклоняет `add_index` без `algorithm: :concurrently`,
`add_foreign_key` и `add_check_constraint` без `validate: false`, `add_reference` с внешним
ключом или обычным индексом, `t.references ... foreign_key: true` в новых таблицах и
`UPDATE`/`update_all` без батчей. Безопасная форма: колонки под `SET LOCAL lock_timeout`
с повторами, новые таблицы без ключей, ключи и проверки `NOT VALID`, отдельная миграция
`VALIDATE`, индексы `CONCURRENTLY`, перенос данных пачками по ~5000 строк с условием
«ещё не заполнено» (образец: `20260928110000`–`110200` и `20261004120000`–`193200`).
Откат таких миграций: `MIGRATION_ROLLBACK_20261004.md`.

## Поведение DEV

DEV deploy принимает только текущий полный SHA ветки `origin/onelink-dev`:

```text
deploy <40-character-sha>
```

Сервер:

1. получает SHA из Git;
2. сравнивает его с фактическим live SHA и обязательным unified contract SHA;
3. блокирует deletion, explicit Revert и возврат старого содержимого защищённых contract-файлов;
4. готовит новый release-каталог и зависимости;
5. проверяет tracked tree и запускает contract suite при изменении критичных файлов;
6. выполняет `db:chatwoot_prepare` без schema/model rewrites и повторно проверяет tracked tree;
7. атомарно переключает `/srv/onelink-dev/current`;
8. проверяет Rails, workers, Vite, finalizers и итоговый tracked tree;
9. автоматически возвращает предыдущий release при ошибке.

При обновлении Captain jobs на DEV старые Sidekiq workers не должны получать задания
нового web: `deploy_dev_release.sh` останавливает worker-группу **до** переключения
`current`, затем запускает workers только из нового release (или восстанавливает
старые при неуспешном cutover). На время переключения обработка DEV jobs приостанавливается;
`onelink-ai-voice-dev.service` заранее не останавливается.

**Условие перед merge в `onelink-dev`:** forced deploy использует установленную копию
`/usr/local/sbin/onelink-dev-deploy-release`, а не файл из Git release. В согласованное
DEV-окно оператор должен сохранить предыдущие копии endpoint, установить проверенные
`script/onelink/dev_forced_command.sh` и `script/onelink/deploy_dev_release.sh` из reviewed
commit и сверить SHA-256 deploy-script с установленным. CI перед `deploy` вызывает
ограниченную read-only команду `deploy-script-sha256` и сравнивает её результат с файлом
точного release SHA; старый forced endpoint эту команду отклонит и выпуск остановится.
До установки обеих копий merge/автоматический DEV deploy запрещён; успешный PR gate
сам по себе не доказывает, что сервер использует новый порядок.

Опциональные DEV fast mode и готовые assets описаны в `ONELINK_DEV_RUNTIME.md`.
В режиме готовых assets CI сначала сверяет `asset-tools-sha256` с reviewed
`prepare_dev_assets.sh` и `dev_built_assets.py`, затем отдельная ограниченная команда
`prepare-assets <full-sha>` выполняет сборку через существующий `/root/work/e-heavy.sh`.
Deploy потребляет и проверяет артефакт точного SHA без сборки внутри endpoint.
При первой активации сначала выкатывается совместимый код с выключенными флагами;
затем оператор готовит assets и переключает внешний runtime. Предыдущий release
должен поддерживать текущий режим и иметь проверенные assets для безопасного отката.

После deploy workflow вызывает отдельную разрешённую forced-команду:

```text
verify <40-character-sha>
```

Она запускает фиксированный exact-SHA RSpec suite с deterministic seed, RuboCop,
Ruby syntax и tracked-tree verification непосредственно из deployed release. Полный
stdout и отдельный SHA-256 загружаются неизменяемым GitHub Actions artifact с именем,
содержащим SHA, run ID и run attempt. Protected paths, baseline hashes и точный список
contract specs находятся в `medelement_contract_manifest.json`.

## Поведение PROD

### Восстановление синхронизации MedElement

`Integrations::Medelement::StaleSyncRunRecoveryJob` проверяет активные прогоны каждые
пять минут. Исполнитель сохраняет идентификаторы ActiveJob/Sidekiq и свой heartbeat
отдельно от времени обновления записи; поступление плановых фаз этот heartbeat не
продлевает. Прогон с известным исполнителем может быть восстановлен после десяти
минут тишины, когда процесс исполнителя отсутствует и для прогона нет задания в
очередях, отложенных заданиях, повторных попытках и работающих исполнителях. Для
старых прогонов без полной идентичности сохраняется порог 45 минут.

Recovery получает тот же mutex аккаунта, который использует синхронизация, затем
под блокировкой хука и строки повторно проверяет heartbeat, задания и владение
mutex. Чужой mutex не удаляется: оставшаяся 30-минутная аренда после остановки
процесса может задержать восстановление. Продолжение содержит незавершённые и
ожидающие фазы; завершённые фазы повторяются только при новом запросе. Ошибка чтения Sidekiq оставляет
прогон активным до следующей проверки.

Для диагностики пустого теневого расписания используется
`script/onelink/medelement_schedule_diagnostics.sql`: это транзакция только для
чтения, выводящая идентификаторы, состояния и счётчики без обращений к MedElement.
`recent_utc_coded_count` считает свежие UTC-метки; ненулевой
`unclassified_last_seen_count` требует отдельной проверки формата меток и не
доказывает отсутствие свежих специалистов.

### Календарь и доступность MedElement

Массовое чтение календаря использует только сохранённые подтверждённые дни
MedElement (`allow_live: false`), включая запросы прошедших дат и дат вне окна
фоновой синхронизации. Оно не делает синхронных запросов расписания или приёмов
провайдера. Свежие подтверждённые интервалы отображаются; неизвестные и устаревшие
интервалы не становятся свободными слотами. Существующие записи отображаются
независимо от наличия подтверждённых часов.

Отдельный поиск доступности и проверка при записи сохраняют подтверждение у
провайдера по запросу вне фонового кеша; календарь не расширяет права на запись.

В форме записи из диалога кнопки свободного времени показывают начало интервала
и доступны только для полной выбранной длительности. Если выбранная дата
подтверждена, но свободных интервалов нет, интерфейс делает один запрос
`GET /api/v1/accounts/:account_id/scheduling/availability` с `date_from`,
`date_to` (следующие 31 день), теми же `resource_id`, `service_id`,
`cabinet_code`, `duration_min` и `confirmed_only=true`. Этот режим использует
`allow_live: false`, сохраняет обычный формат `windows/state/checked_at/source`
и не вызывает MedElement. Частично неизвестный диапазон сохраняет
`schedule_not_confirmed`, даже если в нём найдены отдельные подтверждённые
интервалы. Интерфейс может показать ближайшую подтверждённую дату из этих
интервалов; отсутствие результата не доказывает, что неизвестные даты заняты.
Поиск ограничен одним диапазоном и 8 секундами, отменяется при изменении формы
или контекста. Обычное чтение отдельной даты и проверка перед записью сохраняют
существующую проверку провайдера. На найденную дату переходит только список
доступности; ручные начало, конец и длительность записи сохраняются. Время
записи меняется после явного выбора слота, автоматический поиск его не выбирает.

В «Новом пациенте» из диалога ИИН проверяется существующим checksum-валидатором
и календарным декодером даты/пола. Автозаполнение меняет только новый черновик,
не карточку контакта переписки или существующего пациента. Имя, фамилия и
отчество остаются отдельными полями. Неверный ИИН не создаёт пациента и не
подставляет предположительные дату рождения или пол.

PROD deploy принимает только подписанный GHCR digest, содержащий запрошенный SHA:

```text
promote <40-character-sha> ghcr.io/demomastra2025-eng/chatwoot@sha256:<digest>
```

Workflow допускает promotion только если:

- этот SHA успешно работал в DEV;
- все миграции между SHA, работающим в PROD (последний успешный deployment окружения
  `production`), и запрошенным SHA прошли `change_plan.py --validate-migrations`
  (job `migration-guard`);
- authoritative digest получен напрямую из успешного `docker/build-push-action` и
  сохранён в DEV deployment proof без повторного хеширования manifest;
- image содержит тот же SHA;
- signature, provenance и SBOM валидны;
- full verification точного SHA зелёный: готовый nightly proof переиспользуется, а при
  его отсутствии promotion автоматически запускает тот же полный suite;
- человек подтвердил GitHub Environment `production`.

Перед сборкой нового production image release workflow дополнительно ищет до двух
последних успешных production deployment с разными Git SHA. Для каждого он проверяет
immutable image digest, SHA внутри image, Cosign signature и GitHub attestation, затем
берёт только файлы, на которые ссылаются `.vite/manifest.json` и, если он есть,
`.vite/manifest-assets.json`. HTML, manifests и service workers не сохраняются.
Хранилище ограничено 4096 файлами и 256 MiB суммарно (32 MiB на файл); при сборке
предыдущие файлы добавляются после свежей компиляции только при отсутствии коллизии
либо при совпадении байтов. Ошибка доказательства, небезопасный путь или разные байты
по одному пути останавливают сборку. Если успешных production deployment ещё нет,
сборка выполняется без предыдущих assets.

Rollout идёт workers → второй web → первый web. При ошибке сервисы возвращаются на
предыдущий image, а `.env.production` обновляется только после полной проверки.
Promotion script намеренно использует orchestration boundary `/root/crafty`:
`.env.production` и `docker-compose.production.yml`, а не repo-local
`docker-compose.production.yaml`.

PROD endpoint доступен GitHub-hosted runner через отдельный SSH listener, который
допускает только пользователя `onelink-prod-deploy`. Environment `production` хранит
`ONELINK_PROD_DEPLOY_HOST`, `ONELINK_PROD_DEPLOY_PORT`,
`ONELINK_PROD_DEPLOY_USER`, `ONELINK_PROD_DEPLOY_SSH_KEY` и
`ONELINK_PROD_KNOWN_HOSTS`; основной административный SSH открывать не требуется.

## Одноразовая настройка оператора

Сделать `onelink-dev` default branch репозитория, чтобы scheduled nightly запускался из
той же единственной рабочей ветки. Создать GitHub Environments `development`, `nightly`
и `production`; для `production` включить
обязательное ручное подтверждение. Добавить environment secrets:

- DEV: `ONELINK_DEV_DEPLOY_HOST`, `ONELINK_DEV_DEPLOY_USER`,
  `ONELINK_DEV_DEPLOY_SSH_KEY`, `ONELINK_DEV_KNOWN_HOSTS`;
- PROD: `ONELINK_PROD_DEPLOY_HOST`, `ONELINK_PROD_DEPLOY_PORT`,
  `ONELINK_PROD_DEPLOY_USER`, `ONELINK_PROD_DEPLOY_SSH_KEY`,
  `ONELINK_PROD_KNOWN_HOSTS`.

На каждом сервере используется отдельный непривилегированный deploy user и отдельный
Ed25519 key с forced command. Root SSH key в GitHub не хранится. Установка endpoint:

```bash
sudo ./install_deploy_endpoint.sh dev /secure/path/onelink-dev-ci.pub
sudo ./install_deploy_endpoint.sh production /secure/path/onelink-prod-ci.pub
```

Установка endpoint, настройка GitHub, GHCR login и первый PROD promotion являются
отдельными инфраструктурными изменениями и выполняются только в согласованное окно.

## Статусы сообщений WhatsApp

В объединённом диалоге статус сообщения определяется каналом самого сообщения:
WhatsApp, звонки и другие каналы могут находиться в одной ленте. Карточка звонка
показывает собственный результат звонка, а не индикатор отправки сообщения.

Retry допустим только пока у сообщения нет provider ID (`source_id`). Если ID уже
выдан, outbound job не отправляет сообщение повторно. Поэтому retry сохраняет
статус и ошибку и возвращает отказ; для повторной отправки нужно новое сообщение.

Исторические расхождения исправляются отдельным проверенным repair-скриптом
только после штатного выпуска защиты во все web/worker контейнеры:

1. Проверить SHA работающего release и наличие защиты retry.
2. Выполнить preview по всем WhatsApp Cloud аккаунтам. Кандидат: публичное
   исходящее/template сообщение, локальный `sent`, непустой provider ID и
   сохранённое подтверждение Meta `whatsapp_delivery.status=failed`.
3. Передать свежий ожидаемый размер выборки и новый абсолютный путь журнала
   на постоянном диске. При изменении числа кандидатов операция прекращается.
4. Под блокировкой повторно проверить каждую запись, сохранить прежний статус
   и ошибку в журнале и через штатный updater установить `failed`. Подтверждённую
   позднее доставку пропустить. Provider ID и метаданные сохраняются, повторной
   отправки нет. Если исходная ошибка стёрта, указать, что её детали недоступны.
5. Проверить остаток кандидатов и отображение восстановленного статуса.

Отсутствие `delivered` само по себе не является подтверждением ошибки и не даёт
основания менять статус на `failed`.

## Перевод ИИ на openai/gpt-6-luna

Модели ИИ-агентов и подсказок на PROD задаются данными, а не кодом, поэтому выкладка кода сама модель не меняет.
Перевод выполняется отдельной проверяемой командой с предпросмотром, снимком (права 0600) и откатом; пошаговая
инструкция, пороги мониторинга и быстрый откат из Super Admin:
[LUNA_CUTOVER_RUNBOOK.md](LUNA_CUTOVER_RUNBOOK.md).
