# Завершение удаления SAML — DEV-only Plan

> **Для Hermes:** выполнять последовательно в родительской сессии; не использовать PROD, commit, push или staging.

**Цель:** довести удаление SAML до проверенного DEV-состояния, изолировать точный scope от чужого WIP и остановиться с незакоммиченным diff.

**Архитектура:** сначала восстановить проверяемость DEV runtime, затем закрыть только подтверждённые остатки SAML и выполнить scoped code/tests/live verification. Generic SSO token flow и Google OAuth считаются отдельными контрактами и сохраняются. PROD полностью исключён из этой итерации.

**Стек:** Rails 7.1, Vue/Vite, RSpec, Vitest, RuboCop, PostgreSQL, Sidekiq, systemd DEV runtime.

---

## Ограничения

- Не обращаться к PROD DB, Redis, API, контейнерам или логам, даже read-only.
- Не запускать PROD deploy/restart/migration.
- Не делать `git add`, commit, push, reset, checkout или изменение истории.
- Не трогать несвязанный dirty WIP.
- Допустимы только локальные/DEV проверки и, если RCA потребует, scoped restart `onelink-chatwoot-dev.service`.
- На момент планирования пользователь подтверждает отсутствие SAML-клиентов; DEV уже показал `saml_users=0`, `saml_settings=0`, SAML Sidekiq jobs=0.

## Task 1: Зафиксировать точный SAML scope

**Цель:** отделить наши изменения от сотен чужих dirty-файлов без staging.

**Файлы/артефакты:**
- Existing artifact: `/tmp/saml-removal-tracked.patch`
- Migration: `db/migrate/20260831223000_remove_saml_sso.rb`
- Create: `/tmp/saml-removal-exact-v2.patch`

**Шаги:**
1. Снять `git status --porcelain=v1` и не изменять индекс.
2. Сформировать новый patch только из SAML hunks; исключить scheduling, LinkedIn, CRM и другие изменения внутри общих locale/schema файлов.
3. Проверить `git diff --check` только по SAML scope.
4. Зафиксировать SHA-256 patch и миграции.

**Ожидаемый результат:** воспроизводимый review artifact без чужого WIP и `staged=0`.

## Task 2: RCA зависшего DEV web

**Цель:** вернуть актуальный HTTP health evidence перед дальнейшей проверкой.

**Пути/runtime:**
- Service: `onelink-chatwoot-dev.service`
- Rails: `127.0.0.1:3002`
- Vite: `127.0.0.1:3037`
- External DEV: `https://dev.one-link.kz`
- Logs: `/root/crafty/logs/chatwoot-dev/` и journald service unit

**Шаги:**
1. Проверить Puma process/port, незавершённые requests, DB/Redis timeout и последние stack traces.
2. Отделить SAML/migration ошибку от общей перегрузки Puma/DB/MCP.
3. Если процесс застрял или содержит старый boot-time OmniAuth middleware, выполнить только DEV restart сервиса.
4. Проверить:
   - `/app/login` локально и через DEV gateway возвращает HTTP 200;
   - `/api/v1/auth/saml_login` отсутствует;
   - в свежих логах нет `PendingMigrationError`, `AccountSamlSettings`, `SamlUserBuilder`, `NOAUTH`.

**Ожидаемый результат:** DEV web отвечает, причина timeout зафиксирована; PROD не затронут.

## Task 3: Закрыть подтверждённые остатки

**Цель:** удалить только реальные остатки SAML, не ломая generic SSO/Google OAuth.

**Вероятные файлы:**
- Modify: `onelink/onelink-docs/internal/dev-ui-full-regression-test-plan.mdx:307` — убрать устаревший `/app/login/sso` сценарий.
- Review only: `db/migrate/20260831223000_remove_saml_sso.rb`
- Review only: `app/models/user.rb`
- Review only: `app/models/concerns/featurable.rb`
- Review only: `app/models/sso_authenticatable.rb`
- Review only: `app/controllers/devise_overrides/omniauth_callbacks_controller.rb`
- Review only: `app/controllers/platform/api/v1/users_controller.rb`

