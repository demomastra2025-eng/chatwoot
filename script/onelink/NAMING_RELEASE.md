# OneLink public naming migration

This application change is part of the combined Beeline, Naming, MedElement and WhatsApp release. It is prepared from `fcb617cc6f2c739b9e3a46b2854f644e4113d8ab`. It does not itself rename databases, roles, directories, containers, volumes or networks, change live environment files, or deploy a release. Production and KZ execution still require the owner's final approval of the combined package.

## Application contracts

| Surface | Canonical contract | Compatibility during migration |
| --- | --- | --- |
| Browser configuration | `window.onelinkConfig` | Bidirectional `chatwootConfig` alias to the same object |
| Widget settings | `window.onelinkSettings` | `chatwootSettings` and previously generated `chatonelinkSettings` aliases |
| Widget SDK/client | `window.onelinkSDK`, `window.$onelink` | Legacy SDK and client names share the same instances; a cached SDK/client is adopted without creating another iframe |
| Public widget events | `onelink:*` | Each corresponding `chatwoot:*` event is emitted once; there are no forwarding listeners or loops |
| Generated installation snippets | Canonical SDK/settings names | Fallback to an older cached SDK; copied legacy snippets continue working |
| Account API version | `latest_onelink_version` | Existing `latest_chatwoot_version` remains equal |
| Webhook delivery/authentication | `X-OneLink-Delivery`, `-Timestamp`, `-Signature` | Same timestamp, body and HMAC under legacy names while the bridge is enabled |
| Custom HTTP tool context | `X-OneLink-*` | Identical legacy aliases, with the existing context/filtering and values preserved |
| Bot image | `/assets/images/onelink_bot.png` | Byte-identical old asset remains available to cached clients |
| Session cookie | `_onelink_session` after staged activation | Cookie-aware conversion and logout/drop handling described below |
| Grafana overview/logs | `onelink-production-overview`, `onelink-production-logs` | Exact old default UIDs map to canonical; custom operator UIDs are preserved; old Grafana objects remain available |
| Hub/telemetry | Explicit installation endpoint and request policy | Legacy configuration can be read during migration; production retirement disables all Hub requests |

Locale changes preserve JSON keys, value types and template parameters. Existing module/class names, package identities, iframe messages, browser storage keys, DOM/CSS contracts, Redis keys, persisted InstallationConfig names and serialized job payloads remain compatible. `LICENSE` and upstream attribution are retained.

## Environment contract

The application reads canonical names before legacy fallbacks. Presence is authoritative: an explicitly empty canonical value must not reactivate an older credential or endpoint. It does not rewrite the process environment or database configuration identities.

| Old host key family | Canonical host key family |
| --- | --- |
| `CHATWOOT_*` | `ONELINK_*` |
| `LEGACY_CHATWOOT_*` | `ONELINK_LEGACY_*` |
| `CRAFTY_*` | `ONELINK_*` |

In particular, `CHATWOOT_IMAGE` and `LEGACY_CHATWOOT_IMAGE` map to different keys (`ONELINK_IMAGE` and `ONELINK_LEGACY_IMAGE`). The infrastructure package must use an explicit consumer map for Compose/systemd interpolation. Third-party Evolution `CHATWOOT_*` environment names and postprocessor `CHATWOOT_STORAGE_DIR` are container protocols: canonicalize their host-side sources while retaining the names required by those consumers. The Evolution `/chatwoot/webhook/...` path is likewise an external API contract and requires a verified upstream-compatible alias before any path retirement.

`ONELINK_HUB_URL` works in all runtimes; an explicit empty value disables the endpoint. The old `CHATWOOT_HUB_URL` fallback retains its former development-only scope. `ONELINK_ENABLE_HUB_SYNC` takes precedence over `ENABLE_CHATWOOT_HUB_SYNC`. `ONELINK_UPSTREAM_HUB_ENABLED=false` disables telemetry, registration, events, mobile relay HTTP and the billing URL. Browser WebPush and directly configured native FCM are independent and remain available. The sidebar no longer fetches the upstream changelog; it returns an empty compatible feed until OneLink supplies a separately verified JSON feed.

## Required deployment order and gates

