# cx-card-1 report

## Changes

- Restored the existing `ContactInfo` profile in the conversation contact panel for every account. Its avatar, inline name edit, contact rows, channels, owner control, and existing action buttons remain in place. Patient data now follows those actions inside the same profile area.
- For patient-context conversations with several patients, added a compact “Пациент: ФИО, возраст” selector backed by the existing patient context store. With only the contact itself in the patient list, the selector is hidden. Birth date, IIN (last four digits only), MedElement card status, and the patient edit link appear as profile rows.
- Replaced the calendar drawer’s selected-contact rows with a compact patient card: avatar, name, age, masked IIN, phone editor, available channel names, write/call actions, profile link, and “Сменить”. The card loads optional avatar and channels through the existing contact detail endpoint.
- “Сменить” opens one visible search field with existing OneLink results and the existing MedElement result/import flow. “+ Новый пациент” is last in the result list. The inline identity form opens only when creating a new patient. The existing no-phone editor remains available and its Russian prompt now reads “Нет телефона — добавить”.
- Added Russian text and the matching en/kk keys required by the translation-key guard. No settings, API contracts, migrations, or data deletions were introduced.

No screenshots were possible here. At 390 px, the conversation profile is a scrollable column with the unchanged profile actions above a single compact patient line and fact rows. The appointment card wraps its small actions and keeps the search and results within the drawer width. On desktop, the same components use the wider drawer without a second search field.

## Kept and decisions

- Kept all existing `ContactInfo` action components and handlers, including the admin delete action.
- Kept the existing patient selection store/API, MedElement search/import, contact creation, and phone editor. Changing the patient of a MedElement-owned existing appointment remains blocked by the pre-existing guard; changing a local appointment patient uses the existing appointment form store.
- Kept current MedElement-specific validation for required identity fields. A new calendar patient uses the existing contact creation path.
- The `docs/` submodule is uninitialized in this local clone and has no local git module; documentation in that repository could not be edited without a remote.

## Verification

| Check | Result |
| --- | --- |
| `pnpm install --frozen-lockfile` | Passed; dependencies were installed from the lockfile. |
| `pnpm exec vitest run` on ContactPanel, ContactInfo, ConversationSidebar, SchedulingConversationPatientSelector, SchedulingPatientDetails, SchedulingSelectField, ComboBoxDropdown, SchedulingContactPhoneEditor, patientContext, and SchedulingCalendarPage specs | Final run: **10 files, 126 tests passed**. This includes 390 px and 1280 px cases. Earlier focused runs failed while old-layout assertions and the new-patient test selector were being updated. |
| `pnpm exec vitest run app/javascript/dashboard/routes/dashboard/scheduling/pages/SchedulingCalendarPage.spec.js -t 'shows the selected patient card'` | Final run: 2 passed, 13 skipped. An earlier run failed before the test selector was corrected. |
| `pnpm exec vitest run app/javascript/dashboard/components/widgets/conversation/ConversationSidebar.spec.js` | Passed: 22 tests in the earlier focused run. |
| `pnpm exec vitest run app/javascript/dashboard/i18n/specs/translationKeys.spec.js` | **Failed:** 3 locale assertions (ru, en, kk); 2 tests passed. The same 3 assertions fail on the untouched starting commit `e7348da6c`, verified in a temporary detached worktree. Failures list existing Help Center keys; no newly added patient key appears in the missing-key list. The temporary worktree was removed. |
| `pnpm exec eslint --quiet` on all changed JS/Vue files | Final run passed. Earlier runs reported formatting errors, then one unused test-stub event declaration; both were fixed. The commit hooks also ran `eslint --fix` successfully for staged JS/Vue files. |
| `pnpm exec prettier --check` on all changed files | Passed. `prettier --write` was run on the changed files during implementation. |
| Node check that the new patient-context keys exist in ru/en/kk scheduling JSON | Passed. |
| `git diff --check` and `git diff HEAD~2..HEAD --check` | Passed. |
| Ruby/backend specs and `source ~/.test-env; export POSTGRES_DATABASE=chatwoot_codex_card; bundle exec rails db:create db:schema:load; bundle exec rspec -r /home/codex-e/vite_stub.rb <files>` | **Not run:** this machine has no Postgres or Redis, as stated in the release task rules. No backend/API code was changed. |

The final passing Vitest invocation was:

```sh
pnpm exec vitest run app/javascript/dashboard/routes/dashboard/conversation/ContactPanel.spec.js app/javascript/dashboard/routes/dashboard/conversation/contact/ContactInfo.spec.js app/javascript/dashboard/components/widgets/conversation/ConversationSidebar.spec.js app/javascript/dashboard/components-next/Scheduling/SchedulingConversationPatientSelector.spec.js app/javascript/dashboard/components-next/Scheduling/SchedulingPatientDetails.spec.js app/javascript/dashboard/components-next/Scheduling/SchedulingSelectField.spec.js app/javascript/dashboard/components-next/combobox/specs/ComboBoxDropdown.spec.js app/javascript/dashboard/components-next/Scheduling/SchedulingContactPhoneEditor.spec.js app/javascript/dashboard/stores/scheduling/patientContext.spec.js app/javascript/dashboard/routes/dashboard/scheduling/pages/SchedulingCalendarPage.spec.js
```

Focused Vitest history: the initial four-file run had 9 failures and 27 passes; its rerun had 2 failures and 35 passes. The seven-file run including the translation guard had 5 failures and 82 passes. The six-file run before the final drawer fix had 2 failures and 80 passes. The combobox, select-field, and calendar run filtered by `-t 'patient|create|search'` had 2 failures, 15 passes, and 16 skips. The first full ten-file run had 2 failures and 124 passes. These failures were addressed except for the baseline translation guard.

## Open questions

- With the selector hidden for a contact who is the only patient, where should staff start adding a second patient who shares that number? This task follows the requested one-patient layout and leaves the underlying patient creation API intact.
- Should staff be allowed to change the patient on a MedElement-owned existing appointment? The current form guard prevents it, and changing that rule would affect provider identity handling.
- Should the calendar’s generic “new patient” contact creation link the new card to an existing communication contact when the same number is shared? The existing creation semantics were preserved.

## Commits

- `01bff20ab` Restore contact profile with compact patient context
- `faa994449` Show compact patient card in appointment drawer
- This report is committed last.