**Шаги:**
1. Удалить устаревшую строку SAML из internal DEV QA plan.
2. Подтвердить, что migration остаётся транзакционной и идемпотентной на DEV.
3. Не добавлять лишнюю `uid`-нормализацию: `User#set_password_and_uid` уже устанавливает `uid=email`, это подтверждено SAML builder spec.
4. Сохранить `retired_feature_54`, чтобы не сдвигать legacy feature bitmask.
5. Сохранить generic `sso_auth_token` и Platform login: это magic-link/impersonation контракт, не SAML.
6. Сохранить Google OAuth provider и callback.

**Ожидаемый результат:** в runtime/docs нет SAML entrypoints; Google OAuth и generic SSO не изменены.

## Task 4: Scoped code verification

**Цель:** доказать отсутствие регрессий без полного suite и без изменения PROD.

**Команды:**

```bash
bundle check
bundle exec rails zeitwerk:check
bundle exec rubocop <только изменённые Ruby-файлы>
pnpm exec prettier --check <только изменённые JS/Vue/JSON-файлы>
```

```bash
bundle exec rspec \
  spec/models/account_feature_flags_spec.rb \
  spec/models/user_spec.rb \
  spec/controllers/devise_overrides/sessions_controller_spec.rb \
  spec/controllers/devise_overrides/omniauth_callbacks_controller_spec.rb \
  spec/enterprise/mailers/enterprise/devise_mailer_spec.rb
```

```bash
pnpm vitest run \
  app/javascript/dashboard/routes/dashboard/settings/account/Index.spec.js \
  app/javascript/v3/helpers/specs/RouteHelper.spec.js
```

**Дополнительные проверки:**
1. Распарсить все изменённые locale JSON/YAML.
2. Поискать runtime residuals: `SAML`, `AccountSamlSettings`, `SamlUserBuilder`, `omniauth-saml`, `ENABLE_SAML_SSO_LOGIN`, `/app/login/sso`.
3. Отдельно подтвердить наличие Google OAuth и generic SSO callers/tests.
4. Проверить DEV migration status: pending migrations = 0.

**Ожидаемый результат:** scoped checks зелёные; unrelated failures только фиксируются и не исправляются.

## Task 5: DEV live verification

**Цель:** подтвердить фактическое состояние после code-level проверок.

**Шаги:**
1. Проверить login page HTTP 200.
2. Проверить отсутствие SAML route/controller response.
3. Проверить, что DEV login config не рекламирует SAML.
4. Проверить service status и свежие логи.
5. Проверить отсутствие SAML jobs в DEV queues/scheduled/retries/dead.
6. Не отправлять login/reset emails и не изменять пользовательские данные.

**Ожидаемый результат:** DEV live evidence зелёный и не содержит SAML runtime.

## Task 6: Заморозка diff и финальный review

**Цель:** получить финальный вердикт без commit.

**Шаги:**
1. Пересоздать точный SAML-only patch и SHA-256 после всех разрешённых правок.
2. Запустить один независимый read-only review этого неизменяемого artifact.
3. Во время review не менять проверяемые файлы.
4. Исправлять только blocker/high-risk finding; после такого исправления допустим один узкий follow-up review.
5. Выдать итог с разделением:
   - code-level;
   - DEV/live;
   - PROD — `не проверялся и не затрагивался`.

**Остановка:** оставить изменения незакоммиченными и unstaged. Никакого PROD действия и commit без отдельной команды пользователя.

## Риски и решения

- **Mixed dirty tree:** использовать patch artifact, не staging.
- **Старый boot-time SAML middleware в DEV:** при доказанном stale process разрешён только DEV restart.
- **Будущий PROD rollout:** сейчас не выполнять и не проверять. Отдельная будущая задача должна развернуть новый код на всех web/workers до физического удаления таблицы либо применить согласованный maintenance rollout.
- **Нет SAML-клиентов:** пользовательский password-transition сейчас не входит в scope; assumption будет записан как provided context, а не как PROD evidence.
