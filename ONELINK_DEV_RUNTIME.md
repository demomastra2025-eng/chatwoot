# OneLink DEV runtime switches

These switches apply to the shared DEV deployment running `RAILS_ENV=development`.
All new modes are off unless their value is exactly `1`. Keep the values in
`/srv/onelink-dev/.env.development` available to the Foreman runtime and to the
deploy script.

| Switch | Enable | Disable | Effect |
| --- | --- | --- | --- |
| `ONELINK_DEV_FAST` | `ONELINK_DEV_FAST=1` | Unset or `0` | Eager loads Rails, disables reloading, caches templates, suppresses verbose query logs and asset debugging, and skips rack-mini-profiler and Tidewave. |
| `ONELINK_DEV_LOG_LEVEL` | For example `ONELINK_DEV_LOG_LEVEL=warn` with fast mode | Unset | Overrides fast mode's `info` level. Without fast mode, existing `LOG_LEVEL` behavior applies. |
| `ONELINK_DEV_BUILT_ASSETS` | `ONELINK_DEV_BUILT_ASSETS=1` **and** create `/srv/onelink-dev/runtime/built-assets.enabled` | Unset or `0` **and** remove the flag file | A separate gated preparation builds app and SDK assets for the exact SHA. Deployment verifies and consumes them. Rails serves `public/vite` and `/packs/js/sdk.js` without a Vite dev server. Deployment rejects mismatched or non-`0`/`1` settings. |
| `BOOTSNAP_CACHE_DIR` | Set to a writable persistent directory such as `/srv/onelink-dev/runtime/bootsnap-cache` | Unset | Shares Bootsnap's cache across immutable release directories. Bootsnap already runs from `config/boot.rb`; this is an optional runtime setting. |

## Safe first activation

1. Back up the installed endpoint and external runtime configuration. Install
   the reviewed DEV endpoint using `script/onelink/install_deploy_endpoint.sh`.
   CI compares installed deploy, preparer and asset verifier SHA-256 values
   with the exact release sources. The existing `/root/work/e-heavy.sh` is
   required and is not changed by the installer.
   Preparation and deployment both require the reviewed versioned toolchain:
   `/opt/node-24/bin/node` (24.x), `/opt/node-24/bin/pnpm` (10.x), and Ruby 3.4.4
   through `/opt/rbenv` with `RBENV_VERSION` pinned. They fail before work if
   versions/paths differ; the system-wide default Node is not changed.
   The reviewed deploy script sets its own CPU nice value to 10 and best-effort
   I/O priority to 7 before work; failure stops deployment. Install the script
   atomically while no deployment is running, preserving the existing SSH keys.
2. Deploy this compatible code with both flags off and the existing Vite
   process running. A previous release without `BUILT_ASSETS_CONTRACT = 1`
   cannot support rollback after the runtime switches to built assets.
3. Set the built-assets env and flag file together. Before restarting any
   process, prepare this exact SHA through the existing load gate:

   ```bash
   /root/work/e-heavy.sh /usr/local/sbin/onelink-dev-prepare-assets <full-sha>
   ```

   CI uses the restricted `prepare-assets <full-sha>` SSH verb before its
   separate `deploy`/`rollback` verb. The gate refuses active deployment
   processes, so it must never be invoked from inside the deploy script.
   Preparation holds the deployment lock, builds an exact Git archive using
   frozen dependencies, and builds both Vite app entrypoints and the widget
   SDK. It seals `/srv/onelink-dev/runtime/built-assets/<full-sha>` with both
   manifests and SHA-256 for every asset. A valid artifact is reused; a
   damaged artifact is rejected and requires operator repair before retry.
4. Remove `vite:` from the external Foreman Procfile. Keep Rails and worker
   lines as they are. Caddy's existing catchall to Rails on port 3002 can
   serve `/vite/*` and `/packs/js/sdk.js`. Preserve those path prefixes;
   `handle_path` stripping would break Rails public serving. The old
   `/vite-dev/*` route is unused in built mode and may be retained for rollback.
5. Redeploy the same SHA through the reviewed endpoint. It consumes the sealed
   artifact and validates the previous release before stopping workers. There
   is no early same-SHA success return: the endpoint restarts and checks the
   selected mode. The first built-mode redeployment can use itself as the
   compatible previous release after the verified assets have been installed.
   All seven app entrypoints and the SDK are checked through Caddy for exact
   response content, so an HTML fallback with HTTP 200 does not pass.

Rails explicitly selects production Vite mode, `/vite`, no auto-build and no
proxy in built mode, including with `VITE_RUBY_CONFIG_PATH=config/vite.hybrid.json`.
Normal development keeps its existing Vite options. Production does not apply
these DEV switches. Enable `ONELINK_DEV_FAST=1` only after the isolated eager
boot checks pass; it is independent of the asset mode.

For rollback to live Vite, remove the flag file, set
`ONELINK_DEV_BUILT_ASSETS=0`, restore the `vite:` process and `/vite-dev/*`
Caddy route, then deploy or restart the runtime. Set `ONELINK_DEV_FAST=0` and
restart Rails processes to restore code reloading. Restore `LOG_LEVEL` as
desired. A release rollback must use the deploy script's `--allow-rollback`
path; its checks use the active asset mode. In built mode, both the target and
previous release need compatible code and sealed assets. Automatic rollback
checks the previous public assets after restarting it. Changing external
flags or the Procfile is a separate operator action: a failed same-SHA runtime
switch cannot restore those settings automatically. Restore the saved env,
flag file and Procfile, then restart the compatible release.

## Verification

Run service-free artifact/endpoint contracts with
`python3 -m unittest script/onelink/test_dev_built_assets.py`, and runtime selector
specs with `bundle exec rspec spec/lib/onelink/dev_runtime_spec.rb`. Before live
activation, the isolated DEV harness must boot all four combinations of fast
`0`/`1` and built `0`/`1`, with prepared fixtures in built mode. Check reloading,
eager load, profiler/Tidewave loading and Vite manifest options. Tidewave requires
reloading and must be absent from fast boot. Confirm normal development and
production boot remain unchanged. Heavy builds and Ruby checks use the existing
DEV load gate; no provider or booking writes are part of these checks.

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
