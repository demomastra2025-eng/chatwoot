# MedElement Patient Identity Resolution Implementation Plan

> **For Hermes:** Execute this plan task-by-task only after explicit approval.

**Goal:** Без дублирования локальных Contact безопасно находить или создавать пациента MedElement для `create_reception`, используя данные самой записи и сохраняя исходную причину ошибки до UI.

**Architecture:** Для `create_reception` запись (`Scheduling::Appointment`) является источником телефона и введённых данных пациента; Contact остаётся связующей локальной сущностью и не создаётся/не переписывается ради интеграции. Resolver сначала использует уже связанный provider code, затем выполняет строгий identity matching среди результатов поиска, и только при доказанном отсутствии совпадения допускает создание удалённого пациента. Reconciliation применяется исключительно после фактического начала provider write.

**Tech Stack:** Rails 7.1, Ruby, RSpec, MedElement `/doctor/v1/patients` и `/doctor/v1/patient` API.

---

## Подтверждённый DEV-контекст

- Команды `22–26`, appointment `95/106`, Contact `5213`.
- Snapshot команды `26` содержит валидный телефон, `name` и `lastname`; ИИН отсутствует.
- Read-only поиск MedElement по телефону вернул 3 разных `PROFILE_CODE`.
- Точных совпадений ФИО snapshot с этими тремя пациентами: 0.
- У всех трёх удалённых пациентов ИИН заполнен.
- Попытка использовать недокументированный query `iin=...` на `/doctor/v1/patients` получила HTTP 400. Реализацию такого поиска наугад не добавляем.
- `reconciliation_unknown_write_phase` — вторичная маскирующая ошибка: identity ambiguity возникла до provider write, но была ошибочно отправлена в reconciliation без `write_phase`.
- Локальный код создания provider command не создаёт новый Contact; все команды привязаны к существующему Contact `5213`.

## Целевые правила identity resolution

1. Если в snapshot уже есть `provider_patient_code`, использовать его после существующей проверки account conflict.
2. Для `create_reception` брать из Appointment:
   - `client_phone`;
   - `client_name`;
   - `client_identifier` как потенциальный ИИН;
   - `client_birth_date` и `client_gender`, если заполнены.
   Contact использовать только как fallback для отсутствующих полей.
3. Не мутировать ФИО/телефон/ИИН существующего Contact при сборке snapshot или поиске.
4. Не создавать новый локальный Contact в provider-command flow.
5. Среди точных совпадений телефона:
   - при валидном ИИН — выбирать только единственное точное совпадение ИИН;
   - без ИИН — выбирать только единственное точное совпадение нормализованных имени и фамилии; дату рождения использовать как дополнительный discriminator, если она заполнена;
   - несколько identity matches → `patient_match_ambiguous`, без write;
   - телефон совпал, но identity не совпала → не привязывать чужого пациента.
6. Создание нового удалённого пациента MedElement допускается только когда snapshot содержит минимум отдельные имя + фамилию и валидный телефон; если телефон уже принадлежит другим пациентам, создание допускается лишь как явно подтверждённое действие с понятным текстом «будет создан новый пациент MedElement», а не как скрытая часть записи.
7. Полноценный поиск по ИИН реализовать только после подтверждения документированного MedElement endpoint/query. До этого ИИН используется как сильный discriminator в уже полученных phone results и включается в create payload.
8. Любая identity-ошибка до `mark_write_phase!` завершается детерминированно исходным кодом и никогда не запускает reconciliation.

## Task 1: Зафиксировать regression-контракт identity matching

**Objective:** Тестами описать безопасное поведение до изменения production-кода.

**Files:**
- Modify: `spec/services/integrations/medelement/provider_commands/patient_payload_builder_spec.rb`
- Modify/Create relevant examples: `spec/services/integrations/medelement/provider_commands/patient_resolver_spec.rb`
- Modify: `spec/services/integrations/medelement/provider_commands/create_service_spec.rb`
- Modify: `spec/services/integrations/medelement/provider_commands/executor_spec.rb`
- Modify: `spec/services/integrations/medelement/provider_commands/reconciliation_service_spec.rb`

