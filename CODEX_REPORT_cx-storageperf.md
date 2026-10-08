# cx-storageperf report

## Root cause

The former `StorageController#show` ran both `Account#storage_breakdown` and `StorageUsageService#summary` synchronously. A cold breakdown cache executes `Account#calculate_storage_breakdown` (`app/models/account.rb:371-384`), including tenant-wide blob sums, a join to messages for inbox totals (`app/models/account.rb:470-478`), and a `find_each` plus file stat for every call session recording (`app/models/account.rb:485-512`). The controller then ran another uncached quota aggregate in `StorageUsageService#summary` (`app/services/account_limits/storage_usage_service.rb:91-99`). This work scales with account history and held the web request until Rack::Timeout.

## Changed

- The GET and manual refresh endpoints now return the last Redis-backed overview snapshot immediately. On a cold miss they return `calculating: true` and enqueue one low-priority refresh. A five-minute Redis lease coalesces refresh requests; the existing hourly scheduler also updates snapshots.
- `Accounts::StorageBreakdownRefreshJob` computes the existing breakdown and quota summary in the background. Its SQL runs with a transaction-local 10-second statement timeout. A failed refresh leaves the previous snapshot intact and logs only account ID and error class.
- The Storage page shows a localized calculating state. Manual refresh now reports that calculation was requested. The global usage banner does not treat a calculating response as a completed reading. New keys are present in ru/en/kk as required by the translation-key guard; only Russian is currently shown in the product.
- Request and service specs cover cold and warm reads, duplicate enqueue prevention, absence of the old message/blob scan in requests, parity with the old calculation on attachments and a recording, and timeout fallback.

## Kept and why

- The breakdown formulas, blob ownership rules, recording paths, trash behavior, and purge behavior are unchanged. Reusing the existing calculation in the worker avoids changing displayed byte semantics.
- Staff upload limit checks still calculate live quota usage through `StorageUsageService#within_limit?`. This keeps enforcement exact despite a stale page snapshot. Incoming messages and calls continue to bypass that check. No files or data were deleted, and no migration or dependency was added.
- The old `Account#storage_breakdown` cache remains for its other callers. The new snapshot uses `Redis::Alfred` because the production Rails configuration does not declare a shared `Rails.cache` store across web and Sidekiq processes.

## Freshness and decisions

- On an open page, a snapshot older than five minutes requests a background refresh and still displays its last known values and timestamp. The hourly job refreshes accounts even without page visits. There is no hard maximum age when jobs fail; the last Redis value stays available until eviction. A cold or evicted snapshot shows calculating until a worker succeeds.
- A manual refresh queues work rather than waiting for the scan. The user can check again with the page's existing refresh control; there is no aggressive polling.
- No index migration was added because moving the existing scan out of the web request addresses the timeout without a schema change. The release engineer should measure whether account 43's individual aggregate queries finish within the 10-second statement limit on the real database.

## Checks

- `ruby -c` on the changed controller, service, job, request spec, and service spec: all `Syntax OK` (run during implementation and again after the final Ruby edits).
- `bundle exec rubocop --force-exclusion --fail-level warning` on those five Ruby files: the first pass found three correctable style offenses; a later pass found two offenses after the Redis change; the final pass found **no offenses**.
- `python3 -m json.tool` on ru/en/kk `settings.json`: all passed. A Python JSON/key check confirmed both new storage keys in all three locales.
- `node --check app/javascript/dashboard/components/app/StorageUsageBanner.spec.js`: passed.
- `git diff --check` and `git diff --cached --check`: passed.
- `node_modules` presence check: missing. ESLint, Prettier, Vitest, and `translationKeys.spec.js` were **not run**. Postgres/Redis-backed RSpec specs were **not run** because those services are unavailable here. No migration validation was needed because there is no migration.

## Open questions and limits

- The real database may show that one or more account 43 queries exceed the worker's 10-second statement timeout. If so, the next step is to inspect `EXPLAIN (ANALYZE, BUFFERS)` on safe infrastructure and make a targeted query or index change after review.
- The `docs/` submodule is empty in this local clone, so the changed refresh workflow could not be documented there. Its client-facing documentation should be updated when the submodule is available.
- Redis or Sidekiq outages prevent a new snapshot from being produced; the endpoint still avoids the expensive synchronous scan and returns a calculating state or the last known value.
