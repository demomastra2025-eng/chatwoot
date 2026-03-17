# Инструкция по интеграции WhatsApp -> MacroCRM

## 1. Бизнес-правило по менеджерам

Это ключевая логика интеграции:

1. Если у контакта уже есть сделка в MacroCRM, то менеджер этой сделки становится менеджером чата в вашей системе.
2. Если сделки нет и заявка создается впервые, то менеджер чата сначала назначается в вашей системе, а затем этот же менеджер должен быть передан в MacroCRM как `manager_id` при создании заявки.

Иными словами:

- для существующей сделки источник истины по менеджеру: `MacroCRM`
- для новой сделки источник истины по менеджеру: `ваша система`

## 2. Назначение интеграции

При каждом сообщении WhatsApp, входящем или исходящем, интеграция должна:

1. Нормализовать номер телефона.
2. Найти контакт по номеру.
3. Если контакт найден, найти его сделки.
4. Если сделка найдена, определить менеджера сделки и назначить его менеджером чата в вашей системе.
5. Добавить note в последнюю сделку.
6. Если сделка не найдена, определить менеджера чата в вашей системе.
7. Создать новую заявку в MacroCRM с `manager_id`, соответствующим менеджеру чата.
8. Добавить note в созданную заявку.
9. Если контакт не найден, создать заявку, при этом MacroCRM автоматически создаст контакт, затем добавить note.

## 3. Базовая конфигурация API

Базовый URL:

```text
https://api.macroserver.kz/v2
```

Методы:

- для большинства вызовов используется `POST`
- для получения списка пользователей компании используется `GET /company/getUsers`

Обязательные заголовки:

```http
Authorization: Bearer macro-4D39Ynbx77cAwXnVXecrO2E_CLcBR9kD7pNxxLHU6qtyfodBZYWaXSM6q1U4CAGmk1-IF2Wu2-BDFv7ojOct_GB6O_jSrFLh2lgqVZ3zwfERZY344ITVltUpsGFhEZMaR3wxNzYxNjU5MTIzfGNjNDg1
AppId: 9
Content-Type: application/json
```

Готовые креды для подключения:

```json
{
  "base_url": "https://api.macroserver.kz/v2",
  "app_id": 9,
  "authorization": "Bearer macro-4D39Ynbx77cAwXnVXecrO2E_CLcBR9kD7pNxxLHU6qtyfodBZYWaXSM6q1U4CAGmk1-IF2Wu2-BDFv7ojOct_GB6O_jSrFLh2lgqVZ3zwfERZY344ITVltUpsGFhEZMaR3wxNzYxNjU5MTIzfGNjNDg1"
}
```

## 4. Подтвержденные endpoint'ы

Для задачи WhatsApp-интеграции и назначения менеджера подтверждены следующие endpoint'ы:

```text
POST /contacts/find
POST /estateBuy/find
POST /estateBuy/create
POST /estateBuy/addNote
GET  /company/getUsers
POST /estateBuy/changeManager
```

## 5. Входные данные из вашей системы

Минимальный входной объект:

```json
{
  "phone": "+77001234567",
  "name": "Имя клиента",
  "text": "Здравствуйте, хочу узнать о квартирах",
  "direction": "incoming"
}
```

Расширенный вариант:

```json
{
  "phone": "+77001234567",
  "name": "Имя клиента",
  "text": "Здравствуйте, хочу узнать о квартирах",
  "direction": "incoming",
  "chat_manager": {
    "external_id": "user-42"
  }
}
```

Допустимые значения `direction`:

```text
incoming
outgoing
```

## 6. Нормализация телефона

Перед отправкой в API номер нужно привести к формату:

```text
+77001234567
```

Правило:

- сохранить ведущий `+`
- удалить пробелы, скобки, дефисы и прочие символы
- оставить только цифры после `+`

Примеры:

```text
+7 708 500 4695 -> +77085004695
+77072817060 -> +77072817060
```

## 7. Формирование note

Для входящего сообщения:

```text
[Входящее WhatsApp] <text>
```

Для исходящего сообщения:

```text
[Исходящее WhatsApp] <text>
```

Примеры:

