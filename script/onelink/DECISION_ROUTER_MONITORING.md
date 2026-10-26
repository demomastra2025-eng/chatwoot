# Маршрутизатор агентов: проверка после выкладки и мониторинг

Решение владельца (25.10): маршрутизатор (`Captain::Runtime::DecisionRouter`) единственная логика выбора агента. У него нет
выключателя и нет запасного пути на старую передачу диалога через LLM: если все модели решений недоступны, ход
клиники с двумя и более агентами не выполняется (живой диалог уходит сотруднику, подсказка «Предложить ответ» заканчивается
ошибкой `router_unavailable`). Поэтому после каждой выкладки проверьте цепочку, а в работе следите за сигналами ниже.

Цепочка: `perplexity/pplx-decider-v1.2` -> `inception/mercury-decide` -> `microsoft/microsoft-decision-1`
(строка `CAPTAIN_AGENT_ROUTING_MODELS`). Решение владельца 26.10: решает самый вероятный ответ ответившей модели (route_mode с
наибольшей вероятностью; агент — с наибольшей вероятностью include, консилиум — агенты с вероятностью от 0,5). Порога уверенности
и модели эскалации нет; следующая модель цепочки отвечает только при сбое или таймауте предыдущей. Строки
`CAPTAIN_AGENT_ROUTING_MIN_CONFIDENCE`, `..._ESCALATION_*`, `..._BOUNCE_ESCALATION` больше не читаются.

## 1. Проверка после выкладки

В контейнере Rails:

```
bundle exec rake captain:router_smoke [ACCOUNT_ID=<id>]
```

Один настоящий вызов на каждую модель цепочки (каждая модель отдельно, те же вопросы, что задаёт маршрутизатор) на синтетическом ходе (два выдуманных агента, выдуманное сообщение). Строка на модель: роль, модель, `ok` с
решением или `fail` с классом ошибки, задержка в мс. Ключи, промпты и тексты не печатаются. Код выхода 1, если хоть одна
строка `fail`: одна упавшая модель цепочки ещё не останавливает ходы (решает следующая), но её нужно разобрать до того, как
упадёт следующая. По умолчанию проверяется каждый аккаунт, который маршрутизирует (у его канала два и больше агентов-кандидатов),
от его собственного ключа OpenRouter и бюджета: зелёная проверка значит, что маршрутизировать может каждая клиника; `ACCOUNT_ID`
проверяет один аккаунт. Вызовы записываются как обычные события решений этого аккаунта (`llm.decision.complete`) и тратят его бюджет (доли цента на аккаунт).

## 2. Сигналы

Все запросы читают `llm_events`; подставьте период.

Подсказки, которые не получились из-за маршрутизатора (`error_code` `router_unavailable` — не ответила ни одна модель решений, `council_unavailable` — не собрался консилиум; в `detail` код сбоя `agent_router: <reason>`):

```sql
SELECT date_trunc('hour', created_at) AS hour, payload->>'error_code' AS code, payload->>'detail' AS detail, count(*)
FROM llm_events
WHERE event_name = 'captain.reply_suggestion.complete' AND feature = 'reply_suggestion'
  AND (payload->>'detail' LIKE 'agent_router%' OR payload->>'error_code' IN ('router_unavailable', 'council_unavailable'))
  AND created_at > now() - interval '24 hours'
GROUP BY 1, 2, 3 ORDER BY 1 DESC;
```

Отказы маршрутизатора во всех ходах (живые диалоги и подсказки; `reason`: `decision_chain_unavailable`,
`decision_unresolved`; коды `escalation_*` остались только в старых событиях до 26.10; `models_tried` — какие модели пробовали).
`reason` хранится в колонке `llm_events.reason`, не в `payload`:

```sql
SELECT date_trunc('hour', created_at) AS hour, payload->>'run_source' AS run_source, reason,
       payload->'models_tried' AS models_tried, count(*)
FROM llm_events
WHERE event_name = 'captain.agent.routing_failed' AND created_at > now() - interval '24 hours'
GROUP BY 1, 2, 3, 4 ORDER BY 1 DESC;
```

Какая модель решает и задержка (`run_source` `reply_suggestion` — подсказки, `live` — диалоги; `default_to` есть только у
событий до 26.10):

```sql
SELECT payload->>'run_source' AS run_source, payload->>'decided_by' AS decided_by, payload->>'chain_position' AS position,
       payload->>'default_to' AS default_to, count(*),
       percentile_cont(0.5) WITHIN GROUP (ORDER BY (payload->>'latency_total_ms')::int) AS p50_ms,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY (payload->>'latency_total_ms')::int) AS p95_ms
FROM llm_events
WHERE event_name = 'captain.agent.routed' AND created_at > now() - interval '24 hours'
GROUP BY 1, 2, 3, 4 ORDER BY 5 DESC;
```

Пороги для тревоги: любой `routing_failed` за час; `chain_position` > 1 больше чем у 20 % решений (голова цепочки
деградирует); p95 `latency_total_ms` выше 20 000 (цепочка на пределе); у подсказок `error_code = 'timeout'` при
`detail LIKE 'deadline_at_routing%'` (подсказка не дождалась решения).

## 3. Бюджет подсказки

Подсказка клиники с двумя и более агентами начинается со 120 с (`CAPTAIN_SUGGESTION_ROUTER_BUDGET_SECONDS`, 30–180), с одним
агентом — 60 с (`CAPTAIN_SUGGESTION_BUDGET_SECONDS`). Когда маршрутизатор выбрал одного агента или сотрудника, от решения
остаётся бюджет одного агента (60 с). Консилиум сохраняет 120 с: его части идут параллельно (без свободного потока — по
очереди), и у них свой срок — за 18 с до конца подсказки, чтобы успел редактор. Часть, которая не уложилась (медленная модель,
цепочка зависимых частей, повторный запуск после нового решения маршрутизатора), останавливается как техническая ошибка этой
части: подсказка отвечает остальными частями и называет менеджеру остановленную. Повторное решение для части «не моё»
принимается, только пока успевают маршрутизатор и короткий запуск (36,5 с).
