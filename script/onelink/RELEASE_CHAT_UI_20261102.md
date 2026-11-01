# Chat and UI integration: release gates

This candidate is assembled on DEV base `d5cf9d9d90d8d7c67fc5fe5719e696cc6549361a`.
A feature-branch push is not deployment approval. Do not advance `onelink-dev` or
PROD until the dependencies below are satisfied and the exact candidate has
passed its integration checks.

## Accepted slices

- Visual audit fixes: `128f86921aa20133ea4001361895621c8e59738a`.
- CPU/cron and historical-delivery counts: `0c055e04c44a1c4de9fb7fc8ca7d01676ab3623e`.
- Design skill and standalone catalogue: `62984eff6d2a4c3a10e79ccc7ba42af7fdb6ba4e`.
- Company availability projection for the widget: `d468614eb5189e6b2896cf6878101cdc6be82895`.
- Removal of disconnected AI/CSAT code: `284c7ce7a57d38533ec7589cd4042e57401092a4`.
- Conversation history scroll: `7acad4e23c005b8222292dcc19d8bc3da64d1785`.
- Reactions and authoritative Telegram edit metadata: `9916e0f43e78b03921e6fb41e4f1e3d4f4642c01`.

Specialist schedule changes enter this list only after the corrected frozen SHA
has passed independent review. Other unfinished `logic-*` branches are excluded.

## Telegram edit metadata: coordinated cutover required

The app requires the gateway contract introduced by
`Khamzauly/telegram-personal-gateway` commit
`d366c2750a6cce3271bc0ef6e6f94bbc11cd9f74` (parent `feff7f21ecf8`), or a reviewed
descendant containing that change. Private and group full message snapshots
always include:

- `message_edited_at`: UTC ISO8601 string, or JSON `null`;
- `message_edit_hidden`: JSON boolean, including explicit `false`.

The app uses one parser at webhook ingress and in the queued worker. Missing or
malformed metadata in a full text/caption update returns HTTP 503 without
queueing; a legacy immutable queued job raises a typed error. Pure reaction-only
updates do not require text-edit metadata. Do not suppress these errors or infer
an edit by stripping Markdown/HTML: the provider also parses message text.

Order:

1. Prepare and verify the reviewed gateway image and its source identity.
2. Upgrade the producer first while the old app can still process legacy
   snapshots. Verify the exact contract with a synthetic event.
3. Verify that old full callbacks have finished: gateway in-flight HTTP requests,
   app queues, retry/scheduled jobs and workers. Report only aggregate counts,
   never message bodies or customer details. If zero cannot be established,
   **HOLD**; prepare a separately reviewed fresh-provider replay plan.
4. Advance the app only after those gates. Immutable old callbacks do not gain
   metadata by retrying. Do not automatically rewrite historical `edited` flags.

`message.updated` in the old gateway sends directly through `CallbackClient`
with bounded HTTP retries. HTTP 503 does **not** imply durable outbox storage or
automatic replay. No historical replay is authorized by this integration.

The owner's separate requirement is to route Telegram calls through the shared
Janus. The old aiortc bridge is not the final approved architecture. Coordinate
the complete gateway/app/Janus version set with that work; do not deploy the old
bridge as fulfilment of the Janus requirement.

## Database and rollback

The candidate preserves the existing billing migration
`20261101183000_create_billing_autobilling_tables.rb` and adds the concurrent
partial index migration
`20261102003500_add_wa_historical_delivery_index_to_messages.rb`. The schema merge
keeps both sets of objects and the newer schema version. The index's idempotent
up/down/up was rehearsed on an isolated test database.

Use the current canonical brain runbooks for DEV deployment, backups, migration
approval and rolling restart. PROD needs approval for the exact app/gateway/Janus
result and each infrastructure/data step. Keep the prior app and gateway images,
configuration and session volumes for rollback. Never downgrade the producer
contract while the strict consumer is still running; restore compatible app
consumers first and verify queues before considering a gateway rollback.

No AI auto-reply, clinic messages, historical data repair or publication is
included in this candidate. Verify real desktop/phone behaviour on the exact DEV
SHA before requesting production promotion.
