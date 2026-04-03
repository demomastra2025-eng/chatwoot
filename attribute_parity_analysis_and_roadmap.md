# Анализ атрибутов и roadmap паритета для контактов, диалогов, сделок, задач и записей scheduling

## 1. Цель документа

Этот документ фиксирует:

1. текущий эталонный функционал атрибутов в `contact` и `conversation`
2. текущие разрывы в `deal`, `task` и `appointment`
3. целевую нативную модель, которая будет логично встроена в существующий Onelink
4. поэтапный roadmap, который доводит систему до однородного, надежного и расширяемого состояния

Документ основан на статическом анализе текущего кода Onelink. Изначально это был архитектурный и продуктовый рабочий документ, но код с момента его подготовки заметно ушел вперед. Поэтому ниже roadmap сохраняется как целевая модель, а статус-снимок текущего runtime фиксируется отдельно.

## 1.1. Актуальный статус runtime

На текущий момент кодовая база уже закрывает значительную часть исходного roadmap.

Что уже реализовано:

- `conversation.custom_attributes` переведены на безопасные merge/delete semantics вместо разрушительного whole-hash replace
- legacy/structured write semantics выровнены через общий mutation path там, где это критично
- `currency` и `percent` доведены до нормального parity в filter/automation инфраструктуре
- `deal` и `task` уже догнаны по важной части breadth-поверхностей:
  - custom-field filters на backend и dashboard surfaces
  - summaries/отображение custom fields в list/board/calendar
  - workflow gates по обязательным managed fields
  - Captain context access, prompt rendering и custom-tool template context
- `appointment` перестал быть только raw JSONB storage и стал first-class managed field entity на том же structured engine, что `deal` и `task`
- для `appointment` уже есть:
  - definitions CRUD в settings
  - reserved built-in keys
  - server-side typed validation/defaults/rules
  - registry-driven rendering в scheduling drawer
  - filters
  - Captain context
  - automation conditions и actions
  - workflow gates на обязательные поля
- для `appointment` также появился first-class intake context внутри текущего scheduling create/edit flow: tenant может помечать managed fields как поля, которые нужно собирать на этапе записи

Что остается незакрытым полностью:

- внешний/public booking surface пока не реализован как отдельный продуктовый поток; текущая intake parity относится к dashboard scheduling flow и готовит модель к будущему переиспользованию
- часть stabilization/observability задач из конца roadmap остается отдельным эксплуатационным слоем, а не пробелом в базовой attribute-модели

## 2. Контекст и ключевая постановка задачи

Сейчас в проекте фактически существует не одна система атрибутов, а несколько параллельных слоев:

- legacy custom attributes для `contact` и `conversation`
- более структурированный CRM field layer для `deal` и `task`
- scheduling field layer для `appointment`, который уже опирается на structured registry, но исторически вырос из raw JSONB storage и поэтому все еще важен как зона синхронизации contracts и surfaces

Из-за этого разъезжаются:

- модель definitions
- типизация и серверная валидация
- UI и UX управления полями
- фильтрация
- automations
- AI/Captain context
- сценарии обязательности полей
- публичные и внешние формы

Задача не в том, чтобы "снести legacy", а в том, чтобы:

- сохранить `contact` и `conversation` как исторически стабильный контракт
- взять их как продуктовый эталон по breadth функциональности
- взять CRM field layer как эталон по качеству server-side дисциплины
- довести `deal`, `task` и `appointment` до сопоставимого уровня возможностей
- при этом не превратить систему в абстрактный EAV-конструктор, оторванный от домена

## 3. Базовые архитектурные принципы

### 3.1. Что считать нативным для Onelink

Нативным для текущего проекта следует считать такой подход:

- core business state хранится в обычных колонках и связях
- tenant-specific или variable business metadata хранится в `custom_attributes`
- runtime или integration metadata хранится в `additional_attributes`
- definitions полей хранятся в account-scoped registry
- значения полей остаются на строке сущности в JSONB, а не выносятся в EAV-таблицу значений

Это соответствует текущему Rails/Postgres-ландшафту проекта и не ломает established patterns.

### 3.2. Что нельзя делать

Нельзя:

- заменять custom fields core state-полями домена
- смешивать user-defined fields и integration metadata в одном бесконтрольном слое
- переносить дефекты legacy в новые сущности
- строить generic сущность `record` вместо явных `contact`, `conversation`, `deal`, `task`, `appointment`
- вводить EAV-модель "одна строка на одно значение атрибута" без крайне веской причины

### 3.3. Что нужно сохранить

Нужно сохранить:

- внешний контракт `contact` и `conversation` "как раньше"
- значения атрибутов в JSONB на самой сущности
- account-scoped isolation
- возможность гибко добавлять tenant-specific поля без миграций таблиц сущностей

## 4. Термины

### 4.1. Core field

Стабильное системное поле сущности, которое определяет ее жизненный цикл, связи или важный доменный state.

Примеры:

- `conversation.status`
- `deal.stage_id`
- `task.status_id`
- `appointment.starts_at`
- `appointment.resource_id`

### 4.2. Custom field

Пользовательское или интеграционное поле, которое расширяет сущность, но не должно подменять core state.

Примеры:

- "Предпочитаемый район"
- "Источник медицинского направления"
- "Внутренний код клиента"
- "Класс услуги"

### 4.3. Additional attributes

Системный и интеграционный metadata layer, не предназначенный для self-serve custom fields.

### 4.4. Attribute registry

Account-scoped definitions layer, который описывает:

- какие поля доступны для сущности
- какого они типа
- обязательны ли они
- есть ли у них options/default/rules/contexts
- где именно они должны быть видимы и использоваться

## 5. Что сейчас является эталоном

`contact` и `conversation` являются эталоном не потому, что там идеальная реализация, а потому что именно у них сегодня самый широкий продуктовый surface custom attributes.

Этот эталон состоит из нескольких capability-групп.

### 5.1. Definition CRUD

Для контактов и диалогов администратор может:

- создать definition
- выбрать сущность поля
- задать `label`
- задать `key`
- задать `description`
- выбрать тип поля
- задать список значений для list-like поля
- задать regex и подсказку
- отредактировать definition
- удалить definition

Почему это важно:

- это делает атрибуты self-serve слоем для аккаунта
- это снимает необходимость в миграциях под большинство tenant-specific расширений
- это создает административный контракт, на который затем опираются UI, filters и automations

Ограничения текущего эталона:

- definitions у legacy слабее, чем CRM
- часть ограничений живет в UI, а не на сервере
- `required`, `default_value`, `contexts` и унифицированные правила там слабые или отсутствуют

### 5.2. Типизированный UI для значений

В карточке контакта и диалога уже есть:

- рендеринг полей по типу
- inline-редактирование
- delete конкретного значения
- copy конкретного значения
- UI для `date`, `link`, `list`, `checkbox`, `text`
- client-side regex/url validation

Почему это важно:

- custom field становится живой частью рабочего интерфейса, а не просто JSON в API
- значение можно быстро заполнить на месте без открытия отдельного формы-редактора
- снижается friction у операторов и менеджеров

### 5.3. Entity value lifecycle

Для `contact` и `conversation` уже есть полный жизненный цикл значений:

- значение может прийти при создании сущности
- значение может обновляться частично
- отдельный ключ можно удалить
- значение попадает в payload API и UI state

Почему это важно:

- definition без удобного value lifecycle не дает реальной пользы
- именно этот слой делает custom fields рабочим механизмом в операционных сценариях

Исторически здесь был важный дефект:

- у `conversation` partial update раньше разрушительно заменял весь `custom_attributes` hash

На текущий момент этот дефект уже исправлен в runtime, и для документа это нужно трактовать как анти-паттерн legacy, который не должен повторяться в новых сущностях.

### 5.4. Filters и custom views

Контакты и диалоги уже умеют использовать custom attributes в фильтрации и в сохраненных представлениях.

Почему это важно:

- custom fields становятся полезными не только для хранения данных, но и для операционного поиска
- без этого self-serve поля быстро превращаются в "мертвую метадату"

Ограничения:

- типовая поддержка legacy неполная
- отдельные declared types шире, чем фактическая поддержка filter layer

### 5.5. Automation conditions

Custom attributes участвуют в automation conditions:

- text
- list
- checkbox
- date
- number-like сценарии частично

Почему это важно:

- именно automation делает custom fields частью бизнес-процесса, а не только UI
- многие вертикальные кейсы требуют триггеров по tenant-specific полям

Текущий потолок эталона:

- custom fields участвуют в conditions, но не образуют сильный unified automation contract для всех сущностей
- generic action layer для записи custom fields тоже не доведен до уровня first-class feature

### 5.6. Workflow gates

Для `conversation` уже существует сценарий required-before-resolve.

Почему это важно:

- пользовательские поля начинают участвовать в бизнес-процессе, а не только в описании
- это особенно нужно для CRM и scheduling, где закрытие этапов и завершение записей часто должно зависеть от completeness данных

Это одна из самых ценных возможностей эталона и один из главных кандидатов на перенос в `deal`, `task` и `appointment`.

### 5.7. External forms

У `contact` и `conversation` custom attributes участвуют во внешнем pre-chat form:

- поля подмешиваются в конфигурацию формы
- там есть required
- там есть list/select behavior
- там есть regex validation
- данные затем разводятся по `contact` и `conversation`

Почему это важно:

- custom fields не ограничиваются внутренним dashboard
- система умеет собирать tenant-specific поля на входе в продуктовый поток

Для `appointment` прямой аналог этому не widget pre-chat, а booking/appointment intake form.

### 5.8. Captain / AI context

Контакты и диалоги уже умеют отдавать selected custom fields в Captain context layer.

Почему это важно:

- AI должен видеть не только system state, но и доменно важные tenant-specific поля
- без этого custom fields теряют ценность в AI-assisted workflows

### 5.9. Variables и шаблоны

Custom attributes доступны как переменные в message/template-related UX.

Почему это важно:

- поля становятся частью коммуникационных сценариев
- это полезно и для CRM, и для scheduling, если сущность участвует в шаблонах или AI-generated replies

## 6. Что в эталоне нельзя переносить как есть

Эталон широк по возможностям, но не полностью надежен.

Ниже перечислены вещи, которые нужно исправить или не копировать в новые сущности.

### 6.1. Whole-hash replace вместо безопасного merge

Исторически `conversation` partial update заменял весь `custom_attributes` hash.

Почему это плохо:

- высок риск race condition
- partial update становится разрушительным
- это отличается от поведения `contact`

Текущий runtime уже ушел от этого поведения. Целевое правило для всей платформы остается таким:

- запись custom fields должна быть merge-based
- удаление ключа должно быть осознанным действием
- пустые значения должны удалять ключ по единым правилам

### 6.2. Неполная типовая поддержка legacy

Legacy definitions объявляют больше типов, чем реально поддерживают filters и automation surface.

Почему это плохо:

- у пользователя возникает ложное ощущение, что тип уже fully supported
- фильтрация и автоматизации становятся непредсказуемыми

Целевое правило:

- declared field types должны везде иметь одинаковую семантику
- если тип поддержан в registry, он должен иметь единый runtime contract в UI, API, filters и automation

### 6.3. Слабая серверная валидация legacy values

Сейчас часть правил legacy-полей фактически enforcement'ится только на фронте.

Почему это плохо:

- внешний API может записать данные, которые UI не позволил бы ввести
- интеграции и массовые импорты могут создавать мусор

Целевое правило:

- сервер всегда является source of truth по правилам полей

## 7. Текущее состояние по сущностям

### 7.1. Contact

#### Что уже хорошо

- широкая продуктовая поддержка
- strong compatibility surface
- участие в filters
- участие в automations
- участие в pre-chat
- участие в Captain
- inline UX управления значениями

#### Что слабо

- legacy registry слабее CRM layer
- серверные правила значений неполны
- часть поведения исторически разрослась по разным поверхностям

#### Решение

`contact` не нужно перепридумывать. Его нужно:

- оставить в старом внешнем контракте
- аккуратно harden'ить внутри
- подключить к общему runtime-слою через compatibility adapter

### 7.2. Conversation

#### Что уже хорошо

- широкий feature surface
- required-before-resolve
- filters
- automations
- Captain
- widget/public creation flow

#### Что слабо

- destructive update semantics
- legacy rules по значениям
- неоднородность с CRM

#### Решение

`conversation` также сохраняем как legacy-compatible entity, но:

- исправляем небезопасные write semantics
- поднимаем server-side enforcement
- подключаем к общему capability contract

### 7.3. Deal

#### Что уже хорошо

- сильная definitions модель
- server-side normalization
- required/default/options/rules
- active/inactive definitions
- position ordering
- distinct entity kind
- form rendering уже использует typed section

#### Что пока не дотягивает до эталона

- filters по custom fields уже есть, но сохраненные CRM custom views и дальнейшая product-polish остаются отдельным слоем
- parity по automation conditions уже есть, включая managed custom fields и native CRM actions
- workflow gates на обязательные managed fields уже есть
- Captain context parity уже есть, включая controlled visibility и tool/template access
- общая переменная модель уже частично закрыта через Captain/tool templates, но не превращена в единый глобальный variable system вне AI surface
- нет общей capability language между registry и surrounding surfaces

#### Решение

`deal` не надо переделывать в legacy-стиле. Наоборот:

- его structured layer нужно считать образцом качества
- ему нужно догнать breadth эталона `contact/conversation`

### 7.4. Task

#### Что уже хорошо

- structured field definitions
- server-side validation
- context-aware field applicability (`deal_task` / `standalone_task`)
- typed form rendering

#### Что пока не дотягивает

