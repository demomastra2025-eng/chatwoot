# Firecrawl в Captain: загрузка базы знаний

Этот документ описывает, как Firecrawl должен использоваться в Captain именно для загрузки и обновления базы знаний в `/root/crafty/onelink/chatwoot`.

Связанные документы:

- [api_firecrawl.md](/root/crafty/onelink/chatwoot/api_firecrawl.md) — практический guide по новой Firecrawl `v2` API
- [firecrawl_reference.md](/root/crafty/onelink/chatwoot/firecrawl_reference.md) — полный технический reference

## 1. Главная идея

Для проекта важно держать чёткую границу:

- Firecrawl = `discovery + ingestion + refresh`
- Captain = `documents + FAQ + embeddings + runtime search`

Это значит:

- Firecrawl находит и качает контент
- Captain превращает контент в `Captain::Document`
- затем генерирует `Captain::AssistantResponse`
- затем строит embeddings
- затем отвечает через `search_documentation`

Firecrawl не должен становиться основным runtime-движком ответа ассистента.

## 2. Кейсы, которые должны закрываться

Ниже список кейсов, которые реально важны проекту.

### 2.1 Single Page Import

Когда нужен:

- одна страница docs
- одна статья help center
- одна страница pricing/changelog

Какой инструмент:

- `scrape`

### 2.2 Site Import

Когда нужен:

- импортировать docs/help center целиком
- завести нового ассистента по сайту клиента

Какой инструмент:

- `crawl`

### 2.3 Selected Pages Import

Когда нужен:

- сначала посмотреть найденные URL
- импортировать только нужные страницы
- не тащить весь сайт в knowledge base

Какой инструмент:

- `map`
- затем `batch scrape`

### 2.4 Remote PDF URL Import

Когда нужен:

- PDF лежит по ссылке
- пользователь не загружает файл руками

Какой инструмент:

- `scrape`/PDF parsing через Firecrawl

### 2.5 Re-sync

Когда нужен:

- заново подтянуть источник без удаления документа
- вручную обновить сайт после изменений

Какой инструмент:

- `scrape`
- `batch scrape`
- `crawl`

### 2.6 Delta Sync

Когда нужен:

- обновлять только изменившиеся страницы
- не делать full recrawl каждый раз

Какой инструмент:

- `changeTracking`

### 2.7 Retry Failed URLs

Когда нужен:

- часть страниц упала
- нужно перезапустить только проблемные URL

Какой инструмент:

- `batch scrape`

### 2.8 Browser Fallback

Когда нужен:

- help center закрыт авторизацией
- сайт тяжёлый, JS-only, SPA или с anti-bot особенностями

Какой инструмент:

- `browser`

Это не core-механика, а fallback.

## 3. Что берём в core, а что нет

### Берём в core knowledge ingestion

- `scrape`
- `crawl`
- `map`
- `batch scrape`
- `changeTracking`
- webhooks
- webhook signature verification

### Берём как расширение

- `browser`
- `search`
- `extract`

### Не используем как core-механику KB

- `agent`
- live web `search` как основной источник знаний

Причина:

- они полезны, но относятся уже к research/automation, а не к контролируемому knowledge ingestion.

## 4. Что уже есть в проекте

Текущий код уже умеет базовую Firecrawl-интеграцию:

- если настроен Firecrawl, URL-документы идут через него
- если Firecrawl недоступен, используется простой локальный crawl
- PDF upload живёт отдельным пайплайном через OpenAI Files API

Ключевые точки в коде:

- [enterprise/app/services/captain/tools/firecrawl_service.rb](/root/crafty/onelink/chatwoot/enterprise/app/services/captain/tools/firecrawl_service.rb)
- [enterprise/app/jobs/captain/documents/crawl_job.rb](/root/crafty/onelink/chatwoot/enterprise/app/jobs/captain/documents/crawl_job.rb)
- [enterprise/app/controllers/enterprise/webhooks/firecrawl_controller.rb](/root/crafty/onelink/chatwoot/enterprise/app/controllers/enterprise/webhooks/firecrawl_controller.rb)
- [enterprise/app/jobs/captain/tools/firecrawl_parser_job.rb](/root/crafty/onelink/chatwoot/enterprise/app/jobs/captain/tools/firecrawl_parser_job.rb)
- [enterprise/app/jobs/captain/documents/response_builder_job.rb](/root/crafty/onelink/chatwoot/enterprise/app/jobs/captain/documents/response_builder_job.rb)

