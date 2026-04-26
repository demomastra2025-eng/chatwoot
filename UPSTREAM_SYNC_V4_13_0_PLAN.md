# Onelink Selective Carry From Chatwoot v4.13.0

Status date: 2026-04-26
Worktree: `/Users/akhanbakhitov/Documents/zeroprompt/onelink-sync-v4.13.0-carry`
Branch: `sync/chatwoot-v4.13.0-carry`

## Principle

Onelink is the source of truth. Chatwoot `v4.13.0` is used as a fix and idea source, not as a branch to merge blindly.

Carry rule:

- Apply directly when the upstream code matches Onelink architecture and cases.
- Apply with adaptation when the fix is correct but Onelink has local UX/runtime/product differences.
- Do not apply when the upstream change changes Onelink product semantics, replaces local architecture, or creates integration risk.
- Ask for a product decision only on true dilemmas.

## Applied

### Safe / Direct Or Near-Direct

- `0012fa2c35` message trimming respects configured max length.
- `224b1f98b0` IMAP fetch handles `IOError`.
- `de0bd8e71b` disables tags counter cache to avoid label deadlocks.
- `f2cb23d6e9` browser push handles `Socket::ResolutionError`.
- `0592cccca9` prevents lost concurrent `custom_attributes` writes.
- `4c4b70da25` skips email rate limiting for self-hosted instances.
- `4cce7f6ad8` LINE image/video messages use non-expiring URLs.
- `cac7438fff` fixes email channel links backend behavior.
- `d84ef4cfd6` skips WhatsApp health check during reauthorization.
- `65867b8b36` excludes Sidekiq mutex lock acquisition noise from Sentry.
- `72b8a31f2d` handles users stuck in billing `is_creating`.
- `6f5ad8f372` strips `manually_managed_features` on super admin account create.
- `97dae52841` uses committed RubyLLM model registry.
- `3f9f054c43` drops WhatsApp incoming messages from blocked contacts.
- `04acc16609` skips invoice pay call if already paid after finalize.
- `2b296c06fb` CVE ignore for upstream storage defaults.
- `8e5d4f4d23` Axios security bump to `1.15.0`.

### API / Webhooks / Integrations

- `127ac0a6b2` API channel creation surfaces backend error messages.
- `95463230cb` signs API channel and agent bot webhooks.
- `118270d2e8` updates agent bot listener specs for signed webhook arguments.
- `b815eb9ce0` dispatches webhook event on agent bot assignment.
- `f4d66566d0` includes `changed_attributes` in agent bot `conversation_updated`.
- `50d6ebaaca` dispatches `conversation_status_changed` to agent bots.
- `d83beb2148` populates attachment `extension` and includes `content_type`.
- `441fe4db11` scopes Instagram `external_url` override only to Instagram DM conversations.
- `48533e2a5d` strips markdown hard-break backslashes from webhook payloads.
- `871f2f4d56` upload fetching hardening is already covered in the branch.
- `722e68eecb` validates `support_email` and handles mailer parse errors.

### Help Center / Editor / Docs UX

- `4517c50227` bulk select and delete for Captain documents.
- `5d9d754961` auto-linkifies URLs on paste.
- `7b09b033ef` renders markdown tables in help center.
- `42441dbd28` GuideJar embed support in help center.
- `bd14e96ed9`, `a8c8b38f51`, `72c9e1775b` safe article editor cluster: draft creation on title blur, empty content for drafts, no editor reset while typing.
- `edd0fc98db` table support in article editor.
- `5eee331da3` slash command menu in article editor.
- `b5264a2560` resizable reply/editor UI.

### Dashboard / Conversation UX

- `23786bcb52` marks conversation notifications as read on visit.
- `b9f824b43b` fixes unreadable select options in dark mode.
- `cc008951db` improves active child route matching in sidebar.
- `64f6bfc811` inline edit support for contact info.
- `98cf1ce9f6` bulk select all limited to visible items plus secondary slot.
- `b96bf41234` enables Participating conversations tab.
- `d9e732c005` priority icon refresh.
- `5de7ae492c` and `b9b5a18767` appearance background pair applied with upstream revert semantics.

### Automation / Assignment

- `9efd554693` fixes V2 capacity bypass in team assignment.
- `5fd3d5e036` allows zero conversation limit capacity policy.
- `1987ac3d97` removes old bulk auto-assignment cron and job.
- `aee979ee0b` adds explicit remove assignment actions to macros and automations.
- `135be52431` adds last responding agent option to automation assign agent.
- `45b6ea6b3f` adds automation condition for private notes.

### Auth / Signup / Security

- `4f94ad4a75` signup verification flow applied with Onelink adaptations.
- `211fb1102d` rotates OAuth password if user is unconfirmed.
- `699b12b1d3` blocks inline images in message signatures.
- `f13f3ba446` logs only system API key LLM failures to exception tracker.
- `8824efe0e1` Sentry locale guard was already equivalent in code and was skipped as no-op.