- filters по custom fields уже есть, но сохраненные CRM custom views и дальнейшая product-polish остаются отдельным слоем
- parity по automation conditions уже есть, включая managed custom fields и native CRM actions
- required-before-done уже есть
- Captain context parity уже есть, включая controlled visibility и tool/template access
- нет унифицированного lifecycle-слоя вокруг custom fields вне create/update form

#### Решение

Для `task` нужно продолжать развивать именно structured path и довести его до product parity.

### 7.5. Appointment

#### Что уже есть

- нативная сущность `Scheduling::Appointment`
- managed field definitions registry на structured engine
- settings UI управления полями
- reserved built-in keys
- server-side typed validation/defaults/rules
- workflow gates по обязательным managed fields
- filters и dashboard surfaces для custom fields
- Captain parity
- automation conditions и actions
- intake context внутри текущего scheduling flow
- у сущности уже есть `custom_attributes`
- custom fields проходят через form store и API payload
- scheduling не требует придумывать абстрактную сущность "record"

#### Что пока отсутствует полностью

- отдельный внешний/public booking surface, завязанный на appointment definitions
- финальная product-polish вокруг custom views и operator UX
- stabilization/observability слой из конца roadmap

#### Вывод

`appointment` уже находится на уровне полноценной managed attribute platform внутри продукта. Главный незакрытый разрыв теперь не в storage/registry, а во внешнем booking surface и эксплуатационной зрелости.

## 8. Целевая модель

### 8.1. Supported entity kinds

Целевой supported set:

- `contact`
- `conversation`
- `deal`
- `task`
- `appointment`

Не включать в первую волну:

- `resource`
- `service`
- `holiday`
- `time_off`
- `workday_override`

Их можно добавить позже, но сейчас это только размоет фокус.

### 8.2. Единый conceptual contract

Для любой из 5 сущностей должны существовать одинаковые базовые понятия:

- definition
- value
- supported type
- required
- default value
- options
- rules
- contexts
- visibility
- active/inactive
- update semantics
- delete semantics

Не обязательно, чтобы все это физически лежало в одной таблице уже на первом этапе. Но runtime contract должен быть единым.

### 8.3. Правильное деление слоев данных

#### Core columns

Сюда относятся:

- жизненный цикл
- статус
- ключевые отношения
- даты и идентификаторы доменного процесса

Примеры:

- `deal.stage_id`
- `task.status_id`
- `appointment.starts_at`
- `appointment.resource_id`

#### Custom attributes

Сюда относится:

- variable business metadata
- tenant-specific extensions
- field-driven workflow completeness data

#### Additional attributes

Сюда относится:

- provider metadata
- ingestion/runtime metadata
- technical integration payloads

Прямое правило:

- новые self-serve поля пользователя не должны появляться в `additional_attributes`

### 8.4. Единый набор типов

Целевой type set:

- `text`
- `textarea`
- `number`
- `currency`
- `percent`
- `checkbox`
- `date`
- `datetime`
- `select`
- `multiselect`
- `url`

Дополнительные типы вроде `phone` и `email` стоит вводить только если появится реальная server-side семантика, а не просто UI-маска.

### 8.5. Структура definition

Минимальный целевой definition contract:

- `account_id`
- `entity_kind`
- `key`
- `label`
- `description`
- `field_type`
- `required`
- `active`
- `position`
- `default_value`
- `options`
- `rules`
- `contexts`
- `visibility`
- `source`

#### Поле `contexts`

Нужно для случаев, когда поле применимо не всегда.

Примеры:

- `task`: `deal_task`, `standalone_task`
- `appointment`: `manual_create`, `booking_form`, `staff_edit`
- `conversation`: `widget_prechat`, `agent_sidebar`, `resolve_flow`

#### Поле `visibility`

Нужно для управления тем, где поле реально участвует.

Примеры:

- `ui`
- `api`
- `filters`
- `automation`
- `captain`
- `forms`

#### Поле `source`

Нужно различать:

- `user`
- `system`
- `integration`

Это особенно полезно для автосоздаваемых полей интеграций.

## 9. Capability-модель, к которой нужно прийти

Ниже зафиксирован целевой capability set, одинаковый по смыслу для всех 5 сущностей.

