# cx-heavyfiles report

## Root cause

Before this change, `Api::V1::Accounts::StorageController#heavy_files` called `Accounts::HeavyFilesService#fetch_recordings`, which iterated every recorded call session and resolved and sized each file in the web request (`app/services/accounts/heavy_files_service.rb:134-156` in the base commit). The Storage page requested that endpoint on mount and after Overview refresh (`app/javascript/dashboard/routes/dashboard/settings/storage/Index.vue:116,312` in the base commit). For the largest account, this exceeded the 30-second request limit and held a web worker.

## Changes

- The existing background inbox breakdown pass now collects the largest 200 active recording rows while it already resolves and stats their files (`app/models/account.rb:488-505`). The refresh job writes them to `account:<id>:storage_heavy_recordings_v1` after a successful calculation. The collector keeps bounded memory and does not add another file scan.
- The heavy-files request reads that Redis snapshot, filters its rows by type, inbox, conversation, date range, and limit, and merges them with attachment rows in the existing byte-size order. Its `files` rows retain the previous fields. When the recording snapshot is absent or unreadable, the endpoint returns attachment rows with `recordings_pending: true`.
- Attachment reads use a 10-second session `statement_timeout`, restore the previous value without a new transaction, and return HTTP 503 JSON with a localized `message` on query cancellation.
- The heavy-files table is in Cleaner. Opening Cleaner or changing its list filters requests the list; mounting the page and refreshing Overview do not. Existing loading behavior remains, and a pending hint tells users to reopen the tab after the background calculation.
- Added Ruby request, service, and refresh specs for the snapshot, top-200 bound, file-size parity, filters, cold response, timeout, timeout restoration, and absence of request-path recording resolution. Added a Vue spec for mount, tab-open, filter-change, pending hint, and Overview refresh behavior.

## Kept and decisions

- Recording storage, trash, purge, quota, and the attachment list behavior were kept. No schema, dependency, or data deletion change was made.
- The snapshot has no TTL, like the overview snapshot. It is replaced only after a successful background pass. Thus it can be stale after a recording is added, changed, or purged until the next successful refresh; a failed pass retains the last good snapshot. A missing snapshot stays pending until a refresh succeeds.
- The 200 rows are the largest recordings **for the account before filters**. Narrow filters can therefore return fewer recordings than the former full scan, including none when matching files are outside the global top 200. This is the bounded-memory interpretation of the requested snapshot and should be confirmed as the intended Cleaner behavior.
- The `docs/` submodule is not populated in this local clone, so no docs-repository page was edited. The API and staleness behavior are recorded here for the release engineer.

## Verification on this machine

- `ruby -c` on the nine changed Ruby implementation/spec files: all `Syntax OK` (run after initial edits and again after final Ruby edits).
- `bundle exec rubocop --force-exclusion --fail-level warning` on those nine Ruby files: first pass reported 10 convention offenses; second pass reported 3; the next two passes reported **9 files inspected, no offenses detected**. The first two commands returned exit 0 because the configured fail level was `warning`; the offenses were fixed before commit.
- `node --check app/javascript/dashboard/routes/dashboard/settings/storage/Index.spec.js`: passed twice.
- `node -e` with `JSON.parse` on the changed ru/en/kk `settings.json` files: passed.
- `ruby -e` with `YAML.load_file` on the changed ru/en/kk backend locale files: passed.
- `git diff --check` and the committed-range `git diff ... --check`: passed; no whitespace errors.
- Commit messages and clean branch status were checked with `git log` and `git status`.

## Not run here

- `bundle exec rspec`: this machine has no Postgres/Redis for database-backed specs.
- ESLint, Vitest, Prettier, and the Vue component spec: `node_modules` is absent in this clone. The release engineer must run these, along with real RSpec, on the verification infrastructure.

## Commits

- `730f9103e` Move heavy recording selection into storage refresh
- `547ed56f7` Load heavy files when Cleaner opens

Both commits are linear on the checked-out branch and carry the required co-author trailer. No remote action was attempted.
