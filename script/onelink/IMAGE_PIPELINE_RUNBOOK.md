# Картинки клиентов: описание при получении, роутер и два чтеца

Решения владельца: 07.10 (агент видит только текст картинки), 27.10 («Хорошо. Согласен.» на роутер и двух чтецов).
Код: `Captain::ImageRecognitionService` (кеш и «один вызов на картинку»), `Captain::ImageReading::{Picture, Router, Reader, Prompt}`,
`Messages::ImageDescriptionJob` (описание при получении), `Captain::OpenAiMessageBuilderService` (что видит агент).

## 1. Как это работает

1. Картинка пришла в диалог агента: `Messages::ImageDescriptionJob` описывает её в фоне. Подсказка или живой ответ находят текст в
   `attachments.meta` и не ждут. Если текста ещё нет, запуск описывает картинку сам, один раз (замок в Redis: два вызова на одну картинку не идут).
2. Картинка читается один раз: оригинал берётся из хранилища (внешняя ссылка канала, если файла нет, идёт через `SafeFetch`). Длинная
   сторона больше 1536 px: ужимается до 1536 в JPEG (libvips, качество 85); не больше 1536 px и тип jpeg/png/webp: уходит как есть.
3. Роутер (модель решений, картинка 1024 px JPEG data-URL в состоянии) отвечает на один вопрос: есть ли значимый рукописный текст.
   P(рукописный) не ниже 0.3 или роутер не ответил: читает модель рукописного текста. Иначе обычная модель.
4. Чтец получает универсальную инструкцию (без слов про отрасль; строка «Сфера компании: …» берётся из `accounts.custom_attributes['industry']`,
   если она заполнена) и картинку данными в запросе, не ссылкой. Ответ до 2500 токенов (запас на рассуждение Terra); температура 0 только
   там, где модель её принимает.
5. Текст и чтец сохраняются в `attachments.meta`: `image_recognition_description`, `image_recognition_reader` (`ordinary` или
   `handwriting`), `image_recognition_model`.
6. Агент (подсказка, живой запуск, консилиум, рассылки) **никогда** не получает картинку: ни пикселей, ни ссылки. Он видит только
   «Image attachment (automatic description, it may be inaccurate): …».

## 2. Настройки (Super Admin, «Модели ИИ», группа «Картинки»), одинаковые для всех аккаунтов

| Строка | Что | Пусто значит |
|---|---|---|
| `CAPTAIN_IMAGE_RECOGNITION_MODEL` | обычный чтец | `google/gemini-3.1-flash-lite` |
| `CAPTAIN_IMAGE_HANDWRITING_MODEL` | чтец рукописного текста (и при ошибке роутера) | `openai/gpt-6.1-terra` |
| `CAPTAIN_IMAGE_ROUTER_MODEL` | модель решений роутера | `perplexity/pplx-decider-v1.2` |

Эти функции больше не идут за `CAPTAIN_DEFAULT_MODEL` (Luna): смена модели агента не двигает чтение картинок. Моделей-запасных нет.
Модель вне Google / OpenAI / Perplexity форма не примет, а если её всё же записали, запрос не строится (картинка получит текст
«распознавание недоступно»).

Провайдеры OpenRouter (`provider.only`): Gemini: `google-vertex`, `google-ai-studio`; Terra и другие OpenAI: `openai`, `azure`;
роутер: `perplexity`. Остальное (`data_collection: deny`) как у всех запросов.

## 3. Журнал

Одна строка `llm_events` на чтение картинки: `event_name = 'captain.image.read'`, `feature = 'image_recognition'`, `model` (чтец),
`duration_ms` (всё чтение), в `payload`: `reader`, `reader_ms`, `router_status` (`ok`/`failed`), `router_model`, `router_choice`,
`router_probability`, `router_ms`, `router_error_class`, `reader_usage` (`input_tokens`, `output_tokens`), `router_cost` (по ответу
провайдера), `reader_cost` (оценка по цене из каталога, пусто, пока в каталоге нет цены модели), `total_cost`. Токены и доллары лежат
только в `payload` (токены вложенным объектом: журнал закрывает ключ со словом token), не в колонках `prompt_tokens`/`estimated_cost`: их суммируют панели, а вызовы уже посчитаны на своих строках
(`llm.decision.complete` с `feature = 'image_routing'` для роутера и обычное событие чата с `feature = 'image_recognition'` для чтеца),
вторая запись тех же долларов удвоила бы расход на картинки. Картинок, ссылок на них и прочитанного текста в событиях нет.

```sql
-- доля картинок по чтецам и задержка за сутки
SELECT payload->>'reader' AS reader, count(*), round(avg(duration_ms)) AS avg_ms,
       count(*) FILTER (WHERE payload->>'router_status' = 'failed') AS router_failed
FROM llm_events WHERE event_name = 'captain.image.read' AND created_at > now() - interval '1 day' GROUP BY 1;
```

## 4. Откат

Только данные, кода менять не нужно: в Super Admin поставить `CAPTAIN_IMAGE_RECOGNITION_MODEL` и `CAPTAIN_IMAGE_HANDWRITING_MODEL` на
`openai/gpt-6-luna` (роутер при этом всё равно вызывается; чтобы не платить за него, оба чтеца можно сделать одинаковыми, роутер дешёвый:
$0.02 за 1000 картинок). Описание при получении выключает переменная `CAPTAIN_IMAGE_DESCRIPTION_ON_ARRIVAL=off`.
