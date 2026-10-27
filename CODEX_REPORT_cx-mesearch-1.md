# cx-mesearch-1 report

Base: `3d77ef5701548999166e28c73753f10a27806bf8` on `codex/cx-mesearch-1`.

## Changes

### A. Local contact search

- `Search::ContactQuery` now matches `last_name` and `middle_name` alongside `name`, including the existing е/ё behavior. Multiword queries require each word in any of the three name fields, in any order. Existing email, identifier, phone, phone-digit and case-sensitive identifier behavior remains.
- Added the sole migration, `20261027160000_add_name_parts_trigram_index_to_contacts.rb`, for a concurrent GIN trigram index on the two added fields, with invalid-index cleanup, retry and timeout handling, and `ANALYZE contacts`. Updated `db/schema.rb`.
- Added service and request specs for surnames, patronymics, mixed name order, е/ё, all nine Kazakh Cyrillic case pairs, account scoping and unchanged search behavior.

### B. MedElement patient picker

- Added staff-only POST search and import endpoints. Search uses a JSON body, enabled account hook, one query classifier, exact valid IIN or normalized full phone or up to three name prefixes, and at most the two specified name interpretations. It drops removed and duplicate rows, returns at most 20 with a truncation marker, masks IIN, and does not fetch cards during search or cache results.
- Added a dedicated `:lookup` request profile with one short retry, a one-second maximum rate-slot wait, short transport timeouts and a shared five-second search deadline. Existing request profiles are unchanged. Query parameters are filtered from Rails logging; indexed patient lookup breadcrumbs and spans are removed from Sentry. Errors exposed by this search have fixed messages without typed values.
- The selected row carries a signed, expiring token bound to account, hook, staff user and patient code. Import reads the current card and passes it to `PatientsSyncService` and its existing contact resolver. Explicit imports bypass the 24-hour fresh-contact shortcut, so they either apply the verified card or return an unavailable error. Repeated imports resolve to the same contact. No MedElement write is made.
- The calendar payload now includes one enabled-hook flag. The picker adds a debounced remote block below local options, keeps local results visible, drops stale responses, hides only remote rows already displayed locally, supports keyboard selection and a 375 px layout, and imports a selected row into the existing form path. New text is under `SCHEDULING.PATIENT_SEARCH` in ru, en and kk; the Kazakh locale overlays only that namespace on the existing Russian scheduling catalog.

### C. Booking an identified patient

- A patient with `medelement_patient_code` can be booked without a phone. The form and upsert validation still require first and last name; the selected card supplies them. A new patient without a code still requires a valid IIN and phone and the existing name rules.
- Code-linked create/move reception snapshots no longer require a phone. If a patient card has no phone, they do not borrow the communication contact's number. `PatientResolver` no longer raises `patient_phone_missing` for a code-linked patient without a phone, while keeping mismatch warnings when patient phone numbers are known. The reception payloads contain patient code, timing and resource fields, with no phone field.
- Removed phone extraction from conflict-comment prose in the shared contact resolver; the structured provider phone supplies the conflict detail instead.

## Decisions and retained behavior

- The account hook flag is carried by the calendar response, which the page already loads; no extra page-load request was added.
- Search rows are display data only. Import always reads the card, including when a linked local contact is fresh. This also covers search rows whose phone fields are blank while the card has a phone.
- `PatientContactBinding.provider_phone` remains required for `create_patient` and `update_patient`, which write a phone. `PatientSelectionService` still requires a phone when it converts an already confirmed, previously unlinked draft into a patient-write snapshot. `AppointmentPatientBindingSnapshot` checks a phone only when its command snapshot contains one. The new code-linked reception snapshot omits that field when unknown.
- The conversation sidebar form and its separate required-field copy were left untouched. The shared combobox was extended without changing its local option selection path. Scheduling appointment callbacks, appointment importer, receptions/schedules sync, reminders, AI suggestion, and vendored vue-cal were not changed.
- Other contact-related text predicates found outside `Search::ContactQuery`: Captain's `SearchContactsService` and the telephony AI voice tool search contacts directly; CRM deal search and MedElement conflict filtering have separate purposes. `Contact.resolved_contacts` is a non-text scope. None is the same contact search box, so none was changed.

## Checks run

| Check | Result |
| --- | --- |
| `pnpm install --frozen-lockfile` | Passed; dependencies were absent initially. |
| `ruby -c` on all 31 changed Ruby files | Passed. The final added Kazakh spec was also checked separately after editing. |
| `bundle exec rubocop` on all 31 changed Ruby files | Failed: 6,604 offenses; the generated `db/schema.rb` accounts for most. Remaining offenses in existing files are pre-existing large-class/method, formatting or older spec offenses. No lint suppression was added. |
| `bundle exec rubocop` on all seven new Ruby files | Passed, no offenses. |
| `bundle exec rubocop spec/services/search/contact_query_spec.rb` after the final spec edit | Passed, no offenses. |
| `pnpm exec eslint` on all 14 changed JS/Vue files with `--quiet` | Passed. |
| `pnpm exec prettier --check` on all 14 changed JS/Vue files | Passed. |
| Focused Vitest: new API, composable, picker, appointment form and scheduling fallback specs | 5 files, 89 tests passed. |
| Calendar page Vitest spec in isolation | 13 tests passed. |
| Vitest across `i18n/specs`, `stores/scheduling`, `components-next/Scheduling`, `routes/dashboard/scheduling` with two workers | 48 files, 598 tests: 595 passed, 3 failed, all in `translationKeys.spec.js`. It reports 235 missing ru, 241 en and 108 kk literal keys from unchanged screens, including reports, inbox configuration and sidebar. |
| JSON parse of ru/en/kk scheduling catalogs | Passed. A separate key check found all 12 new `PATIENT_SEARCH` keys in each catalog, with zero missing. |
| `git diff --check` | Passed. |

No database-backed RSpec tests, migration execution, or SQL `EXPLAIN` could run on this machine because PostgreSQL and Redis are unavailable. The new DB specs are committed for the release pipeline to run.

## Open verification and overlaps

- DEV must run the migration and inspect plans on 140,000 synthetic contacts. The SQL uses plain column `ILIKE`/`~*` predicates, but index choice and PostgreSQL's exact case behavior for the nine Kazakh Cyrillic pairs cannot be measured here. No cross-letter substitutions such as қ→к were added.
- DEV must exercise phone-free `create_reception` against its MedElement test organization. The repository payload builder shows no phone field in create or move reception; the external behavior cannot be verified locally.
- The existing translation-key guard remains red on unrelated missing keys. The new namespace is complete in ru/en/kk; the guard was neither weakened nor allowlisted.
- The `docs/` submodule is uninitialized in this clone, so documentation there could not be updated without fetching a remote, which this task forbids.
- Nearby release work on reschedule confirmation touches appointment callbacks and importer code; calendar hold/resize touches vue-cal. Those areas were left untouched.

No remote was added, no push was attempted, and no production system was accessed.