Текущая схема:

1. Создаётся документ по URL
2. `CrawlJob` выбирает Firecrawl или fallback crawl
3. Firecrawl присылает `crawl.page`
4. Страница сохраняется как `Captain::Document`
5. Из документа генерируются FAQ
6. FAQ сохраняются как `Captain::AssistantResponse`
7. На FAQ строятся embeddings
8. Ассистент ищет по embeddings через `search_documentation`

Это правильная база. Менять нужно не core-архитектуру, а слой импорта и его UX.

### 4.1 Что ещё не закрыто в текущей интеграции

Сейчас интеграция в коде остаётся базовой и частично "переходной":

- [enterprise/app/services/captain/tools/firecrawl_service.rb](/root/crafty/onelink/chatwoot/enterprise/app/services/captain/tools/firecrawl_service.rb) умеет только `crawl`, но не даёт единого слоя для `scrape`, `map`, `batch scrape`, `status`, `errors`
- [enterprise/app/controllers/enterprise/webhooks/firecrawl_controller.rb](/root/crafty/onelink/chatwoot/enterprise/app/controllers/enterprise/webhooks/firecrawl_controller.rb) принимает только `crawl.page` и пока валидирует query-token, а не полноценную HMAC signature по raw body
- [enterprise/app/jobs/captain/tools/firecrawl_parser_job.rb](/root/crafty/onelink/chatwoot/enterprise/app/jobs/captain/tools/firecrawl_parser_job.rb) сохраняет только `markdown/title/url` и не ведёт `job_id`, прогресс, ошибки, режим импорта
- текущий UI документов не показывает import lifecycle: `queued / processing / completed / failed / changed`
- нет native-сценариев `Selected pages import`, `PDF URL`, `Re-sync`, `Delta sync`, `Retry failed URLs`

Значит, правильный путь не "переписать Captain", а аккуратно расширить текущую интеграцию до полноценного ingestion layer.

## 5. Рекомендуемая архитектура

### 5.1 Single page

Поток:

1. пользователь вводит URL
2. backend делает `scrape` с `formats: ["markdown"]`
3. создаётся `Captain::Document`
4. ставится `status: available`
5. запускается `ResponseBuilderJob`

### 5.2 Site import

Поток:

1. пользователь вводит root URL
2. backend запускает `crawl`
3. страницы приходят через webhook
4. каждая страница нормализуется в отдельный `Captain::Document`
5. по каждой странице строятся FAQ
6. FAQ попадают в embeddings-индекс

### 5.3 Selected pages import

Поток:

1. пользователь вводит root URL
2. backend делает `map`
3. UI показывает найденные URL
4. пользователь выбирает нужные
5. backend делает `batch scrape`
6. выбранные страницы сохраняются как документы

Это лучший UX для реального бизнеса.

### 5.4 Remote PDF URL import

Поток:

1. пользователь вставляет URL на PDF
2. Firecrawl парсит PDF как источник контента
3. markdown сохраняется в `Captain::Document`
4. дальше идёт стандартный FAQ pipeline

Это нужно отделять от upload-PDF:

- upload-PDF = текущий OpenAI Files pipeline
- PDF URL = Firecrawl ingestion

### 5.5 Re-sync и delta sync

Поток:

1. пользователь жмёт `Re-sync` или срабатывает расписание
2. backend использует сохранённый import profile
3. через `changeTracking` определяется, что реально поменялось
4. обновляются только изменённые страницы
5. перегенерируются только связанные FAQ

### 5.6 Надёжная модель данных

Для минимально-инвазивной первой итерации достаточно не добавлять новые таблицы, а хранить import state в `Captain::Document.metadata`.

Это подходит для:

- `Single page`
- `Site import`
- `Selected pages`
- `PDF URL`
- `Re-sync`
- `Delta sync`

