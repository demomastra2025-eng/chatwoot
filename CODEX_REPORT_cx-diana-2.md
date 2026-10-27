# cx-diana-2 — verification and hardening

Base: `3d77ef5701548999166e28c73753f10a27806bf8`. This branch builds on the committed cx-diana-1 result. The database results below supersede the cx-diana-1 report's statement that RSpec could not run.

## Changes in this review

- Gave synthetic MedElement receptions distinct negative IDs in `Scheduling::SlotConflictDetails`. The shared availability service had skipped receptions with `id == nil` when `ignore_appointment_id` was also nil, so the 409 response omitted the busy hint and could propose a start that crossed a reception. Added a longer-duration regression example.
- Omitted a single busy-range hint when the requested interval overlaps separate visits with a free gap; the existing generic refusal text remains available. Added a regression example for that ambiguity.
- Used the returned contact phone as the source for the appointment form after an inline save. Removed the page's duplicate form update and its submitted-value fallback. Added a store example for a response that does not retain the submitted number.
- Reset the inline phone editor when its contact changes, even when the next contact has the same phone value. The page clears stale phone errors on form context changes and ignores a late save error for a different contact.
- Corrected two added RSpec examples: the blank-card resolver fixture now has matching direct and indexed reads, and the calendar-range spec checks `exclude_end?` directly. Added the missing blank line in the contactable-inbox spec.
- Updated an older local-cancellation integration spec to expect day-aligned reception query bounds. Its old booking-time expectation was the wrong behavior corrected by cx-diana-1 Part A.

## Review decisions and retained behavior

- Kept one day-aligned MedElement reception range shared by preflight and live availability. Local overlap filtering and reception pagination remain in the existing service.
- Kept the existing two-read day-off confirmation and 15-minute failed-attempt backoff for previously confirmed schedule days. A successful read still replaces stored data.
- Kept `SLOT_CONFLICT` and `APPOINTMENT_SLOT_UNAVAILABLE` codes and statuses. New conflict hint fields contain only time ranges and the specialist time zone; existing provider metadata is retained. The frontend retains its generic text when no reliable busy interval is available.
- Kept phone updates on the existing account-scoped contact and outbound `update_patient` path. No second integration flow, schema change, migration, data deletion, or protected-file edit was introduced.
- Kept IIN and last-name validation for non-phone identity edits, and kept the recorded shared-phone path. The new inline action sends only the phone, so these wider identity and family-number rules do not need to change.
- Checked the phone editor's mobile layout in code: the drawer row is one column below 768px; the editor and number input use `min-width: 0`, and actions wrap. No fixed width or horizontal scroll was added. No browser screenshot was taken.
- New UI strings contain no technical provider terms and exist in ru, kk, and en. The translation guard's missing-key set is identical on head and base.

## Verification

| Check | Head | Base |
| --- | --- | --- |
| `bundle check`; `pnpm install --frozen-lockfile` | Passed | Install passed |
| `bundle exec rails db:create db:schema:load` with `POSTGRES_DATABASE=chatwoot_codex_diana` / `chatwoot_codex_diana_base` | Passed | Passed |
| Changed Ruby specs, `bundle exec rspec -r /home/codex-e/vite_stub.rb <changed files>` | Initial run interrupted after 26 examples / 1 failure to fix a confirmed bug; next run 285 examples / 2 failures in added specs; both examples fixed in a focused rerun (3 / 0). A later run on the database used by the guard-failing broad suite had 313 examples / 1 failure because two committed appointments remained; the final fresh-database rerun passed: **313 examples / 0 failures**. | 262 examples / 0 failures (new spec files absent at base) |
| Related Ruby suites: scheduling, MedElement, reminders, automation rules, contacts, related jobs and models, and Captain appointment tools | 3,118 examples / 31 failures. Thirty example names also fail on base; the sole head-only failure was the old day-boundary expectation and its full file now passes (35 / 0). | 3,095 examples / 30 failures |
| Failed concurrency files rerun in new isolated `_test` databases required by `CommittedRowsCleanup` | 28 examples / 4 failures, the same four as base; the other 24 passed | 28 examples / 4 failures, all in `appointments_shared_phone_released_spec.rb`; the other 24 passed |
| Five changed/frontend Vitest files plus `translationKeys.spec.js` | 131 tests: 128 passed, 3 translation-guard failures | Four existing files: 122 tests: 119 passed, the same 3 guard failures |
| Final `appointmentForm.spec.js` and `SchedulingCalendarPage.spec.js` after phone fix | 89 passed | Earlier equivalent files passed in the base run |
| `SchedulingContactPhoneEditor.spec.js` and `SchedulingCalendarPage.spec.js` after contact-switch fix | 17 passed | — |
| `ruby -c` on 21 original changed Ruby files, three corrected specs, and finally all 22 changed Ruby files | 21 / 21, 3 / 3, and 22 / 22 passed | — |
| Focused RuboCop on the new conflict helper and spec, then corrected resolver/range specs | Passed (2 files in each run) | — |
| Full RuboCop on changed Ruby files | 93 offenses across 21 files before the contactable-inbox blank-line fix; final: 92 offenses across 22 files | 86 offenses across 17 existing files |
| Exploratory helper extraction (reverted before commits) | RuboCop: 28 offenses in three inspected files; affected RSpec files were interrupted after 138 examples / 0 failures. The final committed tree is covered by the 313-example passing run above. | — |
| ESLint on all changed JS/Vue, then the three phone-fix files | Passed | — |
| ESLint and Prettier on the three contact-switch files | Passed | — |
| Prettier on the three phone-fix files, then all changed JS/Vue/JSON | Passed | — |
| `git diff --check`; base diff audit for migrations, `config/brakeman.ignore`, and docs | Passed; none of those paths changed | — |

The three translation-guard failures on both revisions report ru 235, en 241, and kk 108 missing keys. The extracted missing-key sets are identical (315 distinct entries); this branch adds none. Full RuboCop was already failing at base; head has six net additional complexity offenses in touched service methods. No finding was suppressed. I tried a small shared-helper extraction, then reverted it because it expanded the code and did not clear the findings.

The broad run's original database names do not match `CommittedRowsCleanup::TEST_DATABASE_NAME`, so concurrency examples refused to truncate them. I did not weaken that guard. I created fresh `chatwoot_codex_diana_test` and `chatwoot_codex_diana_base_test` databases only for those examples. The 28-example reruns match exactly on head and base: only four existing shared-phone released examples fail. Three reminder conversation examples also fail assertions on the base; they are separate from the database-name guard. I created `chatwoot_codex_diana_verify_test` to rerun changed specs after the first head database had been left with committed rows by the refused cleanup.

## Open questions and limits

1. The DEV MedElement test account must verify `update_patient` end to end, especially updates of a patient card without IIN. No production or provider write access was used here.
2. A multi-cabinet specialist without a selected cabinet retains the generic unavailable message because a live reception cannot be attributed to a chosen cabinet.
3. A later provider card with a different free phone can replace a local phone on a card without a channel identity. The blank-card phone-add path is preserved; ownership policy for a later differing provider number remains a product decision.
4. `docs/` is an uninitialized submodule in this clone, so client and internal scheduling documentation could not be updated here.
5. The translation-key guard and broad RuboCop remain non-green at base. Their existing catalog and style debt needs separate cleanup without weakening either gate.
6. Head's six net additional RuboCop metrics findings need a small service extraction to meet the current thresholds. That refactor was left outside this correctness review; the full check remains red on both revisions.