```text
[Входящее WhatsApp] Здравствуйте, хочу узнать о квартирах
[Исходящее WhatsApp] Добрый день! Какие квартиры интересуют?
```

## 8. Менеджеры: как делать сопоставление

### 8.1. Откуда брать список менеджеров MacroCRM

Для этого используется:

```http
GET /company/getUsers
```

Проверенный реальный ответ:

```json
{
  "success": true,
  "users": [
    {
      "id": 79777,
      "name": "Aubakir Diana ",
      "department_id": null
    },
    {
      "id": 78731,
      "name": "Мереке Мираз",
      "department_id": 2475
    }
  ]
}
```

### 8.2. Рекомендуемый способ сопоставления

Сопоставление менеджеров нужно делать на вашей стороне через таблицу соответствий:

```json
{
  "external_manager_id_1": 78731,
  "external_manager_id_2": 78733,
  "external_manager_id_3": 79777
}
```

Рекомендация:

- основной ключ сопоставления: ваш внутренний `external_manager_id`
- хранимое значение: `macro_manager_id`
- имя можно использовать только для разового ручного заполнения таблицы

### 8.3. Как использовать сопоставление по бизнес-логике

Если сделка уже существует:

1. взять `manager_id` из найденной сделки в MacroCRM
2. найти по нему локального менеджера в вашей системе
3. назначить этого менеджера владельцем чата
4. не пытаться менять менеджера сделки, если это не требуется бизнес-процессом

Если сделки не существует:

1. выбрать менеджера чата в вашей системе
2. взять его `external_manager_id`
3. найти ему `macro_manager_id` в таблице маппинга
4. передать этот `macro_manager_id` в `POST /estateBuy/create`

## 9. Алгоритм обработки сообщения

### Сценарий A. Контакт найден, сделка найдена

Порядок:

```text
1. /contacts/find
2. /estateBuy/find
3. взять manager_id из последней сделки
4. назначить этого менеджера владельцем чата в вашей системе
5. /estateBuy/addNote
```

### Сценарий B. Контакт найден, сделок нет

Порядок:

```text
1. /contacts/find
2. /estateBuy/find
3. определить менеджера чата в вашей системе
4. /estateBuy/create с manager_id
5. /estateBuy/addNote
```

### Сценарий C. Контакт не найден

Порядок:

```text
1. /contacts/find
2. определить менеджера чата в вашей системе
3. /estateBuy/create с manager_id
4. /estateBuy/addNote
```

## 10. Endpoint 1 - Поиск контакта

URL:

```http
POST /contacts/find
```

Request:

```json
{
  "phone": "+77001234567"
}
```

Реально проверенный ответ при отсутствии контакта:

```json
{
  "error": true,
  "message": "No contacts found"
}
```

Реально проверенный ответ при наличии контакта:

```json
{
  "success": true,
  "contact": {
    "id": 5192521,
    "name": "Аманжол 21"
  }
}
```

Важно:

- отсутствие контакта нужно обрабатывать как бизнес-сценарий
- после `No contacts found` нужно переходить к `/estateBuy/create`

## 11. Endpoint 2 - Поиск сделок контакта

URL:

```http
POST /estateBuy/find
```

Request:

```json
{
  "contacts_id": 5044369
}
```

Пример ответа:

```json
{
  "success": true,
  "buys": [
    {
      "id": 5767119,
      "manager_id": 78731
    }
  ]
}
```

Правило обработки:

- если `buys` пустой, нужно создавать заявку через `/estateBuy/create`
- если `buys` не пустой, нужно взять последнюю сделку массива:

```text
buys[buys.length - 1]
```

Именно `manager_id` этой сделки нужно использовать как менеджера чата у вас.

## 12. Endpoint 3 - Создание заявки

URL:

```http
POST /estateBuy/create
```

Назначение:

- создать заявку
- если контакта еще нет, MacroCRM создает его автоматически
- если передан `manager_id`, заявка назначается указанному менеджеру

Request без менеджера:

```json
{
  "name": "Имя Клиента",
  "phone": "+77001234567",
  "action": "buy",
  "message": "Здравствуйте, хочу узнать о квартирах",
  "utm": {
    "channel_medium": "WhatsApp (One-Link)",
    "utm_source": "whatsapp",
    "utm_medium": "messenger",
    "utm_campaign": "one-link"
  }
}
```

