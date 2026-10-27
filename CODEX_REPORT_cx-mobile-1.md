# cx-mobile-1 report

## Root cause

Before this fix, `useConversationSidepanelAvailability.js` selected the active panel directly from persisted `is_contact_sidebar_open`, CRM, and appointments flags (now visible as the desktop branch at `app/javascript/dashboard/composables/useConversationSidepanelAvailability.js:86-103`). `ConversationView.vue:109-114,292` and `InboxView.vue:75-78,239-242` mounted the sidebar as soon as a chat and active flag existed. On a phone, `ConversationSidebar.vue:179-186` is a fixed, full-width drawer translated into view when active, so it covered the conversation. There was no route-entry or viewport gate for the saved panel flag. A desktop session leaving the contact card open therefore made the next phone conversation appear to open directly into that card. The dashboard already forces the expanded conversation layout on phones (`Dashboard.vue:136-153`); that rule did not govern the right drawer.

The conversation route/query only selects the chat and handles patient selection. It was not the primary trigger. One explicit route action in `SchedulingCalendarPage.vue:921-928` also saves the appointments flag before navigating to a conversation, which could produce the same cover-up before this fix. Commits `179936d1c` and `823c443db` changed the AI reply area, not this sidebar selection. The earlier narrow-width change `2c8a965f6` adjusted panel layout but did not gate persisted open state.

## Fix and decisions

- The shared sidebar composable now uses one active-panel decision: at widths up to and including 768 px, only a panel explicitly opened for the current account and conversation is active; above that width it uses the existing saved flags. It retains the feature and permission checks for deals and appointments. The 768 px boundary matches the dashboard's mobile conversation layout.
- The contact, deals, and appointments buttons, header shortcuts, and in-panel transitions use that shared open/close action. Closing a phone panel returns to the conversation and leaves desktop preferences untouched. Entry and navigation reset the temporary phone selection. No new persisted setting or migration was added.
- Existing desktop flag updates, including the partial updates used by the contact and deal flows, were kept so desktop behavior remains the same. The existing dashboard mobile list/message layout and unrelated overlays were also kept.
- No UI copy or locale files changed.

## Other phone overlays found; not changed

| Place | Phone behavior |
| --- | --- |
| `components-next/sidebar/Sidebar.vue:1732-1736` | Global navigation drawer covers the left of the page when opened; `Dashboard.vue:88` starts it closed. |
| `components-next/Contacts/ContactsDetailsLayout.vue:140-181`, `components-next/Companies/CompaniesDetailsLayout.vue:71-111` | Detail drawers cover part of the page after their buttons are used; both start closed. |
| `components-next/Scheduling/SchedulingDrawer.vue:253`, `components-next/Scheduling/SchedulingSidePanel.vue:128`, `routes/dashboard/scheduling/pages/SchedulingCalendarPage.vue:2793` | Appointment/form drawers use full-screen phone backdrops when their controlling state opens them. |
| `routes/dashboard/crm/pages/CrmDealsPage.vue:4248-4270,4785-4790` | Deal editor can be opened by route/query state and covers the list with a modal backdrop on phones. |
| `components-next/CRM/CrmDealConversationPanel.vue:551` | Deal conversation content is a full-screen phone overlay when visible outside inline mode. |
| `components/widgets/conversation/TagSkills.vue:248`, `components/ui/ContextMenu.vue:116`, `components/Modal.vue:85` | Skill picker, mobile context menu, and generic modal cover the main content while active. |
| `components/widgets/WootWriter/ReplyBottomPanel.vue:835`, `components-next/year-in-review/YearInReviewModal.vue:175` | File-drop overlay and optional year-review modal cover the page while active. |

No other unconditional default-open overlay was found in this code search. The CRM and scheduling route/query-driven openings above may merit a separate product decision; they were left as requested.

## Verification

| Check run | Result |
| --- | --- |
| `pnpm install --frozen-lockfile` | Passed; installed existing lockfile dependencies. |
| Initial five-suite Vitest run (availability, switch, conversation view, inbox view, sidebar) | Failed: 14 sidebar assertions assumed saved flags open a phone drawer, and the inbox test mock lacked `emitter.on`. Tests were updated to distinguish desktop preferences from phone taps and to supply the existing emitter interface. |
| Initial ESLint on changed files, then an error-only rerun | Failed with six formatting errors and 56 existing localization warnings; formatting errors corrected. |
| Initial two-suite sidebar/inbox rerun | Failed on one phone drawer assertion and the inbox emitter mock; both corrected. A single drawer test then passed. |
| First ten-suite affected Vitest run | 98 passed, 11 header tests failed because the header test fixture did not supply the shared composable's store. The fixture was isolated and the header buttons were covered. |
| Three-suite availability/switch/header rerun | Passed: 30 tests. |
| Ten-suite affected Vitest rerun | Passed: 111 tests across 10 files. |
| Four-suite rerun after preserving desktop partial flag updates | Passed: 41 tests. |
| Header rerun after adding button delegation assertions | Passed: 11 tests. |
| Boundary rerun (availability, sidebar, switch) | Passed: 39 tests across 3 files. |
| `pnpm exec vitest run app/javascript/dashboard/i18n/specs/translationKeys.spec.js` | Failed: 2 passed, 3 failed. The guard reports 235 missing ru keys, 241 en keys, and 108 kk keys across existing Help Center, reports, and sidebar code. This task added no translation keys and changed no locale file; these unrelated missing translations were left untouched. |
| ESLint on all 14 changed JS/Vue files | Passed with `--quiet`; an intermediate run found 10 formatting errors after the desktop-preservation edit, corrected with Prettier. The final three-file boundary ESLint run also passed. Commit hooks ran `eslint --fix` successfully for both code commits. |
| `pnpm exec prettier --check` on the shared composable, its spec, switch spec, and conversation view | Passed. Prettier `--write` was used on files with formatting errors. |
| `git diff --check` and staged diff check | Passed. |

Database-backed Ruby specs were not run because this machine has no PostgreSQL or Redis. No Ruby files changed. A live phone browser session was not available; behavior was verified with viewport-specific Vitest specs.

## Open questions

- Should route/query-driven CRM and scheduling drawers follow a similar phone-entry rule? They are outside this conversation-sidebar fix and were left unchanged.
- The translation-key guard is already red for many untouched source files. Which separate localization task should resolve those missing ru/en/kk keys?
