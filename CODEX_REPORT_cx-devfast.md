# cx-devfast report

## Changes

1. **Fast mode:** `ONELINK_DEV_FAST=1` enables eager loading, disables Rails
   reloading, caches templates, disables verbose query logs and Sprockets
   asset debugging, and uses `info` logging unless
   `ONELINK_DEV_LOG_LEVEL` overrides it. The flag is off unless exactly `1`.
   Normal development keeps its existing `LOG_LEVEL` behavior. A new unit
   spec covers flag parsing, defaults, and log-level precedence.
2. **Development integrations:** Fast mode skips rack-mini-profiler and
   Tidewave. Tidewave 0.2.0's Railtie explicitly raises if
   `config.enable_reloading` is false, so it must not load in this mode.
   Normal development still loads it before Rails initializes. Existing
   reloader `to_prepare` registrations for Sidekiq cron, Facebook,
   ActiveStorage, event listeners, and LLM events remain: Rails runs them
   once at boot with reloading disabled. Web console, debug, annotate,
   meta_request, and optional Bullet were kept because the inspected code
   showed no equivalent reloading guard; their full runtime behavior still
   needs a DEV boot check.
3. **Built assets:** `ONELINK_DEV_BUILT_ASSETS=1` selects Vite Ruby's
   production mode in the development Rails process. That mode uses the
   existing `config/vite.json` `all` settings and the gem's default
   `public/vite` output with `autoBuild=false`, so no Vite configuration
   change or per-request build is needed. The deploy requires the env flag
   to match `/srv/onelink-dev/runtime/built-assets.enabled`; when on, it
   runs `nice -n 10 env NODE_OPTIONS=--max-old-space-size=4096 bin/vite build
   --mode production --force` before cutover, validates the manifest and
   dashboard file, then checks its public URL after cutover. A failed build
   stops deployment before activation. The normal `/vite-dev/` health check
   remains when off.
4. **Documentation:** Added `ONELINK_DEV_RUNTIME.md` at the repository root.
   The requested `docs/onelink-dev-runtime.md` could not be committed: `docs/`
   is an uninitialized Git submodule, its pinned object is absent locally,
   and this clone has no remote. The submodule pointer was kept intact.

## Exact external DEV runtime changes

- Fast mode on: add `ONELINK_DEV_FAST=1` to
  `/srv/onelink-dev/.env.development`, then restart all Rails web and worker
  processes. Add `ONELINK_DEV_LOG_LEVEL=warn` there only if a level other
  than the default `info` is wanted. Fast mode off: set
  `ONELINK_DEV_FAST=0` or remove it and restart; normal `LOG_LEVEL` applies.
- Built assets on: add `ONELINK_DEV_BUILT_ASSETS=1` to that env file and
  create `/srv/onelink-dev/runtime/built-assets.enabled`. In the external
  Foreman Procfile remove its `vite:` process. In Caddy replace the
  `/vite-dev/*` proxy to port 3037 with `/vite/*` routed to Rails on port
  3002, or let the existing catchall route serve `/vite/*` from Rails.
  Install the reviewed deploy script at
  `/usr/local/sbin/onelink-dev-deploy-release` before deployment, since the
  release workflow compares its SHA-256 with the pushed file. Deploy a new
  release. No external `VITE_RUBY_MODE` or `NODE_ENV=production` line is
  needed; code and the Vite build command select production asset mode.
- Built assets off: remove the flag file and set
  `ONELINK_DEV_BUILT_ASSETS=0` or remove it, restore the `vite:` process,
  restore Caddy `/vite-dev/*` to port 3037, then deploy or restart. The env
  flag and file must match for deploys.
- Optional persistent Bootsnap cache: create a writable directory such as
  `/srv/onelink-dev/runtime/bootsnap-cache` and set
  `BOOTSNAP_CACHE_DIR=/srv/onelink-dev/runtime/bootsnap-cache` in the DEV env
  file before restarting. Remove the variable to revert to release-local
  `tmp/cache`. No cache deletion is required.