Request с менеджером:

```json
{
  "name": "Имя Клиента",
  "phone": "+77001234567",
  "action": "buy",
  "message": "Здравствуйте, хочу узнать о квартирах",
  "manager_id": 78731,
  "utm": {
    "channel_medium": "WhatsApp (One-Link)",
    "utm_source": "whatsapp",
    "utm_medium": "messenger",
    "utm_campaign": "one-link"
  }
}
```

Проверенный реальный ответ:

```json
{
  "estate": {
    "id": 6788377
  },
  "contact": {
    "id": 6043135
  },
  "contact_created": true,
  "estate_created": true
}
```

Что использовать дальше:

- `estate.id` - для `addNote`
- `contact.id` - как ID созданного или привязанного контакта

### 12.1. Практически подтвержденное назначение менеджера при создании

Проверенный кейс:

- запрос на `POST /estateBuy/create`
- передан `manager_id = 78731`
- создана заявка `estate.id = 6788382`
- последующий `POST /estateBuy/find` вернул у этой заявки `manager_id = 78731`

Фактически подтвержденный ответ:

```json
{
  "create": {
    "estate": {
      "id": 6788382
    },
    "contact": {
      "id": 6043140
    },
    "contact_created": true,
    "estate_created": true
  },
  "find": {
    "success": true,
    "buys": [
      {
        "id": 6788382,
        "manager_id": 78731,
        "status": 10
      }
    ]
  }
}
```

## 13. Endpoint 4 - Добавление note

URL:

```http
POST /estateBuy/addNote
```

Request для входящего:

```json
{
  "id": 4321,
  "note": "[Входящее WhatsApp] Здравствуйте, хочу узнать о квартирах"
}
```

Request для исходящего:

```json
{
  "id": 4321,
  "note": "[Исходящее WhatsApp] Добрый день! Какие квартиры интересуют?"
}
```

Проверенный ответ:

```json
{
  "success": true
}
```

### Что такое addNote

`addNote` не назначает менеджера и не меняет ответственного.

`addNote` делает только одно:

- записывает текстовое событие в заявку
- используется для фиксации факта входящего или исходящего сообщения WhatsApp

То есть:

```text
менеджер -> отвечает за заявку и чат
note -> хранит историю общения
```

## 14. Endpoint 5 - Получение списка менеджеров

URL:

```http
GET /company/getUsers
```

Назначение:

- получить пользователей компании
- выбрать активных менеджеров
- использовать их `id` как `manager_id`

Request body:

```text
не требуется
```

## 15. Endpoint 6 - Изменение менеджера заявки

URL:

```http
POST /estateBuy/changeManager
```

Request:

```json
{
  "estate_buy_id": 6788382,
  "manager_id": 78731
}
```

Практически подтвержденное ограничение:

```json
{
  "message": "Access denied to action 'changeManager'"
}
```

Вывод:

- метод существует
- текущий токен не имеет прав на отдельную смену менеджера существующей заявки
- для вашего сценария это не критично, потому что нужная логика закрывается через чтение менеджера существующей сделки и передачу `manager_id` при создании новой

## 16. Полная пошаговая инструкция

### 16.1. Подготовить входные данные

```json
{
  "phone": "+77072817060",
  "name": "WhatsApp Test 77072817060",
  "text": "Тест полного сценария WhatsApp",
  "direction": "incoming",
  "chat_manager": {
    "external_id": "user-42"
  }
}
```

### 16.2. Нормализовать номер

```text
+77072817060
```

### 16.3. Сформировать note

Если `direction = incoming`:

```text
[Входящее WhatsApp] Тест полного сценария WhatsApp
```

Если `direction = outgoing`:

```text
[Исходящее WhatsApp] Тест полного сценария WhatsApp
```

### 16.4. Вызвать `/contacts/find`

```json
{
  "phone": "+77072817060"
}
```

Если найден `contact`, переходить к `/estateBuy/find`.

Если пришел ответ:

```json
{
  "error": true,
  "message": "No contacts found"
}
```