| Capability | Contact | Conversation | Deal | Task | Appointment | Target |
| --- | --- | --- | --- | --- | --- | --- |
| Definition CRUD | Есть | Есть | Есть | Есть | Есть | Везде |
| Типы полей | Частично | Частично | Есть | Есть | Есть | Везде, единая семантика |
| Default values | Слабо | Слабо | Есть | Есть | Есть | Везде, где логично |
| Required fields | Ограниченно | Есть в resolve-flow | Есть на create/update + workflow gates | Есть на create/update + workflow gates | Есть на create/update + workflow gates | Везде, плюс workflow gates |
| Regex/options/rules | Частично | Частично | Есть | Есть | Есть | Везде |
| Server-side normalization | Слабо | Слабо | Есть | Есть | Есть | Везде |
| Inline editing UI | Есть | Есть | Частично, через form | Частично, через form | Есть, через scheduling form | Везде |
| Single-key delete | Есть | Есть | По blank/delete semantics частично | По blank/delete semantics частично | По blank/delete semantics частично | Везде |
| Filters/custom views | Есть | Есть | Есть filters, custom views частично | Есть filters, custom views частично | Есть filters, custom views частично | Везде |
| Automation conditions | Есть | Есть | Нет | Нет | Есть | Везде для conditions |
| Workflow gates | Нет | Есть | Есть | Есть | Есть | Deal/Task/Appointment тоже |
| External form support | Есть | Есть | Ограниченно | Ограниченно | Есть intake внутри dashboard, public booking отдельно | Appointment booking/intake должен быть |
| Captain context | Есть | Есть | Есть | Есть | Есть | Везде по visibility |
| Variables/templates | Есть | Есть | Есть в Captain/tool templates | Есть в Captain/tool templates | Есть в Captain/tool templates | Там, где сущность участвует в шаблонах |
| Audit/timeline of field changes | Ограниченно | Ограниченно | Частично через CRM events | Частично через CRM events | Нет | Везде |

## 10. Что означает "закрыть большинство кейсов проекта"

Система должна нативно покрывать не один вертикальный кейс, а повторяемый класс кейсов.

### 10.1. Операционные кейсы

- оператору нужно быстро заполнить tenant-specific поле на месте
- менеджеру нужно фильтровать списки по пользовательским полям
- supervisor'у нужно построить custom view на базе этих полей

### 10.2. CRM кейсы

- продажа требует обязательных полей перед переводом сделки в следующий этап
- задача должна содержать доменные данные перед завершением
- поля должны быть разными для `standalone task` и `deal task`

### 10.3. Scheduling кейсы

- запись должна хранить доменные и клинические метаданные
- запись должна проверять completeness перед завершением
- форма записи должна подстраиваться под tenant-specific intake fields

### 10.4. Интеграционные кейсы

- внешняя интеграция может создавать системные или integration-defined поля
- такие поля не должны разрушать UX self-serve слоя
- сервер должен гарантировать корректную типизацию и допустимые ключи

### 10.5. AI кейсы

- AI должен видеть только те custom fields, которые разрешены и реально нужны
- prompt context не должен тащить весь сырой JSON indiscriminately

## 11. Целевой подход к реализации

### 11.1. Общий runtime API поверх разных storage backends

Физически сразу объединять legacy и CRM в одну таблицу не обязательно.

Но нужен общий runtime API, условно:

- `Attributes::DefinitionCatalog`
- `Attributes::ValueResolver`
- `Attributes::MutationService`
- `Attributes::VisibilityPolicy`
- `Attributes::CapabilityService`

Этот слой должен скрыть от остального продукта, из какой именно physical model пришла definition.

#### Почему это лучший путь

- не ломается legacy runtime для `contact/conversation`
- не теряется качество CRM field engine
- появляется возможность добавить `appointment` сразу по новому стандарту
- surrounding features начинают работать через единый contract

### 11.2. Compatibility adapters

#### Adapter для legacy

Нужен adapter, который переводит `custom_attribute_definitions` в единый runtime contract.

Он должен:

- маппить `attribute_model` в `entity_kind`
- маппить legacy type names в canonical type model
- поднимать `regex` и list values в общий rules/options contract
- отдавать определения в унифицированном формате

#### Adapter для CRM

CRM уже почти совпадает с целевой structured model.

Ему нужен более тонкий adapter, который:

- нормализует payload shape под общий runtime contract
- открывает эти fields для общих filters/automation/captain сервисов

### 11.3. Appointment как первая новая сущность на новом стандарте

`appointment` нужно делать не через новый отдельный кастомный layer, а сразу через тот же structured engine, который логически продолжает CRM field definitions.

Почему именно appointment:

- сущность уже нативная
- storage уже есть
- бизнес-кейс очевиден
- scheduling сейчас сильнее всего отстает по attribute platform

### 11.4. Feature parity должна строиться не от таблиц, а от capability groups

Нельзя считать задачу выполненной только потому, что:

- добавили `entity_kind = appointment`
- научились сохранять JSON

Parity считается только если появились surrounding surfaces:

- registry
- forms
- validation
- filtering
- workflow
- AI visibility
- external intake support

## 12. Детальный roadmap

Ниже roadmap сохранен как архитектурная декомпозиция работ, но уже не как буквальный todo-list.