**Steps:**
1. Добавить failing spec: appointment identity overrides blank/stale Contact identity only for `create_reception`.
2. Добавить spec: Contact после snapshot build не изменён и новый Contact не создан.
3. Добавить resolver specs:
   - один phone + exact ИИН match → link existing patient;
   - несколько phone matches + один exact ФИО match → link exact patient;
   - несколько exact identity matches → deterministic ambiguity;
   - phone matches есть, identity matches нет → никакой случайной link;
   - provider patient creation разрешена только при complete snapshot identity и явном allow-create contract.
4. Добавить executor spec: pre-write ambiguity сохраняет `patient_match_ambiguous`, status `failed`, reconciliation job не ставится.
5. Запустить новые examples и подтвердить ожидаемый FAIL до реализации.

## Task 2: Сделать Appointment источником patient snapshot для create_reception

**Objective:** Передавать в immutable snapshot данные человека, введённые именно для записи, без изменения Contact.

**Files:**
- Modify: `app/services/integrations/medelement/provider_commands/request_snapshot_builder.rb`
- Modify: `app/services/integrations/medelement/provider_commands/patient_payload_builder.rb`

**Steps:**
1. Расширить builder явными optional overrides: имя/фамилия/ИИН/дата рождения/пол/телефон.
2. Для `create_reception` подготовить overrides из Appointment; для `create_patient/update_patient` оставить прежний contact-based контракт.
3. Нормализовать ИИН через существующий `Scheduling::IinValidator`, не принимать произвольные 12 цифр без checksum.
4. Не присваивать значения Contact и не вызывать contact create/upsert.
5. Запустить Task 1 specs; ожидание — snapshot/persistence tests зелёные.

## Task 3: Разделить ФИО без опасной догадки порядка

**Objective:** Не считать автоматически, что произвольное `client_name` всегда записано как «Фамилия Имя».

**Files:**
- Modify: `app/services/integrations/medelement/provider_commands/patient_payload_builder.rb`
- Potential UI/API follow-up only if required: scheduling form/i18n files that own `client_identifier` and separate name fields.

**Steps:**
1. Сначала использовать явные `medelement_first_name/medelement_last_name`, если они уже есть.
2. Проверить, есть ли в Appointment/Contact структурированные поля имени; использовать их перед display name.
3. Если остаётся только строка `client_name`, не выполнять silent identity link на основании неоднозначно разобранного порядка.
4. Для создания пациента потребовать однозначные first/last values; если продукт пока хранит одну строку, добавить в confirmation/UI явное подтверждение разбиения или отдельные поля, а не угадывать.
5. Добавить RU/EN/KK i18n для actionable ошибки: «Уточните имя, фамилию или ИИН пациента».

## Task 4: Усилить PatientResolver

**Objective:** Связывать существующего пациента только по доказанному identity match и не создавать локальные дубли.

**Files:**
- Modify: `app/services/integrations/medelement/provider_commands/patient_resolver.rb`
- Modify: `app/services/integrations/medelement/client.rb` только если подтверждён provider contract по ИИН.

**Steps:**
1. Отделить `phone_candidates` от `identity_matches`.
2. Реализовать приоритет discriminator: ИИН → ФИО → дата рождения, только exact normalized comparisons.
3. Линковать provider code только при `identity_matches.one?`.
4. Не вызывать `account.contacts.create`/upsert; сохранять `medelement_patient_code` только на том же command Contact через существующий conflict guard.
5. При unresolved identity вернуть отдельные коды (`patient_identity_mismatch`, `patient_match_ambiguous`, `patient_identity_incomplete`) с actionable UI copy.
6. Если MedElement подтвердит документированный IIN lookup, добавить отдельный client method и contract specs; до подтверждения этого не делать.

## Task 5: Исправить границу reconciliation

