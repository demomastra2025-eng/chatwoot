# cx-compressrefresh report

## Root cause

Each successful compression called a forced account storage calculation from
`app/services/telephony/recording_compression_service.rb:122,236-237`. The same
synchronous call followed a retained-original trash move at
`app/jobs/telephony/purge_retained_recordings_job.rb:70,84-85` and the move,
restore, and empty operations at `app/services/storage/trash_service.rb:44,137,168`.
The calculation traverses every call session for the account in
`app/models/account.rb:470,488`, resolving recording paths for each session.
Repeated recording work therefore repeated the whole-account scan.

## Changes

- Those mutation paths now call the existing public
  `Accounts::StorageOverviewService#schedule_refresh(force: true)`. Its Redis
  lease coalesces requests for five minutes. The full calculation remains in
  the background overview refresh only.
- A separate, one-hour Redis marker keyed by the Active Job ID prevents a
  second enqueue while the first refresh is queued or running after the
  five-minute lease expires. The job releases only its own marker on completion.
  The marker expires if a job disappears without running.
- `Accounts::StorageBreakdownRefreshJob` now uses `housekeeping`. The branch
  base had it on `low`, despite the worker brief describing it as already on
  `housekeeping`.
- Added specs for ten successful compression requests, ten retained-original
  trash moves, and ten trash-service calls across move, restore, and empty.
  They assert one enqueue and no inline full calculation. Added coverage for
  the queued marker after the short lease expires and for marker release.
  Updated the purge failure spec because it asserted the old synchronous path.

## Kept and timing

The existing calculation, displayed categories and totals, snapshot payload,
and live `AccountLimits::StorageUsageService#within_limit?` checks are unchanged.
FFmpeg settings, recording publication and locks, retained-original period,
trash behavior, and stored references are unchanged. No schema or dependency
change was made.

The page can show the prior snapshot for the five-minute coalescing window
after a compression, purge, or trash operation. Actual refresh also depends on
the `housekeeping` queue wait and calculation time; a delayed worker can make
the snapshot older. If a queued job is lost, the one-hour marker must expire
before a new job can be queued. A queue delay beyond one hour can allow a
duplicate enqueue. These are bounded lease tradeoffs, not a change to quota
enforcement.

## Verification

- `ruby -v`: Ruby 3.4.4 available. `bundle -v`: Bundler 2.5.16 available.
- `ruby -c` on all 11 changed Ruby files: **Syntax OK** for every file. An
  earlier pass on the first 10 changed files also passed.
- `bundle exec rubocop --force-exclusion --fail-level warning` on all 11
  changed Ruby files: **exit 0**. It reported 48 convention offenses in these
  existing large files, with no warning-level failure. An earlier pass on 10
  files also exited 0 with 48 convention offenses.
- `git diff --check`: passed. Static `rg` audit found the sole remaining
  `storage_breakdown(force_refresh: true)` in the background overview service.
- Read-only Active Job API checks confirmed `enqueue`, `job_id`, and
  `successfully_enqueued?` are available; `ActiveJob::EnqueueError` was absent,
  so the enqueue-failure path uses a standard raised error.
- Confirmed `node_modules` is absent and the `docs/` submodule is not
  initialized. No docs-submodule change was possible in this local clone.

RSpec was **not run**: this machine has no Postgres or Redis. ESLint and Vitest
were **not run**: `node_modules` is absent; no JavaScript or Vue files changed.
The release engineer must run the new and existing specs against real services.

## Open questions

- If `housekeeping` queue waits can exceed one hour, should the pending-marker
  fallback TTL be raised? The current hour allows recovery from a lost job but
  can permit a duplicate after an exceptionally long wait.
