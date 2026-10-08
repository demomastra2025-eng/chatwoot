# OneLink DEV runtime switches

These switches apply to the shared DEV deployment running `RAILS_ENV=development`.
All new modes are off unless their value is exactly `1`. Keep the values in
`/srv/onelink-dev/.env.development` available to the Foreman runtime and to the
deploy script.

| Switch | Enable | Disable | Effect |
| --- | --- | --- | --- |
| `ONELINK_DEV_FAST` | `ONELINK_DEV_FAST=1` | Unset or `0` | Eager loads Rails, disables reloading, caches templates, suppresses verbose query logs and asset debugging, and skips rack-mini-profiler and Tidewave. |
| `ONELINK_DEV_LOG_LEVEL` | For example `ONELINK_DEV_LOG_LEVEL=warn` with fast mode | Unset | Overrides fast mode's `info` level. Without fast mode, existing `LOG_LEVEL` behavior applies. |
| `ONELINK_DEV_BUILT_ASSETS` | `ONELINK_DEV_BUILT_ASSETS=1` **and** create `/srv/onelink-dev/runtime/built-assets.enabled` | Unset or `0` **and** remove the flag file | The deploy builds `public/vite` with Vite production mode before cutover. Rails serves the resulting manifest and bundle without a Vite dev server. The deploy rejects mismatched settings. |
| `BOOTSNAP_CACHE_DIR` | Set to a writable persistent directory such as `/srv/onelink-dev/runtime/bootsnap-cache` | Unset | Shares Bootsnap's cache across immutable release directories. Bootsnap already runs from `config/boot.rb`; this is an optional runtime setting. |

Built assets require these changes in the external runtime configuration, made
together with the two switches above:

1. Remove the `vite:` process from the DEV Foreman Procfile. Keep the Rails web
   processes and worker lines as they are.
2. Replace Caddy's `/vite-dev/*` proxy to port 3037 with a `/vite/*` route to
   Rails on port 3002, or let the existing catchall route send `/vite/*` there.
   Rails has `public_file_server.enabled = true` in development and serves
   files from `public/vite`.
3. Deploy a new release. The script builds at low priority with
   `NODE_OPTIONS=--max-old-space-size=4096`, checks the manifest and dashboard
   file before cutover, then checks the public dashboard asset URL.
   The app selects `VITE_RUBY_MODE=production` internally when the built-assets
   flag is on; do not set that mode for the normal Vite development workflow.

For rollback to live Vite, remove the flag file, set
`ONELINK_DEV_BUILT_ASSETS=0`, restore the `vite:` process and `/vite-dev/*`
Caddy route, then deploy or restart the runtime. Set `ONELINK_DEV_FAST=0` and
restart Rails processes to restore code reloading. Restore `LOG_LEVEL` as
desired. A release rollback must use the deploy script's `--allow-rollback`
path; its checks use the active asset mode.

`DEV_WEB_WORKERS` belongs to the external web launcher. The repository's
`config/puma.rb` reads `WEB_CONCURRENCY`; the launcher must map the desired
backend worker count to that variable. Use `DEV_WEB_WORKERS=3` for the current
DEV target and reduce it in the launcher to reverse the change. This setting
does not select Sidekiq processes.

The repository's `Procfile.dev-lite` keeps the main Sidekiq worker plus the
Medelement sync/commands, WhatsApp webhook forward, Telegram inbound/personal
inbound, outbound messages, reminders, Telegram personal history, WhatsApp Web
inbound/history/echo, and coexistence history workers. The current shared DEV
process selection is in an external Procfile, so changes to its six active
Sidekiq processes must be reviewed there; no queue assignment is changed by
these flags.
