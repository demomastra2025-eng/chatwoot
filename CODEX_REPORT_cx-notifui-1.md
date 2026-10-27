# cx-notifui-1 — calendar notifications screen

Base: `e83912db5177987373cd2f3d968caf4c83cac374` (the checked-out engine branch head). Implementation head before this report: `0c66963966887db009e10c465185bea138f6e537`.

## Screens and behavior

- **Calendar → Уведомления** (`scheduling_notifications`) lists every appointment-event automation rule as one row. Calendar-managed notification rules can be added, edited, enabled and disabled there. Existing appointment rules without the calendar flag stay visible and read-only until adoption; non-notification appointment automations point staff to Automations. The former `/scheduling/reminders` URL redirects to the new screen.
- Six existing presets appear as prefilled rows when their equivalent rule is absent. Saving a preset creates the same `AutomationRule` and `create_touch` action as a custom row. There is no second routed preset editor. The old source component and its tests remain in the tree, but its route is gone.
- The editor supports appointment created, updated (for existing rules), rescheduled, cancelled, visit start, visit end and no-show. It offers immediate, zero-offset at-time, before and after timing in minutes, hours or days, with optional clock time for day offsets. Visit-end rules use `appointment_completed` with the `appointment.ends_at` anchor, so they are enrolled only after completion. A transition to `no_show` now emits `appointment_no_show`.
- Content can be free text or an approved channel template. Template variables can be bound to appointment fields; a confirmation button is offered for a template with one quick-reply button. Conditions include service, specialist/resource, cabinet, status and source, evaluated by the existing `AppointmentConditionService`. Existing custom conditions and extra actions remain on save.
- The generic Automations list displays calendar-managed rules read-only with a link to Calendar. The appointment drawer shows planned, sent, skipped (with a staff-facing reason), and not-delivered reminder or enrollment outcomes. The summary endpoint is account scoped.
- New UI copy is present in ru, kk and en. Operational notes are in `script/onelink/calendar_notifications.md` because the `docs/` submodule is not initialized in this clone.

## Data and adoption

Migration `20261027170000` adds `automation_rules.calendar_managed` (default false) and an account/flag index. The flag replaces the description marker for calendar ownership. Existing rule IDs, actions, conditions and active states are retained by `calendar_notifications:adopt`. It selects appointment-event rules with a `create_touch` action, prints candidate counts per account, supports `MODE=dry-run` and `MODE=apply`, and writes a backup of IDs, account IDs and original flag values. Apply requires `BACKUP` and changes only the flag without running notification callbacks.

Actual dry-run on the fresh local test database:

```text
mode=dry-run total=0
backup=/tmp/notifui-adoption-backup.json
backup_rows=0
```

The transactional rake spec used fake data and observed `account=<fixture id> rules=1`, `mode=dry-run total=1`, then `mode=apply total=1` and `marked=1`. It verified the same rule remained inactive and its actions were unchanged. No production access or production SQL was available, so no production-like count was obtained. Apply was not run on real account data.

## Checks run

| Check | Result |
| --- | --- |
| `pnpm install --frozen-lockfile` | Passed; local dependencies installed. |
| `bundle exec rails db:create` and `db:schema:load` on `chatwoot_codex_notifui`; same setup on `chatwoot_codex_notifui_base` | Passed. Both databases were newly created. |
| `bundle exec rails db:migrate:up VERSION=20261027170000` on the base test schema | Passed; column and index added. |
| `ruby -c` on touched Ruby implementation files | Passed (`Syntax OK`). |
| Head: `bundle exec rspec -r /home/codex-e/vite_stub.rb` on the calendar rule request, appointment condition, listener and adoption task specs | **37 examples, 0 failures.** |
| Base: same existing appointment condition and listener specs | **32 examples, 0 failures.** New request and task specs do not exist on base. |
| Head: Vitest on calendar timing, appointment drawer, calendar page and Automations index | **18 tests passed** across four files. New notifications page spec also passed (**2 tests**), including preservation of existing condition order and values. |
| Base: Vitest on the shared calendar page and Automations index | **15 tests passed** across two files. |
| `translationKeys.spec.js` on head and base | **Same pre-existing failure on both:** 3 tests fail; missing-key counts are ru 235, en 241, kk 108. No new count was introduced. |
| Scoped `pnpm exec eslint --quiet`, `pnpm exec prettier --write`, and the staged ESLint commit hooks | Passed after formatting fixes. |
| Strict scoped `bundle exec rubocop` | Exited 1 with style/complexity findings, including existing complexity in touched files and the intentional validation bypass in the flag-only adoption task. `bundle exec rubocop --fail-level E` exited 0. Commit hooks auto-corrected formatting. |
| `git diff --check` | Passed. |

Intermediate checks found a Rails parameter serialized as string `"0"`, a reminder factory saved as `draft`, and a page-test mock that returned no Promise. Their assertions/mocks were corrected and the relevant checks passed on rerun. The full application suite and a live browser session were not run.

## Decisions and open questions

- The calendar flag is set on new calendar rules; old rules require the explicit adoption task. This keeps their IDs and delivery state intact and avoids toggling them during rollout.
- A confirmation button on free text is not supported by the current reminder constraint; the editor offers it for approved quick-reply templates. Decide whether free-text buttons need a separate delivery contract.
- Visit-end rules anchored to `ends_at` can be skipped by the existing late-notification policy if staff mark a visit complete well after its scheduled end. Confirm whether that policy matches the desired follow-up behavior.
- New condition controls cover the requested common fields. Existing custom field conditions are preserved but not exposed as new picker choices on this screen; confirm whether they need a dedicated picker.
- Public/internal `docs/` content could not be updated because the submodule is absent in this local clone. The operational note is in the main repository.
- This clone has no Git remote or GitHub credentials. Commits remain local; no push or production access was attempted.
