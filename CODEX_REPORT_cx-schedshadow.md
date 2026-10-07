# cx-schedshadow: MedElement work schedule snapshots

## Changed

- Added the reversible, additive `medelement_schedule_days` table and account-scoped model. The table stores normalized working windows, raw `working` and `type` values for those windows, cabinet codes, confirmation status, consecutive empty count, source check time, last attempt time, and a raw payload digest.
- Added a `schedules` sync phase immediately after `specialists` on the existing 15-minute operational cadence. It requests only due doctor-days in a 14-day horizon, capped at 300 requests per run. Eligible doctors are active and were seen by the specialists poll within the previous hour. The existing client retains the integration timezone, shared integrator-key throttle, and retry policy.
- Added snapshot safety: malformed, partial, non-object, and failed provider answers retain saved windows and their source timestamp, mark the day unverified, and log only account/hook/resource IDs and date. Provider API errors continue through the existing sync-job retry handling. A first empty answer is unconfirmed and retains old windows; a second consecutive empty answer confirms an empty day. The shared `TimetableWorking` helper recognizes true, 1, `"true"`, and `"1"`.
- Added `provider_schedule` to the resource index/show payload only for MedElement-linked doctors, and a card showing the next 14 dated weekdays, confirmed hours, freshness, local-template differences, and unloaded/unverified states. New UI strings are Russian; the new literal keys have parity entries in en/kk solely for the translation-key guard.
- Added a short labelled MedElement snapshot note to single-day Captain schedule and availability answers. Those tools still return local scheduling data; the live provider check at booking remains authoritative.
- Added `medelement:schedule_diagnostics` to print per-hook counts without personal data. The existing sync-run panel now shows `schedules` and its created, updated, unverified, skipped, and request counters.
- Added model/index, phase, API payload, tool-answer, and Vue card specs. They were written for the release harness and were **not run here**.

## Kept and decisions

- Booking, appointments, slot search, preflight, local work rules, the specialist template seeder, and resource calendar attributes were not changed. The snapshot is read-only outside its own sync table. There are no MedElement write calls or booking creation in this package.
- Today and tomorrow become due after 1 hour; later days become due after 12 hours. Due days are selected by oldest successful check. `last_attempted_at` rotates unverified days so repeated failures cannot permanently consume the 300-request cap. A provider failure does not change `source_checked_at` or `raw_digest`.
- The snapshot table has indexed IDs and model-level account validation but no foreign keys. This avoids making existing hook/resource teardown fail because of retained snapshot rows. No cleanup or data deletion was added. The retention policy is an owner decision.
- The current account's MedElement hook is used for API and Captain reads. The card treats missing or unconfirmed days as unverified; only confirmed data is compared with local rules.
- The disabled-hook coordinator guard still prevents the entire sync run before any provider call. Disabling `sync_specialists` skips the schedules phase as well.

## Request budget

At the 275 ms shared throttle, 20 doctors × 14 days = 280 requests and about 77 seconds of throttle time for a full refresh. 100 doctors × 14 days = 1,400 requests and about 385 seconds (6.4 minutes), spread over at least five capped runs. The additional hourly today/tomorrow refresh is 40 requests (about 11 seconds) for 20 doctors or 200 requests (about 55 seconds) for 100 doctors, when due. Network time and retries add to these estimates.

## Checks and limits

- `ruby -c` on every changed `.rb`/`.rake` file: passed (22 files, including `db/schema.rb`). It was also run earlier on the same set and on focused edits; all syntax checks passed.
- `bundle exec rubocop --force-exclusion --fail-level warning` on the 21 changed Ruby source/spec/migration/rake files: final run exited 0. It reported three convention-level offenses in pre-existing controller/tool method shape, with no warning-level offenses. An early run failed with two warning-level offenses in the new sync service; those were fixed. Subsequent focused and full runs exited 0.
- `node --check app/javascript/dashboard/routes/dashboard/scheduling/pages/ProviderScheduleCard.spec.js`: passed.
- Node JSON parsing of the edited locale files and checks that the six new card keys exist in ru/en/kk: passed.
- `git diff --check` on the task diff: passed.
- Postgres/Redis-backed RSpec, migration execution, the rake task, ESLint, Prettier, Vitest, and the translation-key Vitest guard could not run here: there is no Postgres/Redis service and `node_modules` is absent. No real MedElement API was called.
- `docs/` is an uninitialized git submodule in this local clone, so product documentation there could not be updated without obtaining that separate repository. This report records the runtime/API design for the lead to carry into docs.

The final aggregate checks used these commands (base commit `3e67400466767e31f4ad6a74499d59d79efc8067`):

```sh
git diff --name-only 3e67400466767e31f4ad6a74499d59d79efc8067 HEAD | rg '\.(rb|rake)$' | while IFS= read -r file; do ruby -c "$file" >/dev/null || exit 1; done
git diff --name-only 3e67400466767e31f4ad6a74499d59d79efc8067 HEAD | rg '\.(rb|rake)$' | xargs bundle exec rubocop --force-exclusion --fail-level warning
node --check app/javascript/dashboard/routes/dashboard/scheduling/pages/ProviderScheduleCard.spec.js
git diff --check 3e67400466767e31f4ad6a74499d59d79efc8067 HEAD
```

## Open MedElement questions

- How does the provider distinguish a true day off from an unpublished schedule, vacation, or transient empty timetable?
- Are nonworking rows, partial days, replacement doctors, and cabinet changes represented with other `working`, `type`, or cabinet fields?
- What is the desired retention policy for orphaned snapshots after a hook or resource is removed?