Если позже понадобится история отдельных запусков, аудит и ручной replay, тогда уже можно вводить отдельную сущность вроде `Captain::DocumentImportRun`. Но не раньше.

## 6. Какой UI нужен Captain

### На форме создания источника

Нужны режимы:

- `Single page`
- `Site import`
- `Selected pages`
- `PDF URL`
- `PDF upload`

Нужен `Advanced` блок:

- `Include paths`
- `Exclude paths`
- `Allow subdomains`
- `Ignore query params`
- `Only main content`
- `Max pages`

### На списке документов

Нужно показывать:

- `source mode`
- `status`
- `pages processed / total`
- `last synced at`
- `last error`
- `related FAQ count`

Нужны действия:

- `Re-sync`
- `Retry failed`
- `Cancel import`
- `Refresh changed only`

### Для selected pages

Нужен preview экран:

- список URL
- поиск
- фильтр по path
- чекбоксы
- `select all`
- `import selected`

## 7. Что хранить в данных

Для Firecrawl-источников удобно хранить в `Captain::Document.metadata`:

```json
{
  "firecrawl": {
    "provider": "firecrawl",
    "mode": "crawl",
    "source_type": "url",
    "job_id": "fc-job-id",
    "import_profile": {
      "include_paths": ["/docs", "/help"],
      "exclude_paths": ["/blog", "/changelog"],
      "sitemap": "include",
      "ignore_query_parameters": true,
      "only_main_content": true
    },
    "sync": {
      "status": "processing",
      "pages_total": 0,
      "pages_processed": 0,
      "last_synced_at": null,
      "last_error": null
    }
  }
}
```

Это даст:

- наблюдаемость
- идемпотентность
- повторяемость импорта
- базу для delta sync
- нормальный UI прогресса

## 8. Практические дефолты

Для большинства knowledge base сайтов:

```json
{
  "sitemap": "include",
  "crawlEntireDomain": false,
  "allowSubdomains": false,
  "ignoreQueryParameters": true,
  "maxDiscoveryDepth": 4,
  "onlyMainContent": true
}
```

Почему:

- `sitemap: include` даёт хорошее покрытие
- `ignoreQueryParameters: true` режет дубли
- `onlyMainContent: true` уменьшает шум
- `crawlEntireDomain: false` защищает от случайного ухода в маркетинговый мусор

## 9. Надёжность и безопасность

Обязательно:

- использовать webhooks
- проверять `X-Firecrawl-Signature`
- проверять подпись по raw request body, а не по уже распарсенным params
- логировать `job_id`, `assistant_id`, `account_id`, `root_url`
- делать идемпотентность на нашей стороне
- хранить прогресс импорта
- сохранять результаты async jobs сразу, потому что у Firecrawl они не являются вечным хранилищем
- считать webhook delivery как at-least-once и спокойно переживать повторы

Желательно:

- fallback на простой crawl только как резервный режим
- retry только по failed URLs
- refresh делать дельтами, а не full rebuild
- для `scrape` контролировать кэш-поведение только там, где это действительно нужно продукту

## 10. Порядок внедрения

1. Привести `scrape/crawl/map/batch` к одному продуманному UX.
2. Добавить `Selected pages import`.
3. Добавить `status/progress/error UI`.
4. Добавить `Re-sync`.
5. Добавить `changeTracking` и delta sync.
6. Добавить `PDF URL`.
7. Добавить `browser fallback` для тяжёлых источников.

### 10.1 Практический план по проекту

#### Этап 1. Backend ingestion layer

Файлы-кандидаты:

- [enterprise/app/services/captain/tools/firecrawl_service.rb](/root/crafty/onelink/chatwoot/enterprise/app/services/captain/tools/firecrawl_service.rb)
- [enterprise/app/jobs/captain/documents/crawl_job.rb](/root/crafty/onelink/chatwoot/enterprise/app/jobs/captain/documents/crawl_job.rb)
- [enterprise/app/controllers/enterprise/webhooks/firecrawl_controller.rb](/root/crafty/onelink/chatwoot/enterprise/app/controllers/enterprise/webhooks/firecrawl_controller.rb)
- [enterprise/app/jobs/captain/tools/firecrawl_parser_job.rb](/root/crafty/onelink/chatwoot/enterprise/app/jobs/captain/tools/firecrawl_parser_job.rb)