**Objective:** Не маскировать pre-write identity errors как `reconciliation_unknown_write_phase`.

**Files:**
- Modify: `app/services/integrations/medelement/provider_commands/executor.rb`
- Modify if needed: `app/services/integrations/medelement/provider_commands/reconciliation_service.rb`

**Steps:**
1. Разрешать `reconciliation_required` только когда `execution_state.write_phase` реально установлен.
2. Для ambiguity/mismatch до write сохранять исходный error code и status `failed`.
3. Добавить defensive handling: reconciliation command без write phase не должен терять исходную причину.
4. Проверить, что transport timeout/5xx после patient/reception write по-прежнему идёт в reconciliation.

## Task 6: Confirmation и UX защиты от удалённого дубля

**Objective:** Пользователь должен понимать, когда будет создан новый patient в MedElement.

**Files:**
- Inspect/Modify: `app/services/integrations/medelement/provider_commands/create_service.rb`
- Inspect/Modify relevant confirmation payload/i18n files after tracing exact UI caller.

**Steps:**
1. В confirmation metadata различать `link_existing_patient`, `create_new_patient`, `identity_unresolved`.
2. Для `create_new_patient` показать ФИО (без лишних PII), masked phone и явный эффект создания пациента MedElement.
3. При ambiguity не показывать обычное подтверждение записи; запросить ИИН/структурированное ФИО или ручной выбор provider patient.
4. Не создавать/не объединять локальные Contact автоматически; конфликт ИИН с другим Contact отдавать на ручное разрешение.

## Task 7: Проверка

**Code-level:**
1. `bundle exec rspec spec/services/integrations/medelement/provider_commands`
2. `bundle exec rspec spec/services/integrations/medelement/client_spec.rb spec/requests/api/v1/accounts/scheduling/provider_commands_spec.rb`
3. Scoped UI tests, если меняется форма/confirmation.
4. `bundle exec rubocop <touched Ruby files>`.
5. `git diff --check` и финальный scoped diff review.

**DEV/read-only:**
1. На appointment `106` построить snapshot без DB mutation и проверить наличие phone/name/lastname и отсутствие Contact mutation.
2. На тех же 3 phone candidates проверить, что ни один не линкуется без identity match.
3. Проверить, что pre-write failure возвращает конкретный `patient_identity_*`, а не reconciliation code.

**DEV/runtime — только после отдельного разрешения:**
1. Перезапустить `onelink-chatwoot-dev.service`.
2. Проверить systemd, Puma/Vite и `https://dev.one-link.kz/`.
3. Выполнить один контролируемый тест через UI.
4. Сравнить до/после: число локальных Contact не выросло; provider patient code привязан только после доказанного match или явно подтверждённого create.

## Риски и решения

- **Одинаковый семейный телефон:** телефон не является уникальной личностью; нужен ИИН или ФИО + дополнительный discriminator.
- **Неоднозначный порядок имени:** нельзя тихо интерпретировать display name; предпочтительны отдельные поля.
- **Удалённый дубль при сменившемся телефоне:** без документированного IIN lookup автоматическое создание по одному телефону запрещать/явно подтверждать.
- **Локальный duplicate Contact:** flow не создаёт Contact; конфликт существующего ИИН не мержится автоматически.
- **Старые команды `22–26`:** не перезапускать автоматически. Они terminal failed; после фикса создать новую команду. Любая ручная смена их состояния — отдельная DEV mutation.

## Acceptance criteria

- Ни один новый локальный Contact не создаётся и существующий Contact не переписывается скрыто.
- Пациент MedElement линкуется только при единственном доказанном identity match.
- Создание удалённого пациента явно видно в confirmation и требует complete identity.
- ИИН используется только по подтверждённому provider contract; недокументированные query не добавляются.
- Pre-write ambiguity/mismatch сохраняет исходный error code и не попадает в reconciliation.
- Scoped specs/lint зелёные, DEV проверка показывает отсутствие дублей.