По текущему коду:

- `Phase 0` по сути закрыта
- `Phase 3` закрыта
- `Phase 4` закрыта для текущего dashboard/runtime слоя
- `Phase 5` закрыта по filter surface; custom views/product polish остаются отдельным хвостом
- `Phase 6` закрыта
- `Phase 7` закрыта
- `Phase 8` закрыта для Captain/tool-template surface
- `Phase 9` закрыта только для внутреннего scheduling intake flow; внешний/public booking flow остается open
- `Phase 10` остается актуальным как эксплуатационный и documentation слой

### Phase 0. Hardening текущего фундамента

Статус: по текущему коду в основном закрыта.

#### Цель

Прекратить размножать слабые места текущей модели до того, как она станет общим foundation.

#### Что делаем

1. Исправляем destructive update semantics у `conversation.custom_attributes`.
2. Выровнять типовую поддержку legacy custom fields в filters и automation.
3. Усилить server-side validation там, где сейчас enforcement только на фронте.
4. Выровнять документацию и runtime payload contracts.

#### Почему это обязательно

Если начать строить shared platform на текущих дефектах legacy, они попадут в `deal`, `task` и `appointment`.

#### Критерий готовности

- partial update всегда безопасен
- declared field type имеет предсказуемое runtime behavior
- сервер не принимает очевидно невалидные значения только потому, что их прислал не UI

### Phase 1. Capability contract и canonical model

#### Цель

Формально зафиксировать единый capability contract для 5 сущностей.

#### Что делаем

1. Описываем canonical definition shape.
2. Описываем canonical value mutation semantics.
3. Описываем список supported field types и их runtime semantics.
4. Описываем visibility и contexts.
5. Описываем, какие surrounding surfaces должны поддерживать поля.

#### Почему это обязательно

Без этого команда начнет по-разному трактовать "поддержка custom fields" для каждой новой сущности.

#### Критерий готовности

- есть единый contract, на который могут ориентироваться backend, frontend и product

### Phase 2. Shared attribute runtime layer

#### Цель

Спрятать legacy и CRM differences за единым backend API.

#### Что делаем

1. Вводим общий catalog/resolver/mutation layer.
2. Пишем adapter для legacy definitions.
3. Пишем adapter для CRM definitions.
4. Переводим surrounding services на этот общий слой, где это можно сделать без рискованного UI rewiring.

#### Почему это обязательно

Пока surrounding features ходят прямо в legacy model или прямо в CRM model, однородности не будет.

#### Критерий готовности

- filters, automation и AI получают definitions через единый runtime API
- вызвав `entity_kind`, окружающий код не думает о physical backend

### Phase 3. Appointment definitions registry

Статус: закрыта.

#### Цель

Сделать `appointment` first-class сущностью attribute platform.

#### Что делаем

1. Добавляем `appointment` в supported entity kinds structured registry.
2. Определяем reserved built-in keys для appointment.
3. Подключаем definitions CRUD для appointment в settings UI.
4. Подключаем server-side value resolution по тем же правилам, что у CRM.

#### Рекомендуемый reserved built-in set для appointment

Как built-in и недоступные для custom key должны трактоваться:

- `resource_id`
- `service_id`
- `contact_id`
- `company_id`
- `conversation_id`
- `created_by_id`
- `starts_at`
- `ends_at`
- `duration_min`
- `status`
- `appointment_type`
- `client_name`
- `client_phone`
- `client_identifier`
- `client_birth_date`
- `client_gender`
- `client_comment`
- `source`
- `external_ref`
- `idempotency_key`
- `service_amount`
- `prepaid_amount`
- `prepaid_payment_method`
- `settlement_amount`
- `settlement_payment_method`
- `payment_status`

#### Почему это обязательно

Иначе scheduling останется отдельным сырым миром.

#### Критерий готовности

- admin может создать поле для appointment в settings
- сервер валидирует значения по definition
- unknown keys не проходят

### Phase 4. Registry-driven forms и consistent value lifecycle

Статус: закрыта для текущего dashboard/runtime слоя.

#### Цель

Сделать работу со значениями одинаковой для `deal`, `task`, `appointment`, без ломки legacy UX у `contact/conversation`.

#### Что делаем

1. Выделяем общий renderer для typed custom fields.
2. Используем его в deal/task forms и appointment form.
3. Устанавливаем единые правила:
   - blank удаляет ключ
   - checkbox хранится как boolean
   - multiselect хранится как array
   - date/datetime сохраняются в каноническом формате
4. Добавляем единый mutation contract для server-side merge semantics.

#### Почему это обязательно