Что сделать:

- дать сервису единый API: `scrape`, `map`, `crawl`, `batch_scrape`, `crawl_status`, `batch_status`, `errors`
- перевести webhook на signature verification
- нормализовать payload в единый internal shape
- сохранять `job_id`, `mode`, `root_url`, `sync.status`, `pages_total`, `pages_processed`, `last_error`

#### Этап 2. Captain documents UX

Файлы-кандидаты:

- [app/javascript/dashboard/components-next/captain/pageComponents/document/DocumentForm.vue](/root/crafty/onelink/chatwoot/app/javascript/dashboard/components-next/captain/pageComponents/document/DocumentForm.vue)
- [app/javascript/dashboard/components-next/captain/pageComponents/document/CreateDocumentDialog.vue](/root/crafty/onelink/chatwoot/app/javascript/dashboard/components-next/captain/pageComponents/document/CreateDocumentDialog.vue)
- [app/javascript/dashboard/components-next/captain/assistant/DocumentCard.vue](/root/crafty/onelink/chatwoot/app/javascript/dashboard/components-next/captain/assistant/DocumentCard.vue)
- [app/javascript/dashboard/routes/dashboard/captain/documents/Index.vue](/root/crafty/onelink/chatwoot/app/javascript/dashboard/routes/dashboard/captain/documents/Index.vue)

Что сделать:

- добавить режимы `Single page`, `Site import`, `Selected pages`, `PDF URL`, `PDF upload`
- для `Selected pages` сделать preview после `map`
- на карточках и в списке показать `status`, `progress`, `last sync`, `error`
- добавить действия `Re-sync`, `Retry failed`, `Refresh changed only`

#### Этап 3. FAQ refresh pipeline

Файлы-кандидаты:

- [enterprise/app/jobs/captain/documents/response_builder_job.rb](/root/crafty/onelink/chatwoot/enterprise/app/jobs/captain/documents/response_builder_job.rb)
- [enterprise/app/models/captain/document.rb](/root/crafty/onelink/chatwoot/enterprise/app/models/captain/document.rb)
- [enterprise/app/models/captain/assistant_response.rb](/root/crafty/onelink/chatwoot/enterprise/app/models/captain/assistant_response.rb)

Что сделать:

- при delta sync пересобирать FAQ только по реально изменившимся документам
- не перегенерировать embeddings по документам, которые не менялись
- иметь явную стратегию dedupe для `external_link`

#### Этап 4. Наблюдаемость и эксплуатация

Что сделать:

- логировать import lifecycle
- различать `queued`, `processing`, `completed`, `failed`, `partial`
- показывать оператору, почему импорт пустой: `blocked`, `empty`, `parse_failed`, `webhook_failed`
- иметь безопасный fallback на текущий простой crawl

### 10.2 Критерии готовности

Фича считается сделанной, когда:

- можно импортировать одну страницу, сайт целиком и выбранные страницы
- можно обновить уже существующий источник без удаления документа
- можно загрузить PDF по ссылке
- UI показывает прогресс и понятную ошибку
- повторный webhook не создаёт дубликаты
- runtime ассистента не меняется и продолжает отвечать только через Captain FAQ/embeddings

## 11. Короткий итог

Firecrawl нужен проекту не как “умный ответчик”, а как надёжный ingestion engine для базы знаний.

Если свести всё к самому важному, то для Captain должны быть первыми:

1. `Single page import`
2. `Site import`
3. `Selected pages import`
4. `Re-sync`
5. `Delta sync`
6. `PDF URL`

Именно это даст максимальный продуктовый эффект, останется нативным текущей архитектуре и не сломает runtime ассистента.

## 12. Источники

- <https://docs.firecrawl.dev/features/scrape>
- <https://docs.firecrawl.dev/features/crawl>
- <https://docs.firecrawl.dev/features/batch-scrape>
- <https://docs.firecrawl.dev/api-reference/endpoint/map>
- <https://docs.firecrawl.dev/features/change-tracking>
- <https://docs.firecrawl.dev/features/browser>
- <https://docs.firecrawl.dev/webhooks/security>
