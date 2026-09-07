# OneLink Kaspi Pay Adapter

Internal-only sidecar for Kaspi Pay POS automation.

Source assessed/copied from: `tapter-dev/kaspi-pos-automation` at `579ee8b`.

## Security contract

- No public UI routes.
- Every `/internal/kaspi/*` request must include:
  - `X-OneLink-Timestamp`
  - `X-OneLink-Internal-Signature = HMAC_SHA256(KASPI_PAY_INTERNAL_SECRET, "{METHOD}\n{path_with_query}\n{timestamp}\n{rawBody}")`
- Rails owns payment records, idempotency and polling. The adapter must not persist payment state in JSON files.
- Do not log request bodies, Kaspi responses, passwords, `tokenSN`, `vtokenSecret`, `user_token`, signatures or OTP values.
- Authentication flows are account-bound, expire after 10 minutes, accept at most 5 password/OTP attempts, and expose an opaque flow ID instead of the Kaspi process ID.

## Endpoint contract used by Rails

- `POST /internal/kaspi/auth/init` (`accountId` is required)
- `POST /internal/kaspi/auth/send-phone` (`accountId` must match the flow owner)
- `POST /internal/kaspi/auth/send-password` (only when `send-phone` returns `nextStep=password`)
- `POST /internal/kaspi/auth/verify-otp`
- `POST /internal/kaspi/qr/create`
- `GET /internal/kaspi/qr/status`
- `POST /internal/kaspi/qr/render` (HMAC-only local PNG rendering; accepts only `https://qr.kaspi.kz/*`)
- `GET /internal/kaspi/invoice/client-info`
- `POST /internal/kaspi/invoice/create`
- `GET /internal/kaspi/invoice/details`
- `POST /internal/kaspi/invoice/cancel`
- `POST /internal/kaspi/invoice/history`
- `POST /internal/kaspi/history/operations`
- `POST /internal/kaspi/history/details`
- `POST /internal/kaspi/refund/create`

## Password-auth rollout

Deploy the Rails/frontend contract before the adapter. The old adapter ignores the additional `accountId`, so the existing direct phone-to-OTP flow remains available while password-first authentication remains unavailable as before. Then deploy the adapter and require `/health` to report both `password-auth-v1` and `account-bound-auth-v1` before considering the new flow ready. Do not deploy the account-bound adapter before every Rails web instance sends `accountId`.

The current browser sends `auth_flow_version=2` when it initializes a flow. If a browser tab loaded the old bundle before rollout, the adapter rejects a password-first response with `AUTH_CLIENT_REFRESH_REQUIRED` and deletes that flow instead of silently moving the old UI to an invalid OTP step. Reload OneLink and start a new flow.

## Runtime fingerprint overrides

The verified mobile fingerprint has safe defaults and can be updated without rebuilding the image:
`APP_VERSION`, `APP_BUILD`, `APP_PLATFORM`, `APP_PLATFORM_VER`, `APP_LOCALE`, and `APP_MODEL`.
The production compose maps these from the corresponding `KASPI_PAY_APP_*` variables.

The adapter keeps provider session/device identity only in its configured state directory and exposes no public routes; Rails is the source of truth for payment records, idempotency, status polling and Captain/tool payloads.
