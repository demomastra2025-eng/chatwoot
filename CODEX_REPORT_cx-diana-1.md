# cx-diana-1 — scheduling urgent fixes

Base: `3d77ef5701548999166e28c73753f10a27806bf8`. Work is committed on `codex/cx-diana-1` in four part commits, followed by this report. No remote, production system, migration, data deletion, or `config/brakeman.ignore` change was used.

## A. Live reception conflict reads

- Added `app/services/integrations/medelement/reception_calendar_range.rb`. Both `provider_commands/preflight.rb` and `resource_availability_service.rb` use its exclusive range of provider-local midnights. Preflight semantics remain the same; reception pagination and local overlap filtering remain in place.
- Added `spec/services/integrations/medelement/reception_calendar_range_spec.rb` and extended `resource_availability_service_spec.rb` with a client stub that filters by calendar date, plus overlap, adjacency, removed, excluded, zone, and exact request-boundary coverage.

## B. Schedule day status and retry

- `app/services/integrations/medelement/schedules_sync_service.rb` recognizes an empty clinic-marked day off through the existing two-read confirmation path. API failures preserve `confirmed` and `empty_confirmed` rows while recording `last_attempted_at`; these rows wait 15 minutes before a retry. Other row states, successful reads, the 429 stop, and first-error raising retain their behavior.
- The refresh interval is now selected in one method shared with `app/services/scheduling/schedule_day_availability_service.rb`. Extended `schedules_sync_service_spec.rb`. The old expectation that an API failure changes a confirmed day to `unverified` was corrected in the same part.

## C. Conflict explanation

- Added `app/services/scheduling/slot_conflict_details.rb`. Local and provider refusals use it to return only a merged busy time range, the specialist zone, and up to four grid-valid same-day starts for the requested duration. It uses `Scheduling::AvailabilityService#slots` and the receptions already read during the provider check. Unknown free starts are omitted. Provider errors keep their existing code, status, and provider metadata.
- Updated `availability_refusals.rb`, `appointments/upsert_service.rb`, `appointments/imported_provider_mutation_service.rb`, and `resource_availability_service.rb`. Local appointment and time-off queries cover the day used for hints. With multiple cabinets and no chosen cabinet, the busy hint is withheld rather than attributing a reception to the wrong cabinet.
- `app/javascript/dashboard/stores/scheduling/shared.js` formats the three busy variants in the specialist zone; the prior generic text remains when no busy range is available. Added ru, kk, and en text. Extended `shared.spec.js`, appointment request/service specs, and added `slot_conflict_details_spec.rb`.

## D. Phone on the appointment card

- **D1:** `contacts_controller.rb` previously treated a phone-only patch as an identity edit and required IIN and last name. The controller now skips those requirements only for a phone-only update; create and other identity updates retain their checks.
- **D2:** The controller now rejects a non-Kazakhstan number for a linked patient before saving it, using `MEDELEMENT_PATIENT_PHONE_INVALID`. Existing 10-digit and 8/7-prefix normalization remains. The Russian error text no longer exposes the integration name.
- **D3:** A number owned by another account contact now returns `CONTACT_PHONE_TAKEN` with 409 before saving. A recorded shared-phone match keeps its existing path; no shared-phone flow was changed.
- **D4:** `ContactResolverService#assignable_provider_phone` keeps a new local phone when the provider card is blank; the recorded provider phone remains `''`. A matching provider phone leaves the local phone unchanged. Sync sets `skip_runtime_events`, and the outbound listener requires a User actor, so a provider sync does not queue a patient update back. A different free provider phone may replace the local phone on a card without channel identity. With a channel identity, the resolver preserves the chat contact's phone and may move the patient to another contact, as existing specs describe. These different-phone policies were left unchanged.
- **D5:** Added `SchedulingContactPhoneEditor.vue` and its spec. It is mounted in the calendar drawer for any selected contact. A phone-only save uses `formStore.updateInlineContact`; `appointmentForm.js` now includes the phone for a patient card and permits this one field on an imported appointment without a selected patient card. It updates only the phone in the form, preserving clinical identity fields. The drawer shows the new number immediately even when the imported appointment's own phone is still empty. A later appointment save sends that phone; server-side `resolve_client_phone` also falls back to the contact if the old appointment phone is blank. On success the calendar drops the contact's cached inbox list and reloads the active list. `Contacts::ContactableInboxesService` reads `contact.phone_number` when building WhatsApp inboxes; a spec pins immediate availability after a save.
- **D6:** Reminder routing is evaluated on creation and on reminder sync. At execution, `ExecuteService` checks the current notification contact and route, and `ConversationResolver` resolves delivery against current contact data. A later phone can therefore make a still-pending reminder deliverable, subject to its route and inbox rules. An already failed reminder is ineligible for execution and is not automatically retried merely because a phone was added. No reminder planning or execution code changed.
- The existing outbound path remains: contact update event, User-gated listener, outbound job, `update_patient` command, patient snapshot, scope validation, and executor. Added request, resolver, contactable-inbox, store, page, component, and outbound command specs. The outbound snapshot spec pins `profile_code` and all three `patient_phone_2[n]` fields.

