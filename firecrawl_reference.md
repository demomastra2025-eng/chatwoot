# Firecrawl v2 Reference

Этот файл хранит полный технический reference по Firecrawl для команды.

Он нужен как низкоуровневое дополнение к:

- [firecrawl.md](/root/crafty/onelink/chatwoot/firecrawl.md)
- [api_firecrawl.md](/root/crafty/onelink/chatwoot/api_firecrawl.md)

Основной принцип:

- `firecrawl.md` отвечает на вопрос "что мы строим"
- `api_firecrawl.md` отвечает на вопрос "какими ручками пользоваться"
- `firecrawl_reference.md` отвечает на вопрос "какие именно возможности и нюансы есть у Firecrawl"

## 1. Общая картина

Firecrawl `v2` для нас распадается на:

- `scrape`
- `crawl`
- `map`
- `batch scrape`
- `search`
- `extract`
- `agent`
- `browser`

Системные блоки:

- webhooks
- webhook security
- async jobs
- status/errors endpoints
- watcher/websocket для crawl
- privacy/enterprise режимы

## 2. Конфигурация в нашем проекте

Предпочтительная конфигурация:

```env
FIRECRAWL_API_URL=https://minio.cloud.vconsult.kz/v2
FIRECRAWL_API_KEY=<token>
```

В коде:

- сначала читается `FIRECRAWL_API_KEY`
- потом fallback на `CAPTAIN_FIRECRAWL_API_KEY`
- URL берётся из `FIRECRAWL_API_URL`

Текущие точки интеграции:

- [enterprise/app/services/captain/tools/firecrawl_service.rb](/root/crafty/onelink/chatwoot/enterprise/app/services/captain/tools/firecrawl_service.rb)
- [enterprise/app/jobs/captain/documents/crawl_job.rb](/root/crafty/onelink/chatwoot/enterprise/app/jobs/captain/documents/crawl_job.rb)
- [enterprise/app/helpers/captain/firecrawl_helper.rb](/root/crafty/onelink/chatwoot/enterprise/app/helpers/captain/firecrawl_helper.rb)
- [enterprise/app/controllers/enterprise/webhooks/firecrawl_controller.rb](/root/crafty/onelink/chatwoot/enterprise/app/controllers/enterprise/webhooks/firecrawl_controller.rb)

Текущий practical gap:

- env и `v2` base URL уже поддержаны
- но сервисный слой пока не покрывает весь рабочий набор `scrape/map/batch/status/errors`
- webhook security пока логичнее перевести с token-query на signature verification
- parser job пока не хранит полноценный import lifecycle

## 3. Общие response patterns

### Синхронный response

Типичен для `scrape`, `map`, иногда `search`.

Обычно выглядит как:

- `success`
- `data`
- `metadata`

### Асинхронный job response

Типичен для:

- `crawl`
- `batch scrape`
- `extract`
- `agent`

Обычно даёт:

- `id`
- `status`
- `url` или status endpoint

### Status response

Для async jobs обычно есть:

- `status`
- `completed`
- `total`
- `creditsUsed`
- `data`
- `next`

Практический вывод:

- async result retrieval нужно закладывать сразу в архитектуру
- не стоит завязывать продукт только на webhook, полезен и status polling fallback

### Errors response

Для долгих jobs обычно есть отдельный endpoint ошибок:

- failed URLs
- parse errors
- robots blocked

## 4. `scrape`

### Назначение

Одна страница, синхронно.

### Что умеет вернуть

- `markdown`
- `summary`
- `html`
- `rawHtml`
- `links`
- `images`
- `json`
- `branding`
- `screenshot`
- `attributes`
- `changeTracking`

### Actions

Поддерживаемые действия:

- `wait`
- `click`
- `write`
- `press`
- `scroll`
- `screenshot`
- `scrape`
- `executeJavascript`
- `pdf`

### Когда подходит

- одна docs-страница
- pricing page
- одна статья help center
- remote PDF URL
- re-sync одной страницы

### Пример

```bash
curl -X POST "$FIRECRAWL_API_URL/scrape" \
  -H "Authorization: Bearer $FIRECRAWL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://enis.kz","formats":["markdown"]}'
```

## 5. `crawl`

### Назначение

Полный обход сайта.

### Ключевые параметры

- `url`
- `includePaths`
- `excludePaths`
- `maxDiscoveryDepth`
- `limit`
- `crawlEntireDomain`
- `allowSubdomains`
- `ignoreQueryParameters`
- `sitemap`
- `delay`
- `maxConcurrency`
- `scrapeOptions`

### Сопутствующие возможности

- `params-preview`
- `status`
- `errors`
- `watcher/WebSocket`
- webhooks

### Когда подходит

- полный импорт docs/help center
- onboarding ассистента по сайту клиента
- автоматический импорт сайта знаний

## 6. `map`

### Назначение

Discovery URL без полноценного ingest.

### Что полезно знать

- может работать через sitemap
- умеет `search`
- возвращает `url`, `title`, `description`
- полезен как первая стадия `preview -> select -> import`

### Когда подходит

- selected pages import
- preview перед импортом сайта
- inventory URL

## 7. `batch scrape`

### Назначение

Обработка массива известных URL.