сразу переходить к созданию заявки.

### 16.5. Если контакт найден, вызвать `/estateBuy/find`

```json
{
  "contacts_id": 5044369
}
```

Если сделки есть:

1. взять последнюю сделку
2. прочитать `manager_id` этой сделки
3. назначить этого менеджера владельцем чата в вашей системе
4. вызвать `/estateBuy/addNote`

Если сделок нет:

1. выбрать менеджера чата в вашей системе
2. через таблицу маппинга получить `macro_manager_id`
3. вызвать `/estateBuy/create` с `manager_id = macro_manager_id`
4. вызвать `/estateBuy/addNote`

### 16.6. Если контакт не найден

1. выбрать менеджера чата в вашей системе
2. через таблицу маппинга получить `macro_manager_id`
3. вызвать `/estateBuy/create` с `manager_id = macro_manager_id`
4. вызвать `/estateBuy/addNote`

Пример:

```json
{
  "name": "Имя клиента",
  "phone": "+77072817060",
  "action": "buy",
  "message": "Текст сообщения",
  "manager_id": 78731,
  "utm": {
    "channel_medium": "WhatsApp (One-Link)",
    "utm_source": "whatsapp",
    "utm_medium": "messenger",
    "utm_campaign": "one-link"
  }
}
```

## 17. Готовые HTTP-примеры

### 17.1. Поиск контакта

```bash
curl -X POST "https://api.macroserver.kz/v2/contacts/find" \
  -H "Authorization: Bearer macro-4D39Ynbx77cAwXnVXecrO2E_CLcBR9kD7pNxxLHU6qtyfodBZYWaXSM6q1U4CAGmk1-IF2Wu2-BDFv7ojOct_GB6O_jSrFLh2lgqVZ3zwfERZY344ITVltUpsGFhEZMaR3wxNzYxNjU5MTIzfGNjNDg1" \
  -H "AppId: 9" \
  -H "Content-Type: application/json" \
  -d '{
    "phone": "+77072817060"
  }'
```

### 17.2. Поиск сделок

```bash
curl -X POST "https://api.macroserver.kz/v2/estateBuy/find" \
  -H "Authorization: Bearer macro-4D39Ynbx77cAwXnVXecrO2E_CLcBR9kD7pNxxLHU6qtyfodBZYWaXSM6q1U4CAGmk1-IF2Wu2-BDFv7ojOct_GB6O_jSrFLh2lgqVZ3zwfERZY344ITVltUpsGFhEZMaR3wxNzYxNjU5MTIzfGNjNDg1" \
  -H "AppId: 9" \
  -H "Content-Type: application/json" \
  -d '{
    "contacts_id": 5044369
  }'
```

### 17.3. Создание заявки с назначением менеджера

```bash
curl -X POST "https://api.macroserver.kz/v2/estateBuy/create" \
  -H "Authorization: Bearer macro-4D39Ynbx77cAwXnVXecrO2E_CLcBR9kD7pNxxLHU6qtyfodBZYWaXSM6q1U4CAGmk1-IF2Wu2-BDFv7ojOct_GB6O_jSrFLh2lgqVZ3zwfERZY344ITVltUpsGFhEZMaR3wxNzYxNjU5MTIzfGNjNDg1" \
  -H "AppId: 9" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Manager Mapping Test",
    "phone": "+77080003147",
    "action": "buy",
    "message": "Проверка manager_id при создании",
    "manager_id": 78731,
    "utm": {
      "channel_medium": "WhatsApp (One-Link)",
      "utm_source": "whatsapp",
      "utm_medium": "messenger",
      "utm_campaign": "manager-test"
    }
  }'
```

### 17.4. Добавление note

```bash
curl -X POST "https://api.macroserver.kz/v2/estateBuy/addNote" \
  -H "Authorization: Bearer macro-4D39Ynbx77cAwXnVXecrO2E_CLcBR9kD7pNxxLHU6qtyfodBZYWaXSM6q1U4CAGmk1-IF2Wu2-BDFv7ojOct_GB6O_jSrFLh2lgqVZ3zwfERZY344ITVltUpsGFhEZMaR3wxNzYxNjU5MTIzfGNjNDg1" \
  -H "AppId: 9" \
  -H "Content-Type: application/json" \
  -d '{
    "id": 6788377,
    "note": "[Входящее WhatsApp] Тест полного сценария WhatsApp 2026-03-14 02:03 PKT"
  }'
```

