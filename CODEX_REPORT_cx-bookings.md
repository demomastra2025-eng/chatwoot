# Отчёт cx-bookings

## Что изменилось

1. Ответы пациентскому агенту. `enterprise/lib/captain/tools/agent/appointment_result.rb:1` задаёт единый формат: для одной записи остаются `success`, `appointment_id`, `doctor_name`, `local_date`, `local_time`, `status`. Время берётся из часового пояса специалиста, затем аккаунта. Для поиска остаются `success`, `appointments`, `has_more`; максимум 20 записей, идентификатор есть у каждой. Публичные инструменты и пациентский адаптер используют этот формат (`enterprise/lib/captain/tools/create_appointment_tool.rb:40`, `enterprise/app/services/captain/tools/copilot/search_appointments_service.rb:47`). Полные ответы Staff Copilot и общий `Scheduling::ToolPayloadBuilder` сохранены.
2. Ошибки пациента сведены к `time_taken` только для подтверждённого конфликта слота, `staff_will_help` для неизвестного или неуспешного исхода MedElement и прочих неподтверждённых состояний, `not_found`, `validation_error`, `schedule_not_open`. Для кода `MEDELEMENT_HORIZON_EXCEEDED` передаётся только `last_available_date`, когда она есть (`enterprise/lib/captain/tools/agent/appointment_result.rb:35`). Внутри `Captain::ToolResult` такой краткий ответ остаётся ошибкой с `retryable: false`, а модели выводится только согласованный JSON (`enterprise/lib/captain/tool_result.rb:100`, `enterprise/lib/captain/tool_result.rb:181`). Ожидание подтверждения записи в MedElement по прежнему составляет 45 секунд; пациентский путь через адаптер теперь тоже его применяет (`enterprise/app/services/captain/tools/copilot/create_appointment_service.rb:39`).
3. `get_appointment_provider_status` исключён из рабочих списков инструментов пациента, но старые ссылки в сохранённых описаниях не удалены. Если вызов всё же поступает, ответ всегда `{"success":false,"reason":"staff_will_help"}` (`enterprise/app/models/captain/assistant.rb:526`, `enterprise/lib/captain/tools/agent/account_tool_adapter.rb:40`). У сотрудника инструмент и полный ответ остались.
4. Новая запись с актором Captain получает `source = 'captain'`; сотрудник и существующие строки сохраняют прежний источник (`app/services/scheduling/appointments/upsert_service.rb:226`, `app/services/scheduling/appointments/upsert_service.rb:258`). В условиях автоматизации источник можно выбрать, русская подпись нового значения — «ИИ-агент» (`app/javascript/dashboard/routes/dashboard/settings/automation/constants.js:33`, `app/javascript/dashboard/i18n/locale/ru/scheduling.json:3`). Ключи en/kk добавлены для одинаковой структуры переводов, активный интерфейс остаётся русским. API по прежнему не принимает пользовательский `source`: его удаляет разрешённый набор параметров, а `MutationGuard` запрещает прямую передачу сервису.
5. При создании записи с ожидаемой командой MedElement `SchedulingAutomationRuleListener` сразу исполняет действия, которые не отправляют уведомление, и сохраняет список подходящих правил в существующих `custom_attributes` (`app/listeners/scheduling_automation_rule_listener.rb:4`, `app/services/automation_rules/appointment_created_notification_hold.rb:7`). `create_touch`, `send_webhook_event` и старый `apply_touch_plan` запускаются после `create_reception.status == succeeded`. Ключи исполненных действий хранятся в `ProviderCommand.execution_state`; блокировка PostgreSQL привязана к паре «запись, команда» и не держит транзакцию во время постановки webhook job (`app/services/automation_rules/appointment_created_notification_hold.rb:39`, `app/services/automation_rules/appointment_created_notification_hold.rb:55`). Повторный вызов и повторное событие не создают новое уведомление после успешной записи ключа. Завершённое напоминание также учитывается при поиске дубля (`app/services/automation_rules/touch_action_service.rb:124`). Для webhook передаётся постоянный идентификатор доставки.
6. Успех команды ставит задачу освобождения уведомлений, а ежеминутная задача восстанавливает потерянный запуск (`app/models/integrations/medelement/provider_command.rb:131`, `app/jobs/automation_rules/release_appointment_created_notifications_job.rb:6`, `config/schedule.yml:23`). На этапе отправки напоминание повторно проверяет точную команду `create_reception` и не проходит до её `succeeded` (`app/services/reminders/appointment_provider_guard.rb:41`). Автоматизация статуса исполняется с актором правила, чтобы не стереть привязку ожидающей команды (`app/services/automation_rules/appointment_action_service.rb:80`).