1. **Freeze the combined application and compatible rollback artifacts.** Both include this entire Naming change and the reviewed Beeline provider policy. The rollback artifact excludes the MedElement/WhatsApp functional changes. Once new public SDK/cookie contracts are issued, genuine `fcb617cc` is not a compatible rollback target. Retain old asset paths in both artifacts.
2. **Provision Grafana canonical dashboards before application promotion.** Copy the two reviewed existing definitions to the new UIDs. Verify dashboard bodies, panel/datasource references and access before switching the application. Preserve the old UIDs for bookmarks and rollback. An application deployment without verified canonical dashboards is blocked.
3. **Confirm external dependency aggregates again immediately before activation.** The 31 October read-only snapshot found 7 browser subscriptions (1 updated in 30 days), 0 FCM subscriptions and no configured Firebase project/credentials. Disable the vendor Hub only while FCM remains 0 or after a tested replacement exists. This is not evidence that native FCM is ready. Preserve existing WebPush keys/subscriptions and verify browser push through the supported test path without exporting private key material.
4. **Keep `ONELINK_LEGACY_EXTERNAL_HEADERS_ENABLED=true`.** The snapshot found 3 account webhooks and 33 enabled custom HTTP tools. Receiver migration is outstanding. Audit only approved receiver contracts, verify canonical signature/context handling, then retire legacy names through a separately reviewed configuration stage. Do not infer safety from zero API-channel callbacks alone.
5. **Deploy cookie-aware code on every web replica with the legacy primary.** The default `ONELINK_SESSION_COOKIE_NAME=_chatwoot_session` intentionally does not issue the canonical alias to legacy-only clients. Verify the exact cookie-aware SHA on every web replica before switching the primary. This avoids a genuine old replica logging out only one of two cookies during the first rolling deployment.
6. **Activate `ONELINK_SESSION_COOKIE_NAME=_onelink_session` with the bridge enabled.** Roll replicas one at a time. Cookie-aware old-primary replicas mirror an already-present alias, and both old/new-primary replicas clear both names on session drop. The middleware decrypts and re-encrypts using the destination cookie purpose; copying encrypted ciphertext across cookie names is not valid. Secure/HttpOnly/SameSite/path attributes are retained.
7. **Retire legacy cookie writes only after every replica uses the canonical primary.** Set `ONELINK_LEGACY_SESSION_COOKIE_BRIDGE=false`; startup rejects retirement with the legacy primary. Mixed bridge/retirement replicas preserve the canonical session. An old-only dormant cookie can still be imported once into the canonical name and removed; the option retires mirroring, not all historical-cookie recognition. Removing that final reader requires a subsequent explicit session-expiry/logout policy, rather than silently logging out dormant administrators. Reset/drop must be checked across both names before and after activation.
8. **Verify public contracts and runtime flags on the combined candidate.** Verify generated embeds, cached embeds, one iframe, both event names once, version API equality, canonical/legacy webhook HMAC equality, tool headers and monitoring links. Check DEV systemd/foreman Pumas and workers actually receive `TELEPHONY_BEELINE_ENABLED=false`; production retains its default true. No standalone policy rollout is planned.

## Infrastructure stages in the combined maintenance package

The accompanying infrastructure package must cover the remaining owner scope with explicit preflight, success and rollback checks:

| Required surface | Migration stage and preservation requirement |
| --- | --- |
| `/root/crafty` → `/srv/onelink` | Copy/verify bytes, ownership and modes; update every Compose bind path, systemd unit, backup wrapper, timer/cron and operational consumer; retain a verified rollback path until retirement |
| Compose project `crafty-prod` → `onelink` | Map all 33 defined / 30 live services, dependencies, DNS aliases and lifecycle scripts; avoid duplicate writers or simultaneous ownership of a database |
| `chatwoot_*` containers/services | Use explicit old/new service mapping; update health, metrics/log labels and automation selectors; rolling web/worker application release must not be confused with a full project/network migration |
| 13 existing persistent volumes and 4 networks | Preserve the existing physical volume names as explicit external resources until a separately verified data migration; never create empty replacement volumes or run volume deletion as cleanup; verify network consumers and aliases before retirement |
| `chatwoot_production` / `chatwoot_app` | Separate database/role maintenance stage with a measured downtime gate, stopped writers/connections, identity/ownership/grant and row-count/byte checks, backup/restore rehearsal and exact reversal; no promise of zero downtime or a fixed two-minute window |
| Temporary `sslip.io` telephony URLs | Beeline uses the reviewed authenticated `wss://app.one-link.kz/janus-beeline` transport migration, with actual registrations and all old clients/calls drained before retiring exactly the two KZ Beeline containers; Wazo services are untouched |
| Other host URL keys / Firecrawl | Build a source-to-consumer URL table, prove each replacement/reachability, and clear obsolete values only after confirming their fallback behavior; do not invent an unverified domain or leave an active external dependency unaccounted for |

The operational inventory, secrets, runtime environment snapshots, database dumps and artifacts remain outside this source document. Aggregate counts and hashes may be attached to the release attestation. No phase is considered complete merely because an alias exists: physical persistence/network stages and remaining receiver/session-reader retirements must be recorded as completed or explicitly blocked before final approval.

## Rollback

Use the prebuilt Naming-aware application rollback artifact with the Beeline policy and retained assets. Keep the canonical cookie primary once activated; do not roll back to cookie-unaware code or disable the bridge on an old-primary replica. Retain both Grafana UID definitions. Restore infrastructure/environment through the reviewed stage-specific recovery plan and verify actual process flags. Hub reactivation is permitted only with the approved endpoint/dependency plan; it must not silently fall back to a vendor because a canonical value is empty. Database/project/path rollback follows its separate maintenance stage, preserving all data and avoiding duplicate writers.
