# Firecrawl v2 API: практический guide для проекта

Этот файл нужен как короткий прикладной guide по новой Firecrawl `v2` API.

Связанные документы:

- [firecrawl.md](/root/crafty/onelink/chatwoot/firecrawl.md) — как использовать Firecrawl в Captain
- [firecrawl_reference.md](/root/crafty/onelink/chatwoot/firecrawl_reference.md) — полный технический reference

## 1. Наша конфигурация

Проект должен читать Firecrawl из env:

```env
FIRECRAWL_API_URL=https://minio.cloud.vconsult.kz/v2
FIRECRAWL_API_KEY=<token>
```

В коде сейчас логика такая:

- сначала читается `FIRECRAWL_API_KEY`
- если env пуст, остаётся fallback на `CAPTAIN_FIRECRAWL_API_KEY` из `InstallationConfig`
- base URL берётся из `FIRECRAWL_API_URL`

## 2. Быстрый выбор endpoint-а

Используй:

- `scrape` — когда нужна одна страница
- `crawl` — когда нужен импорт сайта целиком
- `map` — когда нужен preview URL без импорта контента
- `batch scrape` — когда пользователь уже выбрал конкретные URL
- `changeTracking` — когда нужен delta refresh
- `browser` — когда обычный scrape не справляется

Практическое правило:

- синхронные сценарии делай через `scrape` и `map`
- массовые и длинные сценарии делай через `crawl` и `batch scrape`
- всё, что идёт через async job, сразу привязывай к своему `job_id` и внутреннему import state

Не используй как core KB pipeline:

- `search`
- `agent`

## 3. Рабочие примеры

### 3.1 Single page через `scrape`

```bash
curl -X POST "$FIRECRAWL_API_URL/scrape" \
  -H "Authorization: Bearer $FIRECRAWL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://enis.kz","formats":["markdown"]}'
```

Подходит для:

- одной статьи docs
- одной страницы pricing
- remote PDF URL

### 3.2 Preview страниц через `map`

```bash
curl -X POST "$FIRECRAWL_API_URL/map" \
  -H "Authorization: Bearer $FIRECRAWL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://enis.kz","limit":100,"ignoreQueryParameters":true,"sitemap":"include"}'
```

Подходит для:

- `Selected pages import`
- UX preview перед импортом сайта

### 3.3 Full site import через `crawl`

```bash
curl -X POST "$FIRECRAWL_API_URL/crawl" \
  -H "Authorization: Bearer $FIRECRAWL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "url":"https://enis.kz",
    "limit":100,
    "sitemap":"include",
    "ignoreQueryParameters":true,
    "crawlEntireDomain":false,
    "allowSubdomains":false,
    "scrapeOptions":{"formats":["markdown"],"onlyMainContent":true}
  }'
```

Подходит для:

- docs/help center import
- one-click site onboarding

### 3.4 Selected pages через `batch scrape`

```bash
curl -X POST "$FIRECRAWL_API_URL/batch/scrape" \
  -H "Authorization: Bearer $FIRECRAWL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "urls":[
      "https://enis.kz/page-1",
      "https://enis.kz/page-2"
    ],
    "formats":["markdown"]
  }'
```

Подходит для:

- страниц, выбранных пользователем
- retry failed URLs
- точечного re-sync

### 3.5 Status / results / errors

Для long-running imports нужно учитывать ещё три типа вызовов:

- status endpoint для job state
- results endpoint для данных job
- errors endpoint для failed URLs и parse ошибок

Практически это значит:

- нельзя считать `crawl` или `batch scrape` "одноразовым POST и забыли"
- backend должен сохранять `job_id` сразу после запуска
- результаты job нужно забирать и сохранять к себе без надежды, что Firecrawl будет постоянным storage

## 4. Что реально полезно проекту

### `scrape`

Полезно для:

- single page import
- remote PDF URL
- re-sync одной страницы

Полезные форматы:

- `markdown`
- `summary`
- `json`
- `screenshot`
- `changeTracking`

Практические замечания:

- для KB ingestion по умолчанию брать `markdown`
- `changeTracking` использовать как служебный формат для delta sync, а не как финальное пользовательское содержимое
- для force-refresh учитывать кэш-поведение явно, а не надеяться на поведение по умолчанию

### `crawl`

Полезно для:

- full site import
- knowledge base onboarding

Полезные параметры:

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

### `map`

Полезно для:

- preview/import flow
- выбор страниц
- контроль того, что именно пойдёт в KB

### `batch scrape`

Полезно для:

- selected pages
- точечных повторных импортов
- retry failed URLs

На уровне продукта это лучший инструмент для:

- "импортировать только выбранное"
- "переобновить только сломавшиеся URL"
- "точечно досинхронизировать изменения"

### `changeTracking`

Полезно для:

- delta refresh
- nightly sync
- уменьшения стоимости и шума

### `browser`

Полезно для:

- приватных help center
- тяжёлых SPA
- сайтов с логином

Но это fallback, а не обычный путь.

## 5. Рекомендуемые дефолты для Captain

Для большинства knowledge base сайтов:

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

## 6. Что надо обязательно учесть

### Webhooks

Для `crawl` и `batch scrape` лучше использовать webhook flow, а не только polling.

### Security

Нужно проверять:

- `X-Firecrawl-Signature`
- подпись по raw request body
- соответствие `job_id` и нашего import context

### Async flow

Для больших jobs важно хранить:

- `job_id`
- `status`
- `pages_total`
- `pages_processed`
- `last_error`

Важно помнить:

- async job results у Firecrawl не стоит считать долговременным storage
- webhook delivery может прийти повторно, значит нужен идемпотентный обработчик
- UI не должен зависеть только от webhook: полезно иметь и status polling как страховку

### Current code gap

В проекте сейчас уже есть env-first настройка Firecrawl:

- [enterprise/app/services/captain/tools/firecrawl_service.rb](/root/crafty/onelink/chatwoot/enterprise/app/services/captain/tools/firecrawl_service.rb)

Но runtime пока покрывает только базовый `crawl` flow. Для "новой API по-взрослому" ещё нужно добавить:

- `scrape`
- `map`
- `batch scrape`
- status/errors handling
- raw-body webhook verification

### Idempotency

Нужно не плодить дубли документов, если один и тот же import запустился повторно.

## 7. Что не надо тянуть в core KB

Не делать основой базы знаний:

- `search`
- `agent`
- `extract`

Почему:

- это уже не ingestion-контур KB, а research/enrichment/automation слой

## 8. Что должно получиться в продукте

На уровне Captain после нормальной интеграции должны появиться:

- `Single page import`
- `Site import`
- `Selected pages import`
- `Re-sync`
- `Delta sync`
- `Retry failed URLs`
- `PDF URL`
- `Browser fallback`

## 9. Куда смотреть за деталями

- product/use-case логика: [firecrawl.md](/root/crafty/onelink/chatwoot/firecrawl.md)
- полный технический справочник: [firecrawl_reference.md](/root/crafty/onelink/chatwoot/firecrawl_reference.md)

## 10. Источники

- <https://docs.firecrawl.dev/api-reference/v2-introduction>
- <https://docs.firecrawl.dev/features/scrape>
- <https://docs.firecrawl.dev/features/crawl>
- <https://docs.firecrawl.dev/features/batch-scrape>
- <https://docs.firecrawl.dev/api-reference/endpoint/map>
- <https://docs.firecrawl.dev/features/change-tracking>
- <https://docs.firecrawl.dev/features/browser>
- <https://docs.firecrawl.dev/webhooks/security>