### 17.5. Получение списка пользователей компании

```bash
curl -X GET "https://api.macroserver.kz/v2/company/getUsers" \
  -H "Authorization: Bearer macro-4D39Ynbx77cAwXnVXecrO2E_CLcBR9kD7pNxxLHU6qtyfodBZYWaXSM6q1U4CAGmk1-IF2Wu2-BDFv7ojOct_GB6O_jSrFLh2lgqVZ3zwfERZY344ITVltUpsGFhEZMaR3wxNzYxNjU5MTIzfGNjNDg1" \
  -H "AppId: 9"
```

## 18. Готовый псевдокод

```text
INPUT: phone, name, text, direction, externalChatManagerId

1. phone = normalize(phone)

2. if direction == "incoming":
      note = "[Входящее WhatsApp] " + text
   else:
      note = "[Исходящее WhatsApp] " + text

3. contactRes = POST /contacts/find { phone }

4. if contactRes.contact exists:
      estateRes = POST /estateBuy/find { contacts_id: contactRes.contact.id }

      if estateRes.buys exists and estateRes.buys.length > 0:
          estate = estateRes.buys[last]
          estateId = estate.id
          macroManagerId = estate.manager_id

          assignChatManagerFromMacroManager(macroManagerId)
          POST /estateBuy/addNote { id: estateId, note }

      else:
          macroManagerId = managerMapping[externalChatManagerId]

          createRes = POST /estateBuy/create {
              name,
              phone,
              action: "buy",
              message: text,
              manager_id: macroManagerId,
              utm
          }

          estateId = createRes.estate.id
          POST /estateBuy/addNote { id: estateId, note }

   else if contactRes.error == true and contactRes.message == "No contacts found":
      macroManagerId = managerMapping[externalChatManagerId]

      createRes = POST /estateBuy/create {
          name,
          phone,
          action: "buy",
          message: text,
          manager_id: macroManagerId,
          utm
      }

      estateId = createRes.estate.id
      POST /estateBuy/addNote { id: estateId, note }

   else:
      log critical unexpected API response
      stop / retry / alert
```

## 19. Практически подтверждено

Проверено на живом API:

- сценарий `A`: контакт найден, сделка найдена, note добавлен
- сценарий `C`: контакт не найден, контакт создан автоматически, заявка создана, note добавлен
- `incoming` note
- `outgoing` note
- создание `estate` и `contact` через `/estateBuy/create`
- получение списка менеджеров через `GET /company/getUsers`
- назначение менеджера при создании через `manager_id` в `/estateBuy/create`

Проверенный кейс для `+77072817060`:

```json
{
  "contacts_find": {
    "error": true,
    "message": "No contacts found"
  },
  "estate_buy_create": {
    "estate": {
      "id": 6788377
    },
    "contact": {
      "id": 6043135
    },
    "contact_created": true,
    "estate_created": true
  },
  "estate_buy_add_note": {
    "success": true
  }
}
```

Проверенный кейс назначения менеджера:

```json
{
  "users_sample": [
    {
      "id": 78731,
      "name": "Мереке Мираз"
    }
  ],
  "create_with_manager": {
    "estate_id": 6788382,
    "contact_id": 6043140,
    "manager_id": 78731
  }
}
```

## 20. Важные замечания

- Реальный API при отсутствии контакта возвращает `error/message`, а не `success: true, contact: null`.
- После `/estateBuy/create` нужно брать `contact.id` и `estate.id` из ответа.
- `addNote` не назначает менеджера, а только пишет историю сообщения в заявку.
- Для существующей сделки менеджера нужно брать из `estateBuy/find` и назначать у вас владельцем чата.
- Для новой сделки менеджера нужно сначала определить у вас, а затем передать в `manager_id` при `estateBuy/create`.
- `POST /estateBuy/changeManager` существует, но текущий токен не имеет на него прав. Для вашего базового сценария это не блокер.
