# Что конкретно вбивать

Ниже значения для **первого smoke test** по текущим данным из `Fonoster`.

## 1. Что вбивать в UI Onelink при создании `Fonoster` voice inbox

### Вариант для самого простого smoke test

- `Provider`: `Fonoster`
- `Phone number`: `+18623964686`
- `Number ref`: `d451bbe2-53d8-4458-bd0e-d811d85f57e0`
- `Primary app ref`: `74fec1f6-48e8-436c-8147-9176a5da4fa4`
- `Trunk ref`: `a299c0e0-150b-4fc9-9a58-f44bb3634324`
- `Routing mode`: `app`
- `AI app ref`: оставить пустым
- `Operator agent AOR`: оставить пустым
- `Reject message`: можно оставить пустым

## 2. Почему именно так

- `Onelink Voice Runtime`
  - `96fc259c-6bcd-4cbf-bb7d-d2c51f248934`
  - **не нужно** вбивать в `Onelink` как `Primary app ref`
  - это runtime app на стороне `Fonoster`, на него уже смотрит сам DID
- `Primary app ref` в `Onelink`
  - это app, который `Onelink` вернет в route decision для режима `app`
  - по твоим данным для первого smoke test это `Twilio Test App`
  - то есть `74fec1f6-48e8-436c-8147-9176a5da4fa4`

## 3. Если хочешь smoke test именно через `ai`

Тогда в `Onelink` вбей так:

- `Phone number`: `+18623964686`
- `Number ref`: `d451bbe2-53d8-4458-bd0e-d811d85f57e0`
- `Primary app ref`: `74fec1f6-48e8-436c-8147-9176a5da4fa4`
- `Trunk ref`: `a299c0e0-150b-4fc9-9a58-f44bb3634324`
- `Routing mode`: `ai`
- `AI app ref`: `74fec1f6-48e8-436c-8147-9176a5da4fa4`
- `Operator agent AOR`: оставить пустым

Но для первого прохода `app` проще и чище.

## 4. Что нужно в env на стороне Fonoster

Это **не в UI Onelink**, а в `.env` сервера `Fonoster`:

```env
TELEPHONY_BRIDGE_ONELINK_BASE_URL=https://<your-onelink-host>
TELEPHONY_BRIDGE_ONELINK_ACCESS_TOKEN=<bearer-token-if-used>
TELEPHONY_BRIDGE_ONELINK_ACCOUNT_ID=<account-id-if-used>
TELEPHONY_BRIDGE_SHARED_SECRET=44e0486dbc12aea62da52971c0038abf1db4e3b3f5cd58b6
```

## 5. Что нужно в env на стороне Onelink

Минимально:

```env
TELEPHONY_BRIDGE_SHARED_SECRET=44e0486dbc12aea62da52971c0038abf1db4e3b3f5cd58b6
```

Если используешь bearer auth, тогда токен на стороне `Onelink` должен совпадать с тем, что bridge шлет как bearer:

```env
TELEPHONY_BRIDGE_ACCESS_TOKEN=<same-bearer-token-if-used>
```

## 6. Что пока не заполнять

- `Operator agent AOR`
  - пока не заполняй, у тебя нет конкретного live `sip:user@domain` для operator route
- `Onelink Voice Runtime appRef`
  - `96fc259c-6bcd-4cbf-bb7d-d2c51f248934`
  - не вставляй в `Primary app ref` внутри `Onelink`

## 7. Итог

Если хочешь просто быстро запустить первый тест, вбей в `Onelink` именно это:

```text
Phone number: +18623964686
Number ref: d451bbe2-53d8-4458-bd0e-d811d85f57e0
Primary app ref: 74fec1f6-48e8-436c-8147-9176a5da4fa4
Trunk ref: a299c0e0-150b-4fc9-9a58-f44bb3634324
Routing mode: app
```

А на стороне `Fonoster` надо только правильно заполнить `TELEPHONY_BRIDGE_ONELINK_*` и дать сетевой доступ до `Onelink`.