Пока каждая сущность пишет custom fields по-своему, reliability и predictability не будет.

#### Критерий готовности

- `deal`, `task` и `appointment` редактируют typed fields одинаково
- server response и error semantics одинаковы

### Phase 5. Filters и custom views parity

Статус: filters закрыты; custom views и дополнительная product-polish частично open.

#### Цель

Сделать custom fields полноценным query surface для CRM и scheduling.

#### Что делаем

1. Расширяем filter infrastructure на `deal`, `task`, `appointment`.
2. Добавляем type-aware operators.
3. Добавляем select/list-aware options.
4. Поддерживаем custom views или их эквивалент там, где это уже существует продуктово.

#### Почему это обязательно

Без query surface custom fields полезны только как display metadata.

#### Критерий готовности

- можно фильтровать списки `deal`, `task`, `appointment` по custom fields
- типы работают предсказуемо

### Phase 6. Workflow gates parity

Статус: закрыта.

#### Цель

Перенести одну из самых ценных возможностей эталона на остальные сущности.

#### Что делаем

1. Для `deal` вводим required-before-transition или required-before-close policy.
2. Для `task` вводим required-before-done policy.
3. Для `appointment` вводим required-before-complete или required-before-paid policy по согласованным бизнес-статусам.

#### Почему это обязательно

В большинстве CRM и scheduling кейсов именно completeness enforcement делает custom fields реальным operational tool.

#### Критерий готовности

- пользователь не может завершить сущность, если обязательные поля пусты
- правила понятны, видимы и объяснимы в UI

### Phase 7. Automation parity

Статус: закрыта.

#### Цель

Подключить `deal`, `task`, `appointment` custom fields к automation conditions.

#### Что делаем

1. Стандартизируем condition metadata по field type.
2. Добавляем custom field conditions в automation layer для новых сущностей.
3. При необходимости отдельно проектируем actions по записи полей, но только как вторую волну.

#### Почему это обязательно

Многие tenant-specific процессы невозможно выразить без custom-field conditions.

#### Критерий готовности

- automation engine видит definitions и значения `deal`, `task`, `appointment`
- type-aware validation поддерживается на server-side

### Phase 8. Captain / AI / variables parity

Статус: закрыта для Captain/tool-template surface; глобальная cross-product variable system остается отдельной темой.

#### Цель

Сделать custom fields частью controlled AI context, а не только UI layer.

#### Что делаем

1. Расширяем context field registry на `deal`, `task`, `appointment`.
2. Добавляем visibility-control по `captain`.
3. При необходимости расширяем variable picker и template surfaces.

#### Почему это обязательно

AI-слой без tenant-specific metadata видит слишком мало реального контекста.

#### Критерий готовности

- Captain может безопасно получать разрешенные поля новых сущностей
- prompt context не тянет весь сырой payload без фильтрации

### Phase 9. External forms и intake parity

Статус: частично закрыта. Intake parity внутри scheduling dashboard уже есть; внешний/public booking flow остается open.

#### Цель

Дать `appointment` аналог того, что pre-chat уже дает `contact/conversation`.

#### Что делаем

1. Проектируем booking/intake form, завязанный на appointment definitions.
2. Поддерживаем required/options/regex/defaults для этой формы.
3. Гарантируем, что собранные данные валидируются тем же server-side engine, что и dashboard edits.

#### Почему это обязательно

Scheduling без registry-driven intake forms не закроет значимую часть реальных кейсов.

#### Критерий готовности

- appointment custom fields можно собирать не только вручную в dashboard, но и на входной форме

### Phase 10. Stabilization, observability и docs

#### Цель

Закрепить систему как долгосрочный foundation.

#### Что делаем

1. Добавляем audit trail изменения definitions.
2. Добавляем timeline-friendly field change events там, где нужно.
3. Добавляем кеширование definitions по `account + entity_kind + context`.
4. Добавляем индексы для hot keys.
5. Обновляем docs и API contracts.

#### Критерий готовности

- поведение задокументировано
- production diagnostics есть
- performance деградации контролируются

## 13. Детализация по surfaces

### 13.1. Backend

Backend должен стать главным гарантом корректности.

#### Что backend обязан гарантировать

- запрет unknown keys
- запрет конфликтов с built-in fields
- строгую типизацию и нормализацию
- единые delete semantics
- required/default/rules enforcement
- contexts enforcement
- visibility-aware read models для surrounding services

#### Что backend не должен перекладывать на frontend

- regex enforcement
- required logic
- allowed options enforcement
- canonical date/datetime normalization
- semantics удаления значений

### 13.2. Frontend

Frontend должен работать от registry, а не от ad hoc knowledge каждой страницы.

#### Что frontend обязан уметь