## Shared files edited for merge review

- `SchedulingCalendarPage.vue`: import at 31; state at 196–198; save/cache refresh at 1740–1765; phone row and existing-input gate at 3110–3172. Conversation placeholder behavior was otherwise untouched.
- `appointments/upsert_service.rb`: day-wide local reads at 476–498; provider conflict details at 1296–1318.
- `appointmentForm.js`: phone-only guard and payload at 710–769; form phone update at 815–821.
- `shared.js`: conflict message formatting at 221–262.
- `contacts_controller.rb`: update call at 38–45; phone-only identity check at 217–224; phone validation and uniqueness at 251–282.
- `app/javascript/dashboard/i18n/locale/kk/index.js`: scheduling catalog merge at 35–57 so the new Kazakh strings are active without removing existing Russian catalog coverage.

## Verification

- `pnpm install --frozen-lockfile`: passed; dependencies were initially absent.
- `bundle check`: passed.
- `ruby -c` on all 21 changed Ruby files: passed. Rechecked `resource_availability_service.rb` after its last edit: passed.
- `pnpm exec vitest run` on `shared.spec.js`, `appointmentForm.spec.js`, `SchedulingContactPhoneEditor.spec.js`, `SchedulingCalendarPage.spec.js`, and `translationKeys.spec.js`: 127 passed, 3 failed. All 3 failures are in the translation-key guard. The same guard on an untouched worktree at the base commit failed with identical missing-key counts: ru 235, en 241, kk 108. A direct check confirmed all 11 scheduling keys used by these changes exist in each of ru, kk, and en. Focused reruns of the component and calendar page suites passed (2 and 14 tests respectively). After the last imported-appointment guard change, a focused `appointmentForm.spec.js` rerun passed all 74 tests.
- `pnpm exec eslint --quiet` on all changed JS/Vue files: passed.
- `pnpm exec prettier --check` on all changed JS/Vue/JSON files: passed.
- `bundle exec rubocop` on all 21 changed Ruby files: ran and failed with 93 style/complexity offenses in touched files. The new `slot_conflict_details.rb` and its spec passed a focused RuboCop run after correction. No finding was suppressed.
- `git diff --check` and `git diff --stat` against the base: reviewed; no whitespace error, migration, or protected-file change.
- **Not run:** all RSpec examples that need Postgres/Redis, including the added request and service specs. Neither service is available on this machine. No DB spec result is claimed.

## Open questions and limits

1. The DEV MedElement test account must confirm `update_patient` end to end, especially whether MedElement accepts an update without IIN and whether the existing patient name, `company_code`, and `profile_code` fields meet its write contract. OneLink-side saving is independent of that asynchronous outcome.
2. For a multi-cabinet specialist with no cabinet selected, the provider conflict has no attributable chosen-cabinet reception, so the UI retains the generic unavailable text. Decide whether a cross-cabinet specialist-wide hint is wanted before changing this behavior.
3. The different-phone provider sync behavior for cards without channel identity can replace a newer local number if MedElement later presents another free number. This does not affect the blank-card phone-add path; resolving the wider ownership policy needs a product decision.
4. The `docs/` submodule is not initialized in this clone and there is no repository remote. Documentation content could not be updated here; client and internal scheduling documentation should be aligned during release integration.
5. The translation-key guard is not green at the base, and broad RuboCop is not green on this branch. The guard's existing gaps need separate cleanup; this task did not weaken either check or extend the guard's tolerated-missing list.
