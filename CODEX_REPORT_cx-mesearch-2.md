# cx-mesearch-2 verification report

Base: `3d77ef5701548999166e28c73753f10a27806bf8`. Work stayed on `codex/cx-mesearch-2`; no remote, production system, or real MedElement organization was contacted.

## Changes made during review

- Corrected signed import-token verification: the message verifier returns symbol-keyed hashes, so the token identity must be stringified before account, hook, user, and patient-code checks. Added token-scope and staff-access examples.
- Made the code-linked patient card, rather than a separate communication contact, the source of an optional reception phone. Added a regression example for a booking with distinct patient and communication contacts.
- Matched picker text cleanup to `Search::QueryText.clean`, retained keyboard access to remote rows when pressing ArrowUp from an empty selection, and covered both with Vue tests.
- Redacted search and import JSON bodies in Sentry request events and transactions. Required JSON request bodies for both endpoints so URL query parameters and form bodies cannot supply the query or import token. Added request and Sentry specs.
- Preserved the authored appointment phone in the immutable command snapshot for a code-linked reception. The phone is a snapshot identity field; it does not become a provider patient phone or a required field. This fixes a distinct-event deduplication regression while retaining phone-free booking. Added a snapshot regression assertion; the existing outbound command example now passes.
- Corrected two test expectations: global search only exposes resolved contacts, and the lookup retry delay is 0.25 seconds. No product behavior was changed for these expectations.

## Kept behavior and decisions

- Local surname/patronymic search still uses `Search::ContactQuery` and the single new trigram index from cx-mesearch-1. The new patient picker still classifies one query, reads MedElement rows without storing them, and imports only a chosen row through `PatientsSyncService` and the existing resolver.
- Existing create/update-patient commands still require a phone; code-linked create/move reception does not. The conversation sidebar, appointment callbacks, importer, reminders, automation, and vendored calendar were not changed.
- New UI strings remain confined to `SCHEDULING.PATIENT_SEARCH` in ru, kk, and en. The 375 px picker and shared combobox keyboard specs pass. No second matching path, fallback chain, placeholder field text, or phone parsing from comments was added.
- The head database ran `db:migrate` as required for the branch migration. The repository's `db:migrate` enhancement loads installation defaults, including `ACCOUNT_NON_WEB_INBOXES_LIMIT=0`; the schema-loaded base database lacked that override. This caused 33 head-only inbox-factory failures. I changed only that **local test database setting** to `ChatwootApp.max_limit` (100000), matching the base's effective limit, and reran the affected files. No repository setting or test was weakened.

## Rails verification against base

| Check | Head | Base | Assessment |
| --- | --- | --- | --- |
| Initial changed Ruby spec batch | 199 examples, 0 failures after fixes (10 head files) | 171 examples, 0 failures (7 base files) | Later privacy, JSON-body, and snapshot specs were run separately below. |
| Broad MedElement, scheduling appointments/API, contacts, reminders, automation listeners | 1,942 examples, 53 failures before the final snapshot fix and test database limit alignment | 1,922 examples, 19 failures | The 19 common failures are 14 committed-row cleanup guard failures (task database names do not end in `_test`), 4 shared-phone request examples, and 1 reminder-listener example. The 34 head-only failures were 33 inbox-limit setup failures and 1 immutable command snapshot regression, addressed as described above. |
| Outbound command and request snapshot builder files after fix | 53 examples, 0 failures | Base's isolated outbound example: 1 example, 0 failures | The head's previously failing outbound example and added snapshot example also passed together: 2 examples, 0 failures. |
| Five inbox-limit-affected files after local test database alignment | 115 examples, 0 failures | Base isolated self-declared resolver example: 1 example, 0 failures | Aligned to the base's effective non-web inbox limit; no code change. |
| Existing contact-search service suite | 6 examples, 0 failures | 6 examples, 0 failures | Shared search path passes. |
| Reminder-listener failure in isolation | 1 example, 1 failure | Also present in base broad run | Listener untouched; it cancels another conversation's reminder. |

The cleanup guard refused to truncate databases named `chatwoot_codex_mesearch` and `chatwoot_codex_mesearch_base`. I did not weaken the guard, rename a database to bypass it, or delete data. The four shared-phone failures and reminder failure reproduce on base, so they were left for their owning work. The 33 inbox-limit failures were setup differences, not branch behavior.

## Other checks

| Check | Result |
| --- | --- |
| `bundle exec rails db:create db:schema:load` with separate head/base databases; `bundle exec rails db:migrate` on head | Passed. The new `index_contacts_on_name_parts_trgm` was present as a GIN index on the two name-part columns. |
| Head token and linked-contact targeted RSpec; outsider access; Sentry privacy; JSON-body request specs | 2/0, 1/0, 2/0, and 5/0 respectively. |
| Initial changed Ruby specs before fixes; targeted rerun of those failures | 196 examples, 4 failures; then 4 examples, 0 failures. |
| Focused Vitest for API, composable, picker, appointment form, and locale fallback | 5 files, 89 tests passed. Later composable 5/0, SchedulingSelectField 10/0, shared combobox 22/0. |
| Broad Vitest: `i18n/specs`, `stores/scheduling`, `components-next/Scheduling`, `routes/dashboard/scheduling` | 48 files, 598 tests: 595 passed, 3 failed in `translationKeys.spec.js`. Base guard has the identical three failures and identical missing-key counts: ru 235, en 241, kk 108. No missing keys were added or removed by this branch; all new patient-search keys exist in all three locales. |
| `pnpm install --frozen-lockfile` | Passed; dependencies are present. |
| `ruby -c` on all 32 changed Ruby files, plus the final snapshot edit | Passed. |
| `bundle exec rubocop` on all 32 changed Ruby files | 6,599 offenses, 6,525 autocorrectable; most are in generated `db/schema.rb`. The snapshot builder's two offenses are identical on base. New files and added lines have no lint offenses; no suppression was added. |
| `pnpm exec eslint --quiet` and `pnpm exec prettier --check` on all 14 changed JS/Vue files | Passed. An initial Prettier issue in the new combobox spec was formatted and rechecked. |
| `git diff --check 3d77ef570 HEAD` | Passed before the report commit. |

The first Vitest invocation with only `--maxWorkers=2` was rejected by Tinypool's min/max settings; rerunning with both `--minWorkers=2 --maxWorkers=2` produced the counts above. The first base changed-spec invocation named a head-only file and collected zero from that path; it was rerun on the seven files present in base. A direct `psql` index query could not authenticate the local OS role, so the index was verified read-only through Rails instead.

## Open verification and questions

- The requested synthetic 140,000-row `EXPLAIN` and a real MedElement test-organization phone-free `create_reception` could not be exercised in this local clone. The release pipeline/DEV should verify those integrations. Local DB specs cover Kazakh Cyrillic case pairs and the added search paths.
- The three translation-key guard failures, four shared-phone request failures, reminder-listener failure, and 14 database-name cleanup-guard failures remain as described above; they also fail on base. The guard and unrelated functionality were not altered.
- `docs/` is an uninitialized submodule in this no-remote clone, so its documentation could not be updated here.