- универсально рендерить типы полей
- показывать consistent ошибки
- уважать `required`, `active`, `contexts`, `visibility`
- не хардкодить per-entity знание там, где можно использовать registry metadata

#### Что frontend не должен делать

- самостоятельно определять "это allowed key или нет"
- быть единственным местом, где живут правила поля

### 13.3. API

API-контракт должен быть одинаково понятен для всех entity kinds.

#### Принципы

- `custom_attributes` всегда передаются как объект
- create/update semantics одинаковы по смыслу
- blank/delete policy документирована
- validation errors структурированы одинаково

### 13.4. Data model

Значения продолжают жить на сущности в JSONB.

#### Почему это правильно

- это соответствует текущей модели проекта
- не вводит тяжелый EAV
- позволяет дешево читать сущность целиком
- хорошо сочетается с GIN и expression indexes

#### Когда нужен expression index

Когда конкретный custom key становится operationally hot:

- часто фильтруется
- участвует в уникальности
- используется в массовых выборках

## 14. Правила надежности

### 14.1. Mutation semantics

Для всех сущностей:

- update custom fields должен быть merge-based
- delete ключа должен быть осознанным действием
- пустые значения должны обрабатываться единообразно

### 14.2. Type semantics

Один field type должен иметь один смысл во всех поверхностях.

Примеры:

- `checkbox` всегда boolean
- `multiselect` всегда array
- `date` всегда ISO date
- `datetime` всегда ISO datetime
- `currency` и `percent` не должны поддерживаться в definitions, если они не поддержаны в runtime surface

### 14.3. Visibility semantics

Поле может существовать, но не обязано участвовать везде.

Это критично для:

- AI
- filters
- public forms
- workflow gates

### 14.4. Context semantics

Поле должно применяться только там, где оно реально релевантно.

Это особенно важно для:

- `task`
- `appointment`
- потенциальных vertical-specific входных форм

## 15. Non-goals

В первую волну не входит:

- физическая миграция legacy definitions на новый storage
- generic record builder
- custom fields для всех scheduling сущностей подряд
- полноценный reporting/analytics engine поверх custom fields
- универсальный automation action language для записи любых custom fields без отдельного product design

## 16. Риски и как ими управлять

### 16.1. Риск: сломать `contact/conversation`

#### Как снижать

- не менять внешний payload contract
- строить compatibility adapters
- hardening делать точечно

### 16.2. Риск: переусложнить scheduling

#### Как снижать

- first-class only `appointment`
- не тащить сразу `resource/service/holiday/time_off`

### 16.3. Риск: построить "однородность на бумаге"

#### Как снижать

- parity считать только по capability groups
- не засчитывать phase как done, если нет filters/automation/workflow/AI surface

### 16.4. Риск: размножить дефекты legacy

#### Как снижать

- Phase 0 hardening обязателен
- CRM structured layer используется как reference for validation discipline

## 17. Приоритеты

### P0

- hardening legacy write semantics и type consistency
- общий runtime contract
- `appointment` definitions registry

### P1

- registry-driven forms для `appointment`
- filters/custom views for `deal`, `task`, `appointment`
- workflow gates for `deal`, `task`, `appointment`

### P2

- automation parity
- Captain parity
- booking/intake parity для appointment

### P3

- advanced reporting
- расширение на `resource/service`, если появится подтвержденный спрос

## 18. Критерии успеха

Систему можно считать доведенной до целевого состояния, когда одновременно выполнены все условия:

1. `contact`, `conversation`, `deal`, `task`, `appointment` имеют понятный и единый attribute contract.
2. `contact` и `conversation` не потеряли backward compatibility.
3. `deal` и `task` получили breadth функциональности, сравнимый с эталоном `contact/conversation`.
4. `appointment` получил не только storage, но и полноценный registry-driven feature surface.
5. Сервер гарантирует типизацию, required/default/rules, contexts и safe mutation semantics.
6. Filters, workflow gates, automation и Captain используют единый источник правды о полях.
7. Новые self-serve поля больше не появляются через ad hoc JSONB без definitions layer.

## 19. Финальная рекомендация

Правильная стратегическая линия для Onelink выглядит так:

- не трогать внешнее поведение `contact` и `conversation`
- не тащить новые сущности в legacy layer
- использовать CRM field layer как образец качества валидации и нормализации
- сделать `appointment` первой новой сущностью, доведенной до structured attribute platform
- получить однородность через общий runtime contract и capability parity, а не через немедленный физический merge всех storage-моделей

Это позволит сохранить совместимость, не потерять текущие кейсы и при этом выстроить платформу атрибутов, которая нативно и надежно закрывает большинство реальных сценариев проекта.
