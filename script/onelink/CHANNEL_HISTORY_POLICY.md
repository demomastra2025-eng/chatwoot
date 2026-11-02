# История каналов: политика и поддержка

Канон владельца: вся история сообщений и контактов импортируется автоматически;
медиа старше 90 дней загружаются по запросу. Группы и исключённые чаты остаются
отдельными политиками канала. Новых клиентских переключателей нет.

## WhatsApp Web

- `import_contacts`, `import_messages`, `history_lookback_days` выведены из API.
  Любой из этих ключей при create/update даёт **422** с
  `error: platform_managed_history` и списком `fields`, до изменения данных.
  Старые столбцы оставлены для отката; runtime их не читает и API не возвращает.
- Полный импорт не ограничивает возраст текста. До любой загрузки файла
  применяется единая граница 90 дней. Старые подпись, тип и заглушка сохраняются.
- Доказательство полной истории — `full_history_policy_version: 1` вместе с
  успешным `history_synced_at`. Его ставит только успешный full, включая пустой.
  Старые ограниченные full и incremental не доказывают полноту. Монотонные
  provider/local snapshot acknowledgements и deletion fences сохраняются.
- После подключения provider history event запрашивает существующий history
  pipeline. Для тихих старых каналов `ReconcileHistoryJob` каждые 5 минут
  (`3-58/5`) проверяет не более **100** open/connected каналов активных аккаунтов,
  пропуская удаляемые inbox, неизвестный provider snapshot, актуальную baseline,
  pending запрос и занятый runtime mutex. Сам scan не обращается к провайдеру.
- Redis cursor и короткий scan mutex — операционные данные. Запрос ставится
  через единый `request_history_sync!` под SQL row lock с долговечным pending
  marker. Потеря cursor не теряет baseline и не дублирует pending работу.
  Истёкший pending (30 минут) допускает повтор после сбоя. Существующий job mutex
  защищает выполняющийся импорт; при отказе одной постановки scan идёт дальше.
- Исторические contacts/chats/messages и адресное обогащение выполняются под
  `Current.with_runtime_events_suppressed`: без SendReplyJob, AI, automation и
  auto-assignment. Повтор failed LID сообщений подавлен только в этом контексте;
  обычное живое обновление контакта сохраняет прежнее поведение.

## Загрузка вложения пользователем

Обычный пользователь, имеющий право `Conversation/show`, может вызвать:

`POST /api/v1/accounts/:account_id/conversations/:display_id/messages/:id/enrich_media`

Тело запроса не нужно. Произвольный URL не принимается: источник определяется
из scoped Message. Проверяются account, conversation, inbox и удаление сообщения.
Используется существующий WA backfill/decrypt/SSRF/attachment pipeline; TG
делегируется в существующий `TelegramPersonal::EnrichHistoryMediaService`.
Прежний TG inbox endpoint сохранён для совместимости.

Повторный запрос не создаёт второе вложение. Provider RPC выполняется без SQL
row lock; финальная запись проверяет вложения и удаление атомарно. Занятый mutex
возвращает **409** `history_media_busy`; контролируемая ошибка — **422**
`history_media_unavailable`. Если провайдер больше не отдаёт файл, ответ сохраняет
заглушку с `history_attachment.fetch_state: unavailable`; интерфейс показывает
понятное состояние и повтор. `MAX_ATTEMPTS` при адресной загрузке запрещает только
фоновую очередь retry, сама попытка загрузки выполняется.

## Технические операции поддержки

Клиентам доступны статус, QR/code/password, reconnect и обычная повторная
авторизация. Ручных history reset/full/contacts кнопок нет, новый support UI
не создаётся. Следующие POST endpoints сохранены только для поддержки:

- `/api/v1/accounts/:account_id/inboxes/:id/repair_whatsapp_web`
- `/api/v1/accounts/:account_id/inboxes/:id/telegram_personal_history_sync`
  (`force`, `reset_cursor`, `include_contacts`, `full` — существующий контракт).
- `/api/v1/accounts/:account_id/inboxes/:id/telegram_personal_contacts_sync`
  (`force` — существующий контракт).

`Platform::SupportAccess` допускает активного `SuperAdmin` или уже проверенный
сервером `super_admin_impersonation` из Pundit context. Обычные admin/agent,
личный API token администратора, `captain_platform_access`, request params и
browser storage права поддержки не дают. Account/device/session scope и
pending-deletion guards выполняются до операции. При отказе provider не вызывается.
Поддержка использует выданный сервером auth/token в рамках существующей процедуры,
не копирует секреты в runbook или отчёты.

Автоматический TG импорт подтверждён исходниками gateway
`802431a3eab5cc5da0ed62a4a2d59dfb6d1416d6`: verify_code/password, QR completion,
reconnect и channel sync вызывают `_schedule_post_auth_sync`; durable
`full_history_sync_completed_at` и `_auto_reconcile_tick` восстанавливают начальный
full. Необязательный force/reset из FinishSetup больше не нужен.

## Перед выпуском и откат

Этот код **автоматически догрузит старую ограниченную историю** после применения.
Подготовка source не разрешает запуск на живых каналах. Нужны независимое media
review, DEV-проверка и отдельное конкретное разрешение владельца на применение;
PROD — только через согласованный release. Сейчас live full sync не запускался.

Read-only preflight от 02.11.2026: DEV — 0, PROD — 2 подходящих канала с provider
snapshot и старой policy. Это верхняя оценка **2 новых full jobs** при неизменном
состоянии; pending markers могут отложить их. Число ещё не полученных сообщений,
контактов и байтов у провайдера неизвестно. Scan ограничен 100 каналами за проход;
это ограничение постановки, а не объёма full job. Перед release повторить агрегат
без чтения диалогов и идентификаторов каналов, в read-only transaction:

```sql
BEGIN READ ONLY;
SET LOCAL statement_timeout = '5s';
SELECT COUNT(*) AS open_active_not_deleting,
  COUNT(*) FILTER (WHERE NULLIF(c.sync_state->>'provider_history_synced_at', '') IS NOT NULL) AS provider_snapshot_present,
  COUNT(*) FILTER (WHERE NULLIF(c.sync_state->>'provider_history_synced_at', '') IS NOT NULL
    AND c.sync_state->>'full_history_policy_version' IS DISTINCT FROM '1') AS old_policy_with_snapshot
FROM channel_whatsapp_web c
JOIN accounts a ON a.id = c.account_id
JOIN inboxes i ON i.channel_type = 'Channel::WhatsappWeb' AND i.channel_id = c.id
WHERE a.status = 0 AND c.connection_state = 'open'
  AND c.lifecycle_state = 'connected' AND i.deleting_at IS NULL;
ROLLBACK;
```

Откат — возврат согласованного предыдущего source/image по release runbook.
Миграций и удаления старых столбцов нет. Уже импортированная история не удаляется;
существующие файлы старше 90 дней не очищаются этим изменением. Не откатывать
provider acknowledgements или счётчики вручную и не запускать reset при откате.