### Что полезно знать

- принимает список `urls`
- принимает `scrapeOptions`
- работает асинхронно
- поддерживает webhooks
- поддерживает status/errors

### Когда подходит

- импорт выбранных пользователем страниц
- retry failed URLs
- точечный re-sync

## 8. `search`

### Назначение

Веб-поиск, а не KB-ingestion.

### Источники

- `web`
- `news`
- `images`

### Категории

- `github`
- `research`
- `pdf`

### Важный нюанс

`search` может не только искать, но и сразу скрейпить найденные результаты.

### Когда подходит

- copilot/research
- конкурентный анализ
- поиск внешних PDF

### Когда не подходит

- как основа базы знаний Captain

## 9. `extract`

### Назначение

Structured extraction.

### Что умеет

- `prompt`
- `schema`
- множественные URL
- web search

### Когда подходит

- enrichment metadata
- controlled extraction

### Когда не подходит

- как основной KB pipeline

## 10. `agent`

### Назначение

Агентный сбор данных без заранее известных URL.

### Что умеет

- искать
- переходить
- собирать данные
- строить structured output

### Когда подходит

- сложный research
- vendor/company analysis
- enrichment

### Когда не подходит

- для стандартного docs/help center ingestion

## 11. `browser`

### Назначение

Удалённые браузерные сессии.

### Что умеет

- создать session
- выполнять `node`, `python`, `bash`
- работать через CDP/WebSocket
- поддерживать live view
- хранить browser profiles
- работать со скачанными файлами

### Когда подходит

- login-gated help center
- тяжёлые SPA
- нестандартные customer portals

## 12. Webhooks

### Где есть

- `crawl`
- `batch scrape`
- `extract`
- `agent`

### Что важно

- webhook лучше polling для продовых import pipelines
- нужно хранить `job_id` и прогресс
- нужно строить идемпотентность на нашей стороне
- webhook delivery нужно считать повторяемой доставкой, а не exactly-once
- часть жизненного цикла удобно отражать событиями `started/page/completed/failed`

## 13. Webhook security

Нужно проверять:

- `X-Firecrawl-Signature`
- raw request body
- HMAC до любого изменения payload на стороне Rails

Для проекта это обязательный production-шаг.

## 14. Async flow

Для async jobs важно учитывать:

- job создаётся отдельно
- status читается отдельно
- ошибки читаются отдельно
- большие результаты могут быть paginated

Operational notes:

- данные async jobs не стоит рассматривать как постоянное хранилище
- важные результаты нужно promptly переносить в наши `Captain::Document`
- полезно иметь reconciliation job, если webhook не дошёл

Для нас это значит, что UI должен уметь показывать:

- `processing`
- `completed`
- `failed`
- `pages processed`
- `last error`

## 15. Privacy и enterprise режимы

Из полезного:

- `zero data retention`

Это важно для чувствительных источников и enterprise клиентов.

## 16. Дефолты для KB сайтов

Рекомендуемый профиль:

```json
{
  "sitemap": "include",
  "crawlEntireDomain": false,
  "allowSubdomains": false,
  "ignoreQueryParameters": true,
  "maxDiscoveryDepth": 4,
  "scrapeOptions": {
    "formats": ["markdown"],
    "onlyMainContent": true
  }
}
```

## 17. Как это мапится на Captain

### Single page

- `scrape`

### Site import

- `crawl`

### Selected pages

- `map + batch scrape`

### Delta sync

- `changeTracking`

### PDF URL

- `scrape`/PDF parsing

### Browser fallback

- `browser`

## 18. Что из Firecrawl не должно смешиваться с runtime

Не надо строить ответы ассистента напрямую на:

- `search`
- `agent`

Правильная модель:

- Firecrawl качает контент
- Captain хранит документы
- Captain строит FAQ
- Captain строит embeddings
- Captain отвечает по своим embeddings

## 19. Полезные проектные задачи на будущее

- preview страниц перед импортом
- selected pages import
- status/progress/error UI
- re-sync
- delta sync
- retry failed URLs
- remote PDF URL
- browser fallback

## 20. План внедрения по слоям

### Backend

- расширить `Captain::Tools::FirecrawlService` до полноценного клиента
- нормализовать async lifecycle в metadata документа
- сделать webhook signature verification

### Frontend

- добавить import modes
- добавить preview для `map`
- показать progress/error state

### Runtime safety

- не менять основной pipeline ответа ассистента
- не тащить `search` или `agent` в runtime ответа
- оставлять Firecrawl только в контуре загрузки знаний

## 21. Источники

- <https://docs.firecrawl.dev/api-reference/v2-introduction>
- <https://docs.firecrawl.dev/features/scrape>
- <https://docs.firecrawl.dev/features/crawl>
- <https://docs.firecrawl.dev/features/batch-scrape>
- <https://docs.firecrawl.dev/api-reference/endpoint/map>
- <https://docs.firecrawl.dev/features/search>
- <https://docs.firecrawl.dev/features/extract>
- <https://docs.firecrawl.dev/features/agent>
- <https://docs.firecrawl.dev/features/browser>
- <https://docs.firecrawl.dev/webhooks/overview>
- <https://docs.firecrawl.dev/webhooks/security>