- The external web launcher controls `DEV_WEB_WORKERS` (current target: 3).
  It must map the backend count to `WEB_CONCURRENCY`, the variable read by
  `config/puma.rb`. Revert via the launcher. The external reduced Sidekiq
  Procfile and its six active processes were kept; this task does not change
  queue ownership or process selection. `Procfile.dev-lite` in this repo
  still lists the main worker and 12 specialized workers.

## Boot-cost suspects from code inspection

- `config/boot.rb` enables Bootsnap but its default cache is `tmp/cache`
  inside each immutable release. The persistent cache setting above may
  reuse cached gem work; absolute paths to new release files may still miss.
- `config/application.rb` runs `Bundler.require(*Rails.groups)`, walks
  `enterprise/app/**` for eager-load paths, and requires every enterprise
  initializer. This is repeated by every Rails process. Development gems
  include Tidewave, web-console, meta_request, Bullet, debug, and annotate.
  Tidewave also requires its tools at gem load time; fast mode skips it.
- `config/routes.rb` is 1,069 lines and is evaluated at boot.
  `config/initializers/00_init.rb` parses the 659-line integration apps YAML.
  `config/initializers/event_handlers.rb` registers all dispatcher listeners
  in `to_prepare`. No safe local simplification was evident.
- `config/initializers/llm.rb` calls `Llm::Config.initialize!` after boot;
  `config/initializers/geocoder.rb` calls `Geocoder::SetupService#perform`,
  which can fetch a GeoIP database if absent and configured. These paths
  were kept because changing startup behavior could affect functionality.
- `config/initializers/languages.rb` builds a small static locale table;
  131 locale files exist under `config/locales`. No custom eager locale scan
  was found in the inspected application/initializer files, so locale
  loading was not changed.

These are code-based suspects, not measured timings. Eager-loading production
paths already exist; DEV-specific eager boot still needs live verification.

## Checks and limits

- `ruby -c` on `Gemfile`, `lib/onelink/dev_runtime.rb`,
  `config/application.rb`, `config/environments/development.rb`,
  `config/initializers/rack_profiler.rb`, and
  `spec/lib/onelink/dev_runtime_spec.rb`: **Syntax OK** for all. The first
  pass covered the five Ruby files before the Gemfile change; the final
  pass covered all six.
- `bash -n script/onelink/deploy_dev_release.sh`: **passed** after the
  final script edit.
- `bundle exec rubocop --force-exclusion --fail-level warning` on those
  six Ruby paths: **exit 0, five files inspected, no offenses**. The spec
  path is excluded by repository RuboCop config. An earlier pass returned
  exit 0 with one convention-level namespace-style offense; that was fixed
  before commit.
- `git diff --check`: **passed** before commits. Commit author and required
  trailers were checked with `git log`.
- `git ls-tree HEAD docs` showed a Git gitlink; `git cat-file -t` on its
  pinned object failed because the object is absent. `git remote -v` was
  empty. These checks explain the documentation placement.
- **Not run:** RSpec, Rails server/eager boot, Vite build, ESLint, Vitest,
  and `script/onelink/test_change_plan.py`. This clone has no Postgres or
  Redis, `node_modules` is absent, and the brief reserves executable tests
  and integration checks for the release engineer. No DEV or production
  host was accessed.

## Open verification and rollback

The release engineer should verify a flagged Rails web and Sidekiq boot,
the Vite manifest/dashboard asset through Caddy, and existing specs on the
real DEV infrastructure. Confirm the external launcher maps
`DEV_WEB_WORKERS` to `WEB_CONCURRENCY`, and move the runtime guide into the
docs submodule when that repository is available. If fast boot fails, set
`ONELINK_DEV_FAST=0` and restart. For built assets, restore the matching
flag/env, Foreman, and Caddy settings described above; use the deploy
script's `--allow-rollback` for a release rollback. No data or schema
change was made.