### Captain / AI

- `742c5cc1f4` Dialogflow `language_code` configurability.
- `b7b6e67df7` AI summary localized to account language.
- `b4b5de9b46` conservative handoff prompt fix.
- `8daf6cf6cb` custom tools v1 runtime carried selectively: V1 assistant runtime now wires existing Onelink custom tools.
- `00837019b5` V2 handoff message fix carried with Onelink buffer-state and `preserve_waiting_since`.
- `5264de24b0` carried only the safe `captain_assistant_responses.edited` part.

## Applied With Onelink Adaptation

- Signup verification preserves Onelink legal consent, business-email validation, RU/KK locale keys, and API-only signup response behavior.
- Auto-assignment cron removal preserves Onelink `ENABLE_SIDEKIQ_CRON` and `Integrations::Medelement::CronScheduleService.sync_all!`.
- Custom tools runtime keeps Onelink feature/gating behavior and does not apply upstream `response_bot -> custom_tools` paywall semantics.
- Document auto-sync does not add upstream `captain_documents.sync_status` columns because Onelink already uses Firecrawl metadata-backed sync state.
- Resizable editor keeps local editor sizing and reply-box behavior.
- Priority icon component avoids upstream dynamic i18n key warning.
- Axios lockfile was regenerated minimally: `axios 1.13.6 -> 1.15.0`, `proxy-from-env 1.1.0 -> 2.1.0`.

## Already Covered / No-Op

- `8824efe0e1` Sentry empty locale guard is already present.
- `d83beb2148` attachment extension/content type behavior is already present.
- `0b41d7f483` Swagger typo is already covered.
- `127ac0a6b2`, `742c5cc1f4`, multiple webhook and help-center commits show as non-equivalent patch IDs because Onelink carries adapted implementations.

## Not Applied

### Needs Product Decision

- `f1da7b8afa` enable `assignment_v2` by default for new accounts.
  - Reason: changes new-account behavior and is coupled to Onelink `advanced_assignment`.
- `f422c83c26` unified upstream `Call` model.
  - Reason: Onelink already has `Telephony::CallSession` / voice provider source of truth.
- `b4ce59eea8` reclaim `response_bot` flag for `custom_tools`.
  - Reason: changes entitlement semantics and can disable/alter existing custom tools access.
- `fbe3560b7a` custom tools paywall / UI exposure.
  - Reason: product monetization decision, not a safe bugfix.
- `7651c18b48` Firecrawl branding API.
  - Reason: onboarding/product expansion, not a correctness fix.
- `e5107604a0` Context.dev account enrichment.
  - Reason: adds external dependency and signup/onboarding background behavior.

### Intentionally Skipped

- `4381be5f3e` disable help center on hacker plans.
  - Reason: upstream billing-plan semantics do not map cleanly to Onelink.
- `44a7a13117` Estonian language option.
  - Reason: Onelink active product locales are not being expanded in this carry.
- `8c0c0fd32c`, `45124c3b41`, `aa2e8f99e4`, `03c10ba147`.
  - Reason: translation dumps/noisy i18n updates; take only keys required by carried features.
- `e0e321b8e2` Annotaterb annotation maintenance.
  - Reason: non-functional repo maintenance.
- `42163946eb` and `3190b29fe9` NewRelic ignore + immediate revert.
  - Reason: upstream net no-op.
- `e123a4e500` version bump to `4.13.0`.
  - Reason: only after final acceptance of the carry branch.
- `5264de24b0` document DB sync columns.
  - Reason: conflicts with Onelink Firecrawl metadata sync model.

## Verification Notes

Passed in this worktree:

- Ruby syntax checks for touched backend files.
- `git diff --check` for each batch.
- ESLint for touched frontend clusters where applicable.
- RuboCop for the latest Captain changed files.
- JSON parse checks for touched signup locale files.
- YAML parse check for `config/schedule.yml`.
- Conflict-marker scans for touched batches.

Blocked:

- Targeted RSpec does not start because local PostgreSQL is not running on `127.0.0.1:5432`.
- The failure occurs before examples: `ActiveRecord::ConnectionNotEstablished` / `PG::ConnectionBad`.

## Current Open Questions

1. Do we keep `Telephony::CallSession` as canonical and skip upstream `Call`, or design a compatibility layer?
2. Do we want upstream custom tools paywall/feature flag semantics, or keep current Onelink Captain access?
3. Should new accounts get `assignment_v2` enabled by default?
4. Do we want account enrichment through Context.dev/Firecrawl during signup?
5. Should the branch version be bumped to `4.13.0` after QA, or keep Onelink-specific versioning?