## Поведение по состояниям команды

| Состояние | Действия без уведомления | Удержанные уведомления |
| --- | --- | --- |
| Команда ещё не создана или ожидает подтверждения | Сразу | Ожидают |
| `succeeded` и та же запись всё ещё актуальна | Уже выполнены | Выполняются; повторный запуск использует ключ |
| `failed`, `declined`, `cancelled`, `provider_status_unknown` | Уже выполнены | Не отправляются, пока нет подтверждённого успеха |
| Запись отменена до успеха | Уже выполнены | Не отправляются |
| Запись без ожидаемой команды MedElement | Сразу | Сразу |

Глобальное событие `appointment.created` не задерживалось. Правила клиник и данные не изменялись. Путь переноса/отмены, сообщение об успешном переносе в `AiBookingOutcomeJob`, передача неудачных и неизвестных исходов сотруднику остались на месте. Правило, выключенное до подтверждения, при освобождении не исполняется; для действующего правила используется его текущая редакция.

## Проверка скрытых данных

`Captain::ContextFields` теперь передаёт пациентскому агенту только ID, имя специалиста, локальную дату и время, статус (`enterprise/lib/captain/context_fields.rb:34`, `enterprise/lib/captain/context_fields.rb:318`, `enterprise/lib/captain/context_fields.rb:422`; `enterprise/app/services/captain/assistant/agent_runner_service.rb:893`). Поэтому `appointment.liquid` не получает `external_ref`, оплату и атрибуты MedElement. Обратные вызовы трассировки получают уже сокращённый ответ инструмента; технические данные из него не попадают обратно в модель. Для внутренней логики успешного переноса `AgentRunner` читает нужное доказательство из БД отдельно (`enterprise/app/services/captain/assistant/agent_runner_service.rb:1080`). Входные аргументы инструмента в трассе могут по прежнему содержать выбранный самим агентом код кабинета; шаблоны и описания инструментов намеренно не менялись по указанию владельца о заморозке промпта. Это остаётся предметом отдельного просмотра промптов.

## Проверки

- `ruby -c` для всех 42 изменённых Ruby-файлов — успешно. Ранее после промежуточных правок те же проверки на 40 и 10 файлах также прошли.
- `bundle exec rubocop --force-exclusion --fail-level warning` для всех 42 изменённых Ruby-файлов — код выхода 0, предупреждений/ошибок/фатальных нарушений 0. Первый запуск выявил три предупреждения (`Lint/ShadowedArgument`, `Lint/UnusedMethodArgument`, `Lint/DuplicateBranch`); они исправлены, повторные запуски успешны. Замечания уровня convention не заявляются как исправленные.
- `node --check` для 4 изменённых JS-файлов — успешно; разбор JSON для 3 файлов переводов — успешно; разбор YAML `config/schedule.yml` — успешно.
- `git diff --check` для итогового набора коммитов — успешно.
- RSpec не запускался: на этой машине нет PostgreSQL/Redis. Написаны новые проверки формата, источника, условий автоматизации, удержания, восстановления, завершённого Reminder и барьера доставки; результат должен подтвердить релизный инженер.
- ESLint, Vitest, Prettier и `translationKeys.spec.js` не запускались: `node_modules` отсутствует, а рабочее задание прямо исключает эти проверки здесь.

## Оставшиеся риски и вопросы

- Строгую гарантию ровно одной внешней HTTP-доставки webhook нельзя обеспечить имеющимися таблицами и без миграции. После постановки `WebhookJob`, но до записи отметки об исполнении возможен повтор с тем же `X-Chatwoot-Delivery`. Локальное создание напоминания защищено даже после завершения; для webhook нужна дедупликация у получателя либо отдельный транзакционный outbox. Это единственная часть требования «ровно один раз», которая не доказана кодом.
- Повторная обработка старого `apply_touch_plan` после завершённого отложенного набора требует проверки на настоящей БД. Для обычных сохранённых напоминаний учитываются и завершённые записи; для отложенного набора используется его существующая логика записи.
- Подмодуль `docs/` в этой локальной копии не инициализирован. Документация не менялась; удалённый репозиторий не добавлялся и не использовался.
- Решение для владельца при дальнейшем просмотре: хранить снимок действий правила на момент создания записи или исполнять его текущую редакцию после подтверждения. Здесь выбрана текущая редакция, чтобы не копировать содержимое уведомлений и адреса webhook в данные записи.

## Предлагаемые фразы для будущего промпта

Успешная запись: «Вы записаны к {врач} на {дата} в {время}».

Неотправленное уведомление: «Подтверждение пока не отправлено; администратор свяжется с вами».
