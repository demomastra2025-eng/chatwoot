# OneLink: разработка → DEV → PROD

## Главное правило

Ежедневная ветка одна: **`onelink-dev`**.

```text
изменение → проверки → commit → push → проверки GitHub → DEV
                                                       ↓
                                              ручная кнопка PROD
```

- Зелёный push автоматически и атомарно обновляет `dev.one-link.kz`.
- Красный push не меняет DEV: там остаётся предыдущая рабочая версия.
- PROD получает тот же проверенный Git SHA и OCI image digest без повторной сборки.
- Грязный или незакоммиченный каталог никогда не является релизом.

## Обычная работа

```bash
cd /root/crafty/onelink/chatwoot
git switch onelink-dev
git pull --ff-only origin onelink-dev

# изменить код и выполнить подходящие локальные проверки

git add <нужные-файлы>
git commit -m "тип: короткое описание"
git push origin onelink-dev
```

После push больше ничего делать не нужно: GitHub проверяет изменение и при успехе
выкатывает его в DEV. После ручной проверки DEV разработчик запускает workflow
`OneLink Promote Production`, указывает полный SHA и подтверждает GitHub Environment
`production`.

## Когда нужна отдельная ветка

Только для большого, рискованного или параллельного изменения:

```bash
git switch onelink-dev
git pull --ff-only origin onelink-dev
git switch -c feature/<короткое-название>

# изменить, проверить, commit, push и открыть PR в onelink-dev
```

После merge ветка удаляется. Постоянные персональные, release- и develop-ветки не нужны.
`onelink-main` используется только как техническая база синхронизации с upstream Chatwoot.

## Что автоматизировано

- `.github/workflows/onelink_pr_gate.yml` — проверки необязательной feature-ветки/PR.
- `.github/workflows/onelink_release.yml` — проверки каждого push в `onelink-dev`,
  быстрый DEV deploy и сборка подписанного production image.
- `.github/workflows/onelink_nightly.yml` — полный ночной Ruby/Vue/security suite.
- `.github/workflows/onelink_promote_production.yml` — ручное продвижение проверенного
  DEV SHA в PROD.

Проверки выбираются по diff от последнего успешно развернутого DEV SHA: Ruby, Vue,
migration и Docker-проверки запускаются только когда соответствующий слой изменился.
Если успешного DEV proof ещё нет, workflow принудительно выполняет bootstrap deploy;
после красного runtime-run следующий push повторно включает неприменённые изменения.
Автоматический flow принимает только безопасные
expand-миграции; destructive contract-cleanup выполняется отдельной операторской задачей. Изменения
встроенных sidecar-сервисов пока блокируются fail-closed, чтобы не создать смешанный
runtime из разных SHA.

## Поведение DEV

DEV deploy принимает только текущий полный SHA ветки `origin/onelink-dev`:

```text
deploy <40-character-sha>
```

Сервер:

1. получает SHA из Git;
2. готовит новый release-каталог и зависимости;
3. выполняет `db:chatwoot_prepare` до переключения;
4. атомарно переключает `/srv/onelink-dev/current`;
5. проверяет Rails, workers и Vite;
6. автоматически возвращает предыдущий release при ошибке.

## Поведение PROD

PROD deploy принимает только подписанный GHCR digest, содержащий запрошенный SHA:

```text
promote <40-character-sha> ghcr.io/demomastra2025-eng/chatwoot@sha256:<digest>
```

Workflow допускает promotion только если:

- этот SHA успешно работал в DEV;
- image содержит тот же SHA;
- signature, provenance и SBOM валидны;
- последний nightly, содержащий SHA, зелёный;
- человек подтвердил GitHub Environment `production`.

Rollout идёт workers → второй web → первый web. При ошибке сервисы возвращаются на
предыдущий image, а `.env.production` обновляется только после полной проверки.

## Одноразовая настройка оператора

Сделать `onelink-dev` default branch репозитория, чтобы scheduled nightly запускался из
той же единственной рабочей ветки. Создать GitHub Environments `development`, `nightly`
и `production`; для `production` включить
обязательное ручное подтверждение. Добавить environment secrets:

- DEV: `ONELINK_DEV_DEPLOY_HOST`, `ONELINK_DEV_DEPLOY_USER`,
  `ONELINK_DEV_DEPLOY_SSH_KEY`, `ONELINK_DEV_KNOWN_HOSTS`;
- PROD: `ONELINK_PROD_DEPLOY_HOST`, `ONELINK_PROD_DEPLOY_USER`,
  `ONELINK_PROD_DEPLOY_SSH_KEY`, `ONELINK_PROD_KNOWN_HOSTS`.

На каждом сервере используется отдельный непривилегированный deploy user и отдельный
Ed25519 key с forced command. Root SSH key в GitHub не хранится. Установка endpoint:

```bash
sudo ./install_deploy_endpoint.sh dev /secure/path/onelink-dev-ci.pub
sudo ./install_deploy_endpoint.sh production /secure/path/onelink-prod-ci.pub
```

Установка endpoint, настройка GitHub, GHCR login и первый PROD promotion являются
отдельными инфраструктурными изменениями и выполняются только в согласованное окно.
