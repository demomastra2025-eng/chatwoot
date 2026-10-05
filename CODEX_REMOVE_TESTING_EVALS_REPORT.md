# Отчёт: удаление Captain «Тестирование»

Ветка `codex/remove-testing-evals` создана от `rc/e-stage2` (`48990f08fdf86f61199dbf681df80255fab28321`). Изменения находятся только в этой рабочей копии; push, PR и merge не выполнялись.

## Удалено

- Страница `captain/evaluations`, её frontend route `captain_evaluations_index`, API-клиент, sidebar-пункт, backend route и `EvaluationsController` с endpoint-ами `show`, `run`, `run_status`, `import_conversation`, `run_dataset`, `red_team`.
- `Llm::EvalRun`, `Llm::Evals::RunJob` и их тесты.
- Eval-only framework в `lib/llm/evals` и `enterprise/lib/captain/evals`, кроме ядра ReleaseCheck; связанный rake task, Tribunal initializer, test helper, suite/config/specs и workflow `.github/workflows/captain_ai_evals.yml`.
- Eval-only наборы в `config/llm_evals`: удалены остальные YAML, dataset и шесть eval fixtures. Gem `ruby_llm-tribunal` удалён из `Gemfile` и `Gemfile.lock`; его единственная зависимость `ruby_llm` остаётся. Обновлены `example/rubyllm_library/README.md` и `adoption_matrix.md`.
- В русской локали удалены `SIDEBAR.CAPTAIN_EVALUATIONS` и блок `CAPTAIN.EVALUATIONS.*`. Тест Sidebar оставлен и переименован так, чтобы он проверял только скрытие «Расходов» у сотрудников.

Удалено 111 tracked-файлов. Тесты удалённой страницы, API, job, модели и eval framework удалены вместе с соответствующим кодом.

## Оставлено

- Ядро ReleaseCheck: шесть классов `Llm::Evals` (`ModerationSuite`, `OfflineModerationRuntime`, `MethodStub`, `CaseLoader`, `Result`, `CollectionResult`), `Captain::Evals::ToolSafetySuite` и `ConversationCompletionSuite`, а также пять соответствующих specs.
- YAML `moderation.yml`, `tool_safety.yml`, `conversation_completion.yml` и fixture `customer_support_basic_no_tool.json`, которую использует `event_bus_callbacks_spec.rb`.
- Observability route/UI, вкладка «Оценки», `Llm::ReleaseCheck`, `AlertNotifier` и `rake llm:release_check`. Общие живые `Llm::*` и `Captain::*` классы не менялись.
- Таблица `llm_eval_runs`, обе миграции и `db/schema.rb`; миграций и удаления данных нет. `config/brakeman.ignore` не менялся.
- Английские и казахские строки локали оставлены согласно заморозке en/kk. `translationKeys.knownMissing.json` тоже оставлен: guard не требует его менять после удаления source-ключей. Старые значения пользовательского sidebar key `Captain:Evaluations` останутся неиспользуемыми.

## Решения и открытые вопросы

- По указанию владельца сохранена Observability вкладка «Оценки» и её live/deterministic ReleaseCheck. Это отдельная часть страницы «Логи».
- Production fixture оставлена на прежнем пути, чтобы не менять сохраняемый `event_bus_callbacks_spec.rb`.
- Проверка ссылок на исходном SHA подтвердила, что `ruby_llm-tribunal` используется только удаляемым controller/eval-кодом, initializer, helper, spec, Gemfile/lockfile, workflow и двумя обновлёнными example-документами. Упоминания в `.hermes/plans/` — исторические и оставлены.
- Удаление `.github/workflows/captain_ai_evals.yml` убирает PR gate с `llm:evals:ci`, strict Tribunal dataset и его eval specs. В качестве небольшой замены предлагаю specs, которые запускают сохранённые реальные `moderation.yml` и `tool_safety.yml`; они не добавлены, так как Ruby suite недоступен для проверки в этой среде.
- До выкладки оператору нужно отдельно проверить очередь Sidekiq `low` на ожидающие `Llm::Evals::RunJob` и строки `llm_eval_runs` со статусами `queued`/`running`. DEV/PROD, Redis и базы здесь не проверялись и не открывались. Также не проверялось, требуется ли удалить `Captain AI Evals` из внешних branch-protection checks; настройки GitHub в репозитории не видны.
- Переменные `LLM_EVALS_*` в коде больше не используются. Значения окружения DEV/PROD не проверялись; если они заданы вне репозитория, они станут неактивны.

## Проверки

- Vitest: captain routes, `Sidebar.spec.js`, `sidebarVisibility.spec.js` и все i18n specs — **10 файлов, 95 тестов прошли**, включая `translationKeys.spec.js`. Вывод содержал предупреждение об устаревшей базе Browserslist и Vue test-stub warnings, без падений.
- ESLint: четыре изменённых JS/Vue-файла — **0 errors, 98 warnings** по `@intlify/vue-i18n/no-missing-keys`. Независимый запуск на чистой базе дал 99 warnings; все предупреждения оставлены без подавления.
- Оба изменённых русских JSON-файла успешно разобраны `ConvertFrom-Json`.
- Prism 1.9 parser для изменённых `Gemfile` и `config/routes.rb` — **2 файла, 0 ошибок**. `git diff --check` прошёл.
- Сверка diff подтвердила отсутствие изменений в `db/`, `config/brakeman.ignore` и `db/migrate`; grep по исходному SHA подтвердил область использования Tribunal.
- Не выполнены `bundle lock`, RSpec, RuboCop, Brakeman и `rails zeitwerk:check`: в среде нет Ruby/Bundler, Docker или WSL. Поэтому результат Brakeman и загрузку Rails/lockfile следует подтвердить в release-проверке.

## Коммиты

- `7e4b392ab` — `Remove the Captain evaluations UI`
- `91ac35e2a` — `Remove the Captain evaluations API`
- `a704fafe1` — `Remove the offline evaluation framework`

Каждый коммит содержит trailer `Co-Authored-By: OpenAI Codex <noreply@openai.com>`.
